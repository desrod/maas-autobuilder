#!/bin/bash

# set -x

version=2.50
storage_path="/storage/images/maas"
storage_format="qcow2"
compute="maas-node"
node_num=3
node_start=1
node_cpus=4
node_ram=4096
nic_model="virtio"
network="maas"
d1=50
d2=100
d3=100

create_vms() {
	create_storage "${node_num}" & build_vms "${node_num}" "${node_cpus}" "${node_ram}"
}


wipe_vms() {
	destroy_vms "$1"
}


create_storage() {
	for ((machine="$node_start"; machine<="$node_num"; machine++)); do
		printf -v maas_node %s-%02d "$compute" "$machine"
		mkdir -p "$storage_path/$maas_node"
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d1.img" -o cluster_size=512k,lazy_refcounts=on,preallocation=metadata,compat=1.1 "$d1"G &
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d2.img" -o cluster_size=512k,lazy_refcounts=on,preallocation=metadata,compat=1.1 "$d2"G &
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d3.img" -o cluster_size=512k,lazy_refcounts=on,preallocation=metadata,compat=1.1 "$d3"G &
	done
}


build_vms() {
	for ((virt="$node_start"; virt<="$node_num"; virt++)); do
		printf -v virt_node %s-%02d "$compute" "$virt"
		bus="scsi"
		macaddr1=$(printf '52:54:00:%02x:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))" "$((RANDOM%256))")
		macaddr2=$(printf '52:54:00:%02x:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))" "$((RANDOM%256))")

		virt-install -v --noautoconsole   \
			--print-xml               \
			--autostart               \
			--boot network,hd,menu=on \
			--video qxl,vram=256      \
			--channel spicevmc        \
			--name "${virt_node}"       \
			--ram "${node_ram}"         \
			--vcpus "${node_cpus}"      \
			--console pty,target_type=serial \
			--graphics spice,clipboard_copypaste=no,mouse_mode=client,filetransfer_enable=off \
			--cpu host-passthrough,cache.mode=passthrough  \
			--controller "$bus",model=virtio-scsi,index=0  \
			--disk path="$storage_path/$virt_node/$virt_node-d1.img,format=$storage_format,sparse=false,size=$d1,bus=$bus,io=threads,cache=writeback" \
			--disk path="$storage_path/$virt_node/$virt_node-d2.img,format=$storage_format,sparse=false,size=$d2,bus=$bus,io=threads,cache=writeback" \
			--disk path="$storage_path/$virt_node/$virt_node-d3.img,format=$storage_format,sparse=false,size=$d3,bus=$bus,io=threads,cache=writeback" \
			--network=network=$network,mac="$macaddr1",model=$nic_model \
			--network=network=$network,mac="$macaddr2",model=$nic_model > "$virt_node.xml" &&
			virsh define "$virt_node.xml" &
		# virsh start "$virt_node" &
	done
}

destroy_vms() {
	for ((node="$node_start"; node<="$node_num"; node++)); do
		printf -v compute_node %s-%02d "$compute" "$node"

		# If the domain is running, this will complete, else throw a warning 
		virsh --connect qemu:///system destroy "$compute_node"

		# Actually remove the VM
		virsh --connect qemu:///system undefine "$compute_node"

		# Remove the three storage volumes from disk
		for disk in {1..3}; do
			virsh vol-delete --pool "$compute_node" "$compute_node-d${disk}.img"
		done
		rm -rf "${storage_path:?}/${compute_node}/"
		sync
		rm -f "$compute_node.xml" \
			"/etc/libvirt/qemu/$compute_node.xml"    \
			"/etc/libvirt/storage/$compute_node.xml" \
			"/etc/libvirt/storage/autostart/$compute_node.xml"
	done
}


usage() {
	printf "manage-nodes -- Create and manage virsh/KVM nodes for deployment\n\n"
	printf -- "	-h This help message\n"
	printf -- "	-c Create new nodes\n"
	printf -- "	-w Wipe existing nodes\n"
	printf -- "	-n <num> of nodes to create/wipe  (default: 3)\n\n"
	printf -- "	--cpus <num> of vcpus to allocate (default: 4)\n"
	printf -- "	--ram <amt> of RAM in MB          (default: 4986)\n\n"
	
}  

version() {
	printf "manage-nodes -- v${version}\n"
	printf -- "Copyright(c) 2016-2021 David A. Desrosiers <david.desrosiers@canonical.com>\n\n"
	printf -- "This is free software; see the source for copying conditions.\n"
	printf -- "There is NO WARRANTY, to the extent permitted by law.\n\n"
}

source "$PWD"/getopt

OPT_SHORT='n:cwhV'
OPT_LONG=('create' 'wipe' 'nodes:' 'cpus:' 'ram:')
if ! parseopts "$OPT_SHORT" "${OPT_LONG[@]}" -- "$@"; then
    exit 1
fi

set -- "${OPTRET[@]}"
unset OPT_SHORT OPT_LONG OPTRET

# Bash can use (( arithmetic )) context here.
if (( $# <= 1 )); then
    usage >&2
    exit 1
else
    while true; do
        case $1 in
            -c|--create)  mode=create;;
            --cpus)       node_cpus=$2; shift ;;
            --ram)        node_ram=${2:-4096}; shift ;; 
            -w|--wipe)    mode=wipe;;
            -n|--nodes)   node_num=$2; shift ;;
            -h|--help)    usage; exit 0 ;;
            -V|--version) version; exit 0 ;;
            --)           shift; break ;;
        esac
        shift
    done

    if [[ $mode ]]; then
        "$mode"_vms "$node_num" "${cpus:-4}" "$ram" 
    fi
fi

