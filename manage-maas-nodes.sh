#!/bin/bash

# set -x

storage_path="/storage/images/maas"
storage_format="qcow2"
compute="maas-node"
node_count=20
node_start=1
node_cpus=4
node_ram=4096
nic_model="virtio"
network="maas"

create_vms() {
	create_storage & build_vms
}


wipe_vms() {
	destroy_vms
}


create_storage() {
	for ((machine="$node_start"; machine<=node_count; machine++)); do
		printf -v maas_node %s-%02d "$compute" "$machine"
	        mkdir -p "$storage_path/$maas_node"
        	/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d1.img" 40G &
        	/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d2.img" 20G &
        	/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d3.img" 20G &
	done
}


build_vms() {
        for ((virt="$node_start"; virt<=node_count; virt++)); do
		printf -v virt_node %s-%02d "$compute" "$virt"
	        ram="$node_ram"
	        vcpus="$node_cpus"
	        bus="scsi"
	        macaddr=$(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))")

	        virt-install -v --noautoconsole   \
	                --print-xml               \
                        --autostart               \
	                --boot network,hd,menu=on \
	                --graphics spice          \
	                --video qxl,vram=1024     \
	                --channel spicevmc        \
	                --name "$virt_node"       \
	                --ram "$ram"              \
	                --vcpus "$vcpus"          \
	                --cpu host-passthrough,cache.mode=passthrough  \
	                --controller "$bus",model=virtio-scsi,index=0  \
	                --disk path="$storage_path/$virt_node/$virt_node-d1.img,format=$storage_format,size=40,bus=$bus,cache=writeback" \
	                --disk path="$storage_path/$virt_node/$virt_node-d2.img,format=$storage_format,size=20,bus=$bus,cache=writeback" \
	                --disk path="$storage_path/$virt_node/$virt_node-d3.img,format=$storage_format,size=20,bus=$bus,cache=writeback" \
	                --network=network=$network,mac="$macaddr",model=$nic_model > "$virt_node.xml" 
	        virsh define "$virt_node.xml"
	        # virsh start "$virt_node"
	done
}

destroy_vms() {
	for ((node="$node_start"; node<=node_count; node++)); do
		printf -v compute_node %s-%02d "$compute" "$node"

	        # If the domain is running, this will complete, else throw a warning 
	        virsh --connect qemu:///system destroy "$compute_node"

	        # Actually remove the VM
	        virsh --connect qemu:///system undefine "$compute_node"

	        # Remove the three storage volumes from disk
	        for disk in {1..3}; do
	                virsh vol-delete --pool "$compute_node" "$compute_node-d${disk}.img"
	        done
	        rm -rf "$storage_path/$compute_node/"
	        sync
	        rm -f "$compute_node.xml" \
			"/etc/libvirt/qemu/$compute_node.xml"    \
			"/etc/libvirt/storage/$compute_node.xml" \
			"/etc/libvirt/storage/autostart/$compute_node.xml"
	done
}

while getopts ":cw" opt; do
  case $opt in
    c)
		create_vms
 	;;
    w)
		wipe_vms
	;;
	\?)
		echo "Invalid option: -$OPTARG" >&2
	;;
  esac
done

