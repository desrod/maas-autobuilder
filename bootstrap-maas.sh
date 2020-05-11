#!/bin/bash 

required_bins=( ip sudo debconf-set-selections )

check_bins() {
    # Append any needed binaries we need to check for, to our list
    if [[ $1 ]]; then
            required_bins+=("$1")
    fi

    for binary in "${required_bins[@]}"; do
        if ! [ -x "$(command -v "$binary")" ]; then
            printf "Error: Necessary program '%s' is not installed. Please fix, aborting now.\n\n" "$binary" >&2
            exit 1
        fi
    done
}

read_config() {
    if [ ! -f maas.config ]; then
        printf "Error: missing config file. Please create the file 'maas.config'.\n"
        exit 1
    else
        shopt -s extglob
        maas_config="maas.config"
        source "$maas_config"
    fi
    if [ ! -f maas.debconf ]; then
        printf "Error: missing debconf file. Please create the file 'maas.debconf'.\n"
        exit 1
    fi
}

# Initialize some vars we'll reuse later in the build, bootstrap
init_variables() {
    echo "MAAS Endpoint: $maas_endpoint"
    echo "MAAS Proxy: $maas_local_proxy"

    virsh_chassis="qemu+ssh://${virsh_user}@${maas_system_ip}/system"

    core_packages=(jq moreutils uuid)
    maas_packages=(maas maas-cli maas-proxy maas-dhcp maas-dns maas-rack-controller maas-region-api maas-common)
    pg_packages=(postgresql-10 postgresql-client postgresql-client-common postgresql-common)
}

remove_maas() {
    # Drop the MAAS db ("maasdb"), so we don't risk reusing it
    sudo -u postgres psql -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='maasdb'"
    sudo -u postgres psql -c "drop database maasdb"

    # Remove everything, start clean and clear from the top
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge "${maas_packages[@]}" "${pg_packages[@]}" && \
    sudo apt-get -fuy autoremove

    # Yes, they're removed but we want them PURGED, so this becomes idempotent
    for package in "${maas_packages[@]}" "${pg_packages[@]}"; do
       sudo dpkg -P "$package"
    done
}

install_maas() {
    # This is separate from the removal, so we can handle them atomically
    sudo apt-get -fuy --reinstall install "${core_packages} ${maas_packages[@]}" "${pg_packages[@]}"
    sudo sed -i 's/DISPLAY_LIMIT=5/DISPLAY_LIMIT=100/' /usr/share/maas/web/static/js/bundle/maas-min.js
}

purge_admin_user() {

read -r -d '' purgeadmin <<EOF
with deleted_user as (delete from auth_user where username = '$maas_profile' returning id),
     deleted_token as (delete from piston3_token where user_id = (select id from deleted_user)),
     deleted_ssh_id as (delete from maasserver_sshkey where user_id = (select id from deleted_user)),
     deleted_userprofile as (delete from maasserver_userprofile where user_id = (select id from deleted_user))
     delete from piston3_consumer where user_id = (select id from deleted_user);
EOF

    sudo -u postgres psql -c "$purgeadmin" maasdb
}

