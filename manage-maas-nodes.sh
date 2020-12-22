#!/bin/bash

# set -x

. default.config
. maas.config
. hypervisor.config

# Storage type
storage_format="raw"

# Models for nic and storage
nic_model="virtio"
stg_bus="scsi"

# how long you want to wait for commissioning
# default is 1200, i.e. 20 mins
commission_timeout=1200

# Time between building VMs
build_fanout=60

# Ensures that any dependent packages are installed for any MAAS CLI commands
# This also logs in to MAAS, and sets up the admin profile
maas_login()
{
    # Install some of the dependent packages
    sudo apt -y update && sudo apt -y install jq bc

    # We install the snap, as maas-cli is not in distributions, this ensures
    # that the package we invoke would be consistent
    sudo snap install maas --channel=2.8/stable

    # Login to MAAS using the API key and the endpoint
    echo ${maas_api_key} | maas login ${maas_profile} ${maas_endpoint} -
}

# Grabs the unique system_id for the host human readable hostname
maas_system_id()
{
    node_name=$1

    maas ${maas_profile} machines read hostname=${node_name} | jq ".[].system_id" | sed s/\"//g
}

# Adds the VM into MAAS
maas_add_node()
{
    node_name=$1
    mac_addr=$2
    node_type=$3

    # This command creates the machine in MAAS. This will then automatically
    # turn the machines on, and start commissioning.
    maas ${maas_profile} machines create \
        hostname=${node_name}            \
        mac_addresses=${mac_addr}        \
        architecture=amd64/generic       \
        power_type=virsh                 \
        power_parameters_power_id=${node_name}            \
        power_parameters_power_address=${qemu_connection} \
        power_parameters_power_pass=${qemu_password}

    # Grabs the system_id for th node that we are adding
    system_id=$(maas_system_id ${node_name})

    # This will ensure that the node is ready before we start manipulating
    # other attributes.
    ensure_machine_ready ${system_id}

    # If the tag doesn't exist, then create it
    if [[ $(maas ${maas_profile} tag read ${node_type}) == "Not Found" ]] ; then
        maas ${maas_profile} tags create name=${node_type}
    fi

    # Assign the tag to the machine
    maas ${maas_profile} tag update-nodes ${node_type} add=${system_id}

    # Ensure that all the networks on the system have the Auto-Assign set
    # so that the all the of the networks on the host have an IP automatically.
    maas_auto_assign_networks ${system_id}
}

