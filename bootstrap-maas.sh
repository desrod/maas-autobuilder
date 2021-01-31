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
    if [[ $maas_pkg_type != "snap" ]]  && [ ! -f maas.debconf ]; then
        printf "Error: missing debconf file. Please create the file 'maas.debconf'.\n"
        exit 1
    fi
}

# Initialize some vars we'll reuse later in the build, bootstrap
init_variables() {
    echo "MAAS Endpoint: $maas_endpoint"
    echo "MAAS Proxy: $maas_local_proxy"

    core_packages=( jq moreutils uuid )
    maas_packages=( maas maas-cli maas-proxy maas-dhcp maas-dns maas-rack-controller maas-region-api maas-common )
    pg_packages=( postgresql postgresql-client postgresql-client-common postgresql-common )

    maas_snaps=( maas maas-test-db )
}

remove_maas_deb() {
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
    sudo apt-add-repository ppa:maas/${maas_version} -y -r
}

remove_maas_snap() {
    sudo snap remove ${maas_snaps[@]}
}

install_maas_deb() {

    sudo apt-add-repository ppa:maas/${maas_version} -y

    # This is separate from the removal, so we can handle them atomically
    sudo apt-get -fuy --reinstall install "${core_packages}" "${maas_packages[@]}" "${pg_packages[@]}"
    sudo sed -i 's/DISPLAY_LIMIT=5/DISPLAY_LIMIT=100/' /usr/share/maas/web/static/js/bundle/maas-min.js
}

install_maas_snap() {
    sudo apt-get -fuy --reinstall install "${core_packages}"

    # When we specify the channel, we have to install the snaps individually
    for snap in ${maas_snaps[*]} ; do
        sudo snap install ${snap} --channel=$maas_version/stable
    done
}

purge_admin_user() {

read -r -d '' purgeadmin <<EOF
with deleted_user as (delete from auth_user where username = '$maas_profile' returning id),
     deleted_token as (delete from piston3_token where user_id = (select id from deleted_user)),
     deleted_ssh_id as (delete from maasserver_sshkey where user_id = (select id from deleted_user)),
     deleted_userprofile as (delete from maasserver_userprofile where user_id = (select id from deleted_user))
     delete from piston3_consumer where user_id = (select id from deleted_user);
EOF

    [[ $maas_pkg_type == "snap" ]] && maas-test-db.psql -c "$purgeadmin" maasdb
    [[ $maas_pkg_type == "deb" ]] && sudo -u postgres psql -c "$purgeadmin" maasdb
}