build_maas() {
    # Create the initial 'admin' user of MAAS, purge first!
    purge_admin_user
    sudo maas createadmin --username "$maas_profile" --password "$maas_pass" --email "$maas_profile"@"$maas_pass" --ssh-import lp:"$launchpad_user"

    sudo chsh -s /bin/bash maas
    sudo chown -R maas:maas /var/lib/maas

    if [ -f ~/.maas-api.key ]; then
        rm ~/.maas-api.key
        maas_api_key="$(sudo maas-region apikey --username=$maas_profile | tee ~/.maas-api.key)"
    fi;

    # Fetch the MAAS API key, store to a file for later reuse, also set this var to that value
    maas login "$maas_profile" "$maas_endpoint" "$maas_api_key"

    maas_system_id="$(maas $maas_profile nodes read hostname="$HOSTNAME" | jq -r '.[].interface_set[0].system_id')"

    # Inject the maas SSH key
    maas_ssh_key=$(<~/.ssh/maas_rsa.pub)
    maas $maas_profile sshkeys create "key=$maas_ssh_key"

    # Update settings to match our needs
    maas $maas_profile maas set-config name=default_storage_layout value=lvm
    maas $maas_profile maas set-config name=network_discovery value=disabled
    maas $maas_profile maas set-config name=active_discovery_interval value=0
    maas $maas_profile maas set-config name=kernel_opts value="console=ttyS0,115200 console=tty0,115200 elevator=noop zswap.enabled=1 zswap.compressor=lz4 zswap.max_pool_percent=20 zswap.zpool=z3fold intel_iommu=on iommu=pt debug nosplash scsi_mod.use_blk_mq=1 dm_mod.use_blk_mq=1 enable_mtrr_cleanup mtrr_spare_reg_nr=1 systemd.log_level=debug"
    maas $maas_profile maas set-config name=maas_name value=us-east
    maas $maas_profile maas set-config name=upstream_dns value="$maas_upstream_dns"
    maas $maas_profile maas set-config name=dnssec_validation value=no
    maas $maas_profile maas set-config name=enable_analytics value=false
    maas $maas_profile maas set-config name=enable_http_proxy value=true
    # maas $maas_profile maas set-config name=http_proxy value="$squid_proxy"
    maas $maas_profile maas set-config name=enable_third_party_drivers value=false
    maas $maas_profile maas set-config name=curtin_verbose value=true

    maas $maas_profile boot-source update 1 url="$maas_boot_source"
    # maas $maas_profile boot-source update 1 url=http://"$maas_bridge_ip":8765/maas/images/ephemeral-v3/daily/
    maas $maas_profile package-repository update 1 name='main_archive' url="$package_mirror"

    # This is hacky, but it's the only way I could find to reliably get the
    # correct subnet for the maas bridge interface
    maas $maas_profile subnet update "$(maas $maas_profile subnets read | jq -rc --arg maas_ip "$maas_ip_range" '.[] | select(.name | contains($maas_ip)) | "\(.id)"')" gateway_ip="$maas_bridge_ip"
    sleep 3

    maas $maas_profile ipranges create type=dynamic start_ip="$maas_subnet_start" end_ip="$maas_subnet_end" comment='This is the reserved range for MAAS nodes'

    sleep 3
    maas $maas_profile vlan update fabric-1 0 dhcp_on=True primary_rack="$maas_system_id"

    # This is needed, because it points to localhost by default and will fail to 
    # commission/deploy in this state
    echo "DEBUG: http://$maas_bridge_ip:5240/MAAS/"

    sudo debconf-set-selections maas.debconf
    sleep 2
    # sudo maas-rack config --region-url "http://$maas_bridge_ip:5240/MAAS/" && sudo service maas-rackd restart
    sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure maas-rack-controller
    sleep 2

    sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure maas-region-controller
    sudo service maas-rackd restart
    sleep 5
}

bootstrap_maas() {
    # Import the base images; this can take some time
    echo "Importing boot images, please be patient, this may take some time..."
    maas $maas_profile boot-resources import

    until [ "$(maas $maas_profile boot-resources is-importing)" = false ]; do sleep 3; done;

    # Add a chassis with nodes we want to build against
    maas $maas_profile machines add-chassis chassis_type=virsh prefix_filter=maas-node hostname="$virsh_chassis"

    # This is necessary to allow MAAS to quiesce the imported chassis
    echo "Pausing while chassis is imported..."
    sleep 10

    # Commission those nodes (requires that image import step has completed)
    maas $maas_profile machines accept-all

    # Grab the first node in the chassis and commission it
    # maas_node=$(maas $maas_profile machines read | jq -r '.[0].system_id')
    # maas "$maas_profile" machine commission -d "$maas_node"

    # Acquire all images marked "Ready"
    maas $maas_profile machines allocate

    # Deploy the node you just commissioned and acquired
    # maas "$maas_profile" machine deploy $maas_node
}

