#!/bin/bash

# set -x

storage_path="/storage/images/maas"
storage_format="raw"
compute="maas-node"
node_count=20
node_start=1
node_cpus=4
node_ram=4096
nic_model="virtio"
network="maas"
d1=50
d2=100
d3=100

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
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d1.img" "$d1"G &
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d2.img" "$d2"G &
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d3.img" "$d3"G &
	done
}


build_vms() {
        for ((virt="$node_start"; virt<=node_count; virt++)); do
		printf -v virt_node %s-%02d "$compute" "$virt"
	        ram="$node_ram"
	        vcpus="$node_cpus"
	        bus="scsi"
	        macaddr1=$(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))")
	        macaddr2=$(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))")

	        virt-install -v --noautoconsole   \
	                --print-xml               \
                        --autostart               \
	                --boot network,hd,menu=on \
	                --video qxl,vram=256      \
	                --channel spicevmc        \
	                --name "$virt_node"       \
	                --ram "$ram"              \
	                --vcpus "$vcpus"          \
	                --console pty,target_type=serial \
	                --graphics spice,clipboard_copypaste=no,mouse_mode=client,filetransfer_enable=off \
	                --cpu host-passthrough,cache.mode=passthrough  \
	                --controller "$bus",model=virtio-scsi,index=0  \
	                --disk path="$storage_path/$virt_node/$virt_node-d1.img,format=$storage_format,size=$d1,bus=$bus,io=native,cache=directsync" \
	                --disk path="$storage_path/$virt_node/$virt_node-d2.img,format=$storage_format,size=$d2,bus=$bus,io=native,cache=directsync" \
	                --disk path="$storage_path/$virt_node/$virt_node-d3.img,format=$storage_format,size=$d3,bus=$bus,io=native,cache=directsync" \
                        --network=network=$network,mac="$macaddr1",model=$nic_model \
                        --network=network=$network,mac="$macaddr2",model=$nic_model > "$virt_node.xml" &&
	        virsh define "$virt_node.xml" &
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