build_maas() {
    # Create the initial 'admin' user of MAAS, purge first!
    purge_admin_user

    [[ $maas_pkg_type == "snap" ]] && maas init region+rack --database-uri maas-test-db:/// --maas-url $maas_endpoint --force

    sudo maas createadmin --username "$maas_profile" --password "$maas_pass" --email "$maas_profile"@"$maas_pass" --ssh-import lp:"$launchpad_user"

    if [[ $maas_pkg_type == "deb" ]] ; then
      sudo chsh -s /bin/bash maas
      sudo chown -R maas:maas /var/lib/maas
    fi

    if [ -f ~/.maas-api.key ]; then
        rm ~/.maas-api.key
    fi

    maas_cmd="maas-region"
    [[ $maas_pkg_type == "snap" ]] && maas_cmd="maas"

    maas_api_key="$(sudo ${maas_cmd} apikey --username $maas_profile | head -n 1 | tee ~/.maas-api.key)"

    # Fetch the MAAS API key, store to a file for later reuse, also set this var to that value
    maas login "$maas_profile" "$maas_endpoint" "$maas_api_key"

    maas_system_id="$(maas $maas_profile nodes read hostname="$HOSTNAME" | jq -r '.[].interface_set[0].system_id')"

    # Inject the maas SSH key if it exists
    if [ -f ~/.ssh/maas_rsa.pub ]; then
        maas_ssh_key=$(<~/.ssh/maas_rsa.pub)
        maas $maas_profile sshkeys create "key=$maas_ssh_key"
    fi

    # Update settings to match our needs
    maas $maas_profile maas set-config name=default_storage_layout value=lvm
    maas $maas_profile maas set-config name=network_discovery value=disabled
    maas $maas_profile maas set-config name=active_discovery_interval value=0
    maas $maas_profile maas set-config name=dnssec_validation value=no
    maas $maas_profile maas set-config name=enable_analytics value=false
    maas $maas_profile maas set-config name=enable_third_party_drivers value=false
    maas $maas_profile maas set-config name=curtin_verbose value=true

    [[ -n "$maas_upstream_dns" ]] && maas $maas_profile maas set-config name=upstream_dns value="${maas_upstream_dns}"
    [[ -n "$maas_kernel_opts" ]] && maas $maas_profile maas set-config name=kernel_opts value="${maas_kernel_opts}"
    [[ -n "$maas_name" ]] && maas $maas_profile maas set-config name=maas_name value=${maas_name}

    if [[ -n "$squid_proxy" ]] ; then
        maas $maas_profile maas set-config name=enable_http_proxy value=true
        maas $maas_profile maas set-config name=http_proxy value="$squid_proxy"
    fi

    [[ -n "$maas_boot_source" ]] && maas $maas_profile boot-source update 1 url="$maas_boot_source"
    [[ -n "$package_repository" ]] && maas $maas_profile package-repository update 1 name='main_archive' url="$package_repository"

    # Ensure that we are only grabbing amd64 and not other arches as well
    maas $maas_profile boot-source-selection update 1 1 arches="amd64"

    # The release that is is downloading by default
    default_release=$(maas $maas_profile boot-source-selection read 1 1 | jq .release | sed s/\"//g)

    # Add bionic if the default is focal, or vice-versa
    [[ $default_release == "focal" ]] && other_release="bionic"
    [[ $default_release == "bionic" ]] && other_release="focal"

    [[ -n "$other_release" ]] && maas ${maas_profile} boot-source-selections create 1 os="ubuntu" release="${other_release}" arches="amd64" subarches="*" labels="*"

    # Import the base images; this can take some time
    echo "Importing boot images, please be patient, this may take some time..."
    maas $maas_profile boot-resources import

    # This is hacky, but it's the only way I could find to reliably get the
    # correct subnet for the maas bridge interface
    maas $maas_profile subnet update "$(maas $maas_profile subnets read | jq -rc --arg maas_ip "$maas_ip_range" '.[] | select(.name | contains($maas_ip)) | "\(.id)"')" \
        gateway_ip="$maas_bridge_ip" dns_servers="$maas_bridge_ip"

    sleep 3

    maas $maas_profile ipranges create type=dynamic start_ip="$maas_subnet_start" end_ip="$maas_subnet_end" comment='This is the reserved range for MAAS nodes'

    sleep 3
    maas $maas_profile vlan update fabric-1 0 dhcp_on=True primary_rack="$maas_system_id"

    if [[ $maas_pkg_type == "deb" ]]; then
        # This is needed, because it points to localhost by default and will fail to
        # commission/deploy in this state
        echo "DEBUG: ${maas_endpoint}"

        sudo debconf-set-selections maas.debconf
        sleep 2
        # sudo maas-rack config --region-url "${maas_endpoint}" && sudo service maas-rackd restart
        sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure maas-rack-controller
        sleep 2

        sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure maas-region-controller
        sudo service maas-rackd restart
        sleep 5
    fi
}

bootstrap_maas() {

    until [ "$(maas $maas_profile boot-resources is-importing)" = false ]; do sleep 3; done;

    # Add a chassis with nodes we want to build against
    [[ -n "$virsh_chassis" ]] && maas $maas_profile machines add-chassis chassis_type=virsh prefix_filter=maas-node hostname="$virsh_chassis"

    # This is necessary to allow MAAS to quiesce the imported chassis
    echo "Pausing while chassis is imported..."
    sleep 10

    # Commission those nodes (requires that image import step has completed)
    maas $maas_profile machines accept-all

    # Grab the first node in the chassis and commission it
    # maas_node=$(maas $maas_profile machines read | jq -r '.[0].system_id')
    # maas "$maas_profile" machine commission -d "$maas_node"

    # Acquire all machines marked "Ready"
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
    if [ -f ~/.maas-api.key ]; then
        maas_api_key=$(<~/.maas-api.key)
    fi

cat > clouds-"$rand_uuid".yaml <<EOF
clouds:
  $cloud_name:
    type: maas
    auth-types: [ oauth1 ]
    description: MAAS cloud for $cloud_name
    # endpoint: ${maas_endpoint:0:-8}
    endpoint: $maas_endpoint
    config:
      enable-os-refresh-update: true
      enable-os-upgrade: false
      logging-config: <root>=DEBUG
EOF

if [[ -n "$package_repository" ]] ; then
cat >> clouds-"$rand_uuid".yaml <<EOF
      apt-mirror: $package_repository
EOF
fi

# Only add the proxy stuff if its set
if [[ -n "$squid_proxy" ]] ; then
cat >> clouds-"$rand_uuid".yaml <<EOF
      apt-http-proxy: $squid_proxy
      apt-https-proxy: $squid_proxy
      snap-http-proxy: $squid_proxy
      snap-https-proxy: $squid_proxy
      # snap-store-proxy: $snap_store_proxy
EOF
fi

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
transmit-vendor-metrics: false
EOF

# Only add the proxy stuff if its set
if [[ -n "$squid_proxy" ]] ; then
cat >> config-"$rand_uuid".yaml <<EOF
juju-ftp-proxy: $squid_proxy
juju-http-proxy: $squid_proxy
juju-https-proxy: $squid_proxy
juju-no-proxy: $no_proxy
apt-http-proxy: $squid_proxy
apt-https-proxy: $squid_proxy
EOF
fi

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

    # Only enable HA if the variable is set and true
    [[ -n "$juju_ha" ]] && [[ $juju_ha == "true" ]] && juju enable-ha

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

# Load up some initial variables from the config and package arrays
read_config
init_variables

# This is the proxy that MAAS itself uses (the "internal" MAAS proxy)
no_proxy="localhost,127.0.0.1,$maas_system_ip,$(echo $maas_ip_range.{100..200} | sed 's/ /,/g')"

while getopts ":a:bc:ij:nt:r" opt; do
  case $opt in
    a )
        check_bins
        remove_maas_${maas_pkg_type}
        install_maas_${maas_pkg_type}
        build_maas
        bootstrap_maas
        add_cloud "$OPTARG"
        ;;
    b )
        echo "Building out a new MAAS server"
        check_bins
        install_maas_${maas_pkg_type}
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
        install_maas_${maas_pkg_type}
        exit 0
        ;;
    j )
        echo "Bootstrapping Juju controller $OPTARG"
        add_cloud "$OPTARG"
        exit 0
        ;;
    r )
        remove_maas_${maas_pkg_type}
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