# These are for juju, adding a cloud matching the customer/reproducer we need
add_cloud() {

	if ! [ -x "$(command -v juju)" ]; then
		sudo snap install juju --channel "$juju_version"
	fi
	rand_uuid=$(uuid -F siv)
	cloud_name="$1"
	maas_api_key=$(<~/.maas-api.key)

cat > clouds-"$rand_uuid".yaml <<EOF
clouds:
  $cloud_name:
    type: maas
    auth-types: [ oauth1 ]
    description: MAAS cloud for $cloud_name
    # endpoint: ${maas_endpoint:0:-8}
    endpoint: $maas_endpoint
    config:
      # apt-mirror: $package_mirror
      apt-http-proxy: $squid_proxy
      apt-https-proxy: $squid_proxy
      snap-http-proxy: $squid_proxy
      snap-https-proxy: $squid_proxy
      snap-store-proxy: $squid_proxy
      enable-os-refresh-update: true
      enable-os-upgrade: false
      logging-config: <root>=DEBUG
EOF

cat > credentials-"$rand_uuid".yaml <<EOF
credentials:
      $cloud_name:
        $cloud_name-auth:
          auth-type: oauth1
          maas-oauth: $maas_api_key
EOF

cat > config-"$rand_uuid".yaml <<EOF
automatically-retry-hooks: true
mongo-memory-profile: default
default-series: bionic
juju-ftp-proxy: $squid_proxy
juju-http-proxy: $squid_proxy
juju-https-proxy: $squid_proxy
juju-no-proxy: $no_proxy
apt-http-proxy: $squid_proxy
apt-https-proxy: $squid_proxy
transmit-vendor-metrics: false
EOF

    echo "Adding cloud............: $cloud_name"
    # juju add-cloud --replace "$cloud_name" clouds-"$rand_uuid".yaml
    juju update-cloud "$cloud_name" -f clouds-"$rand_uuid".yaml

    echo "Adding credentials for..: $cloud_name"
    #juju add-credential --replace "$cloud_name" -f credentials-"$rand_uuid".yaml
    juju add-credential "$cloud_name" -f credentials-"$rand_uuid".yaml

    echo "Details for cloud.......: $cloud_name..."
    juju clouds --format json | jq --arg cloud "$cloud_name" '.[$cloud]'

    juju bootstrap "$cloud_name" --debug --config=config-"$rand_uuid".yaml

    # Since we created ephemeral files, let's wipe them out. Comment if you want to keep them around
    if [[ $? = 0 ]]; then
	rm -f clouds-"$rand_uuid".yaml credentials-"$rand_uuid".yaml config-"$rand_uuid".yaml
    fi

    juju enable-ha
    juju machines -m controller
}

# Let's get rid of that cloud and clean up after ourselves
destroy_cloud() {
    cloud_name="$1"

    juju --debug clouds --format json | jq --arg cloud "$cloud_name" '.[$cloud]'
    juju --debug remove-cloud "$cloud_name"

}

show_help() {
  echo "

  -a <cloud_name>    Do EVERYTHING (maas, juju cloud, juju bootstrap)
  -b                 Build out and bootstrap a new MAAS
  -c <cloud_name>    Add a new cloud + credentials
  -i                 Just install the dependencies and exit
  -j <name>          Bootstrap the Juju controller called <name>
  -n                 Create MAAS kvm nodes (to be imported into chassis)
  -r                 Remove the entire MAAS server + dependencies
  -t <cloud_name>    Tear down the cloud named <cloud_name>
  "
}


if [ $# -eq 0 ]; then
  printf "%s needs options to function correctly. Valid options are:" "$0"
  show_help
  exit 0
fi

init_variables
read_config

# This is the proxy that MAAS itself uses (the "internal" MAAS proxy)
no_proxy="localhost,127.0.0.1,$maas_system_ip,$(echo $maas_ip_range.{100..200} | sed 's/ /,/g')"

while getopts ":a:bc:ij:nt:r" opt; do
  case $opt in
    a )
    check_bins
    remove_maas
    install_maas
    build_maas
    bootstrap_maas
    add_cloud "$OPTARG"
    ;;
    b )
    echo "Building out a new MAAS server"
    check_bins
    install_maas
    build_maas
    bootstrap_maas
    exit 0
    ;;
    c )
    check_bins maas
    init_variables
    add_cloud "$OPTARG"
    ;;
    i )
    echo "Installing MAAS and PostgreSQL dependencies"
    install_maas
    exit 0
    ;;
    j )
    echo "Bootstrapping Juju controller $OPTARG"
    add_cloud "$OPTARG"
    exit 0
    ;;
    r )
    remove_maas
    exit 0
    ;;
    t )
    destroy_cloud "$OPTARG"
    exit 0
    ;;
   \? )
    printf "Unrecognized option: -%s. Valid options are:" "$OPTARG" >&2
    show_help
    exit 1
    ;;
    : )
    printf "Option -%s needs an argument.\n" "$OPTARG" >&2
    show_help
    echo ""
    exit 1
    ;;
  esac
done