# Attempts to auto assign all the networks for a host
maas_auto_assign_networks()
{
    system_id=$1

    # Grabs all the interfaces that are attached to the system
    node_interfaces=$(maas ${maas_profile} interfaces read ${system_id} \
        | jq ".[] | {id:.id, name:.name, mode:.links[].mode, subnet:.links[].subnet.id }" --compact-output)

    # This for loop will go through all the interfaces and enable Auto-Assign
    # on all ports
    for interface in ${node_interfaces}
    do
        int_id=$(echo $interface | jq ".id" | sed s/\"//g)
        subnet_id=$(echo $interface | jq ".subnet" | sed s/\"//g)
        mode=$(echo $interface | jq ".mode" | sed s/\"//g)
        if [[ $mode != "auto" ]] ; then
            maas ${maas_profile} interface link-subnet ${system_id} ${int_id} mode="AUTO" subnet=${subnet_id}
        fi
    done
}

# Calls the 3 functions that creates the VMs
create_vms() {
    maas_login
    create_storage
    build_vms
}

# This takes the system_id, and ensures that the machine is uin Ready state
# You may want to tweak the commission_timeout above in somehow it's failing
# and needs to be done quicker
ensure_machine_ready()
{
    system_id=$1

    time_start=$(date +%s)
    time_end=${time_start}
    status_name=$(maas ${maas_profile} machine read ${system_id} | jq ".status_name" | sed s/\"//g)
    while [[ ${status_name} != "Ready" ]] && [[ $( echo ${time_end} - ${time_start} | bc ) -le ${commission_timeout} ]]
    do
        sleep 20
        status_name=$(maas ${maas_profile} machine read ${system_id} | jq ".status_name" | sed s/\"//g)
        time_end=$(date +%s)
    done
}

# Calls the functions that destroys and cleans up all the VMs
wipe_vms() {
    maas_login
    destroy_vms
}

# Creates the disks for all the nodes
create_storage() {
    for ((virt="$node_start"; virt<=node_count; virt++)); do
        printf -v virt_node %s-%02d "$compute" "$virt"

        # Create th directory where the storage files will be located
        mkdir -p "$storage_path/$virt_node"

        # For all the disks that are defined in the array, create a disk
        for ((disk=0;disk<${#disks[@]};disk++)); do
            /usr/bin/qemu-img create -f "$storage_format" \
                "$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img" "${disks[$disk]}"G &
        done
    done
    wait
}

# The purpose of this function is to stop, release the nodes and wipe the disks
# to save space, and then so that the machines in MAAS can be re-used
wipe_disks() {
    for ((virt="$node_start"; virt<=node_count; virt++)); do
        printf -v virt_node %s-%02d "$compute" "$virt"
        system_id=$(maas_system_id ${virt_node})

        # Release the machine in MAAS
        maas ${maas_profile} machine release ${system_id}

        # Ensure that the machine is in ready state before the next step
        ensure_machine_ready ${system_id}

        # Stop the machine if it is running
        virsh --connect qemu:///system shutdown "$virt_node"

        # Remove the disks
        for ((disk=0;disk<${#disks[@]};disk++)); do
            rm -rf "$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img" &
        done
    done

    # Re-create the storage again from scratch
    create_storage
    wait
}

# Builds the VMs from scratch, and then adds them to MAAS
build_vms() {
    for ((virt="$node_start"; virt<=node_count; virt++)); do
        printf -v virt_node %s-%02d "$compute" "$virt"

        # Based on the variables in hypervisor.config, we define the variables
        # for ram and cpus. This also allows a number of control nodes that
        # can be defined as part of full set of nodes.
        ram="$node_ram"
        vcpus="$node_cpus"
        node_type="compute"
        if [[ $virt -le $control_count ]] ; then
            ram="$control_ram"
            vcpus="$control_cpus"
            node_type="control"
        fi
        bus=$stg_bus

        # Based on the bridges array, it will generate these amount of MAC
        # addresses and then create the network definitions to add to
        # virt-install
        macaddr=()
        network_spec=""

        # Based on the type of network we are using we will assign variables
        # such that this can be either bridge or network type
        if [[ $network_type == "bridge" ]] ; then
            net_prefix="bridge"
            net_type=(${bridges[@]})
        elif [[ $network_type == "network" ]] ; then
            net_prefix="network"
            net_type=(${networks[@]})
        fi

        # Now define the network definition
        for ((mac=0;mac<${#net_type[@]};mac++)); do
            macaddr+=($(printf '52:54:00:%02x:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))" "$((RANDOM%256))"))
            network_spec+=" --network=$net_prefix="${net_type[$mac]}",mac="${macaddr[$mac]}",model=$nic_model"
        done

        # Based on the disks array, it will create a definition to add these
        # disks to the VM
        disk_spec=""
        for ((disk=0;disk<${#disks[@]};disk++)); do
            disk_spec+=" --disk path=$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img"
            disk_spec+=",format=$storage_format,size=${disks[$disk]},bus=$bus,io=native,cache=directsync"
        done

        # Creates the VM with all the attributes given
        virt-install -v --noautoconsole   \
            --print-xml                   \
            --autostart                   \
            --boot network,hd,menu=on     \
            --video qxl,vram=256          \
            --channel spicevmc            \
            --name "$virt_node"           \
            --ram "$ram"                  \
            --vcpus "$vcpus"              \
            --os-variant "ubuntu18.04"    \
            --console pty,target_type=serial \
            --graphics spice,clipboard_copypaste=no,mouse_mode=client,filetransfer_enable=off \
            --cpu host-passthrough,cache.mode=passthrough  \
            --controller "$bus",model=virtio-scsi,index=0  \
            $disk_spec \
            $network_spec > "$virt_node.xml" &&

        # Create the Vm based on the XML file defined in the above command
        virsh define "$virt_node.xml"

        # Start the VM
        virsh start "$virt_node" &

        # Call the maas_add_node function, this will add the node to MAAS
        maas_add_node ${virt_node} ${macaddr[0]} ${node_type} &

        # Wait some time before building the next, this helps with a lot of DHCP requests
        # and ensures that all VMs are commissioned and deployed.
        sleep ${build_fanout}

    done
    wait
}

destroy_vms() {
    for ((node="$node_start"; node<=node_count; node++)); do
        printf -v virt_node %s-%02d "$compute" "$node"

        # If the domain is running, this will complete, else throw a warning
        virsh --connect qemu:///system destroy "$virt_node"

        # Actually remove the VM
        virsh --connect qemu:///system undefine "$virt_node"

        # Remove the three storage volumes from disk
        for ((disk=0;disk<${#disks[@]};disk++)); do
            virsh vol-delete --pool "$virt_node" "$virt_node-d$((${disk} + 1)).img"
        done

        # Remove the folder storage is located
        rm -rf "$storage_path/$virt_node/"
        sync

        # Remove the XML definitions for the VM
        rm -f "$virt_node.xml" \
            "/etc/libvirt/qemu/$virt_node.xml"    \
            "/etc/libvirt/storage/$virt_node.xml" \
            "/etc/libvirt/storage/autostart/$virt_node.xml"

        # Now remove the VM from MAAS
        system_id=$(maas_system_id ${virt_node})
        maas ${maas_profile} machine delete ${system_id}
    done
}

show_help() {
  echo "

  -c    Creates everything
  -w    Removes everything
  -d    Releases VMs, Clears Disk
  "
}

while getopts ":cwd" opt; do
  case $opt in
    c)
        create_vms
        ;;
    w)
        wipe_vms
        ;;
    d)
        wipe_disks
        ;;
    \?)
        printf "Unrecognized option: -%s. Valid options are:" "$OPTARG" >&2
        show_help
        exit 1
        ;;
  esac
done
