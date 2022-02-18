#!/usr/bin/env python3

import subprocess

import click
from tqdm import tqdm
import libvirt
from randmac import RandMac

version = 1.00
storage_path = "/storage/images/maas"
storage_format = "qcow2"
node_name = "maas-node"
nic_model = "virtio"
disk_1 = 40
disk_2 = 100
disk_3 = 100

############################################################################################
def validate_range(ctx, param, value):
    # print(f"Inside callback for parameter {param} with value {value}:")
    required_count = ctx.params["count"]
    start_count = ctx.params["start"]

    if value is None:
        limit_stop = required_count
        # print(f"Missing value for {param}, setting to {limit_stop}")
    else:
        total_count = value - start_count

        if total_count > required_count:
            limit_stop = required_count - start_count
            print(f"Exceeded node count with {value}, limiting to {limit_stop}")
        else:
            limit_stop = value

    return limit_stop


############################################################################################
def create_storage(conn, machine):
    machine_path = f"{storage_path}/{machine}"
    subprocess.run(["sudo", "mkdir", "-p", machine_path])
    d = 1

    pool_xml = f"""
        <pool type='dir'>
        <name>{machine}</name>
        <source>
        </source>
        <target>
            <path>{machine_path}</path>
            <permissions>
            <mode>0755</mode>
            <owner>0</owner>
            <group>0</group>
            </permissions>
        </target>
        </pool>"""

    conn.storagePoolCreateXML(pool_xml, 0)

    pool = conn.storagePoolLookupByName(machine)
    for disk in disk_1, disk_2, disk_3:
        volume_xml = f"""
            <volume type='file'>
            <name>{machine}-d{d}.img</name>
            ​<capacity unit="G">{disk}</capacity>
            <key>{machine_path}/{machine}-d{d}.img</key>
            <source>
            </source>
            <target>
                <path>{machine_path}/{machine}-d{d}.img</path>
                <format type='qcow2'/>
                <permissions>
                <mode>0644</mode>
                <owner>0</owner>
                <group>0</group>
                </permissions>
                <timestamps>
                </timestamps>
                <compat>1.1</compat>
                <features>
                <lazy_refcounts/>
                </features>
            </target>
            </volume>"""
        
        pool.createXML(volume_xml, 0)
        pool.refresh()
        d += 1


############################################################################################
def create_machines(conn, start, end, memory, vcpu, network):
    for node in tqdm(range(start, end + 1)):
        machine = f"{node_name}-{node:0{2 if len(str(end)) < 2 else len(str(end))}d}"
        machine_path = f"{storage_path}/{machine}"
        memory_kb = memory * 1024

        create_storage(conn, machine)

        # Variables for the template are above
        template = node_xml.format(machine=machine, 
                              vcpu=vcpu, 
                              memory=memory_kb,
                              machine_path=machine_path, 
                              mac1=RandMac('00:00:00:00:00:00', True),
                              network=network,
                              mac2=RandMac('00:00:00:00:00:00', True)
                              )

        # print(f"Defined template for {machine} out of {end} total. ({end - node} remaining)")
        conn.defineXML(template)


############################################################################################
def destroy_machines(conn, start, end):

    for node in range(start, end + 1):
        machine = f"{node_name}-{node:0{2 if len(str(end)) < 2 else len(str(end))}d}"
        virsh_domain = conn.lookupByName(machine)

        try:
            pool = conn.storagePoolLookupByName(machine)
            vols = pool.listVolumes()

            for vol in vols:
                try:
                    volume = pool.storageVolLookupByName(vol)
                    volume.delete()
                except Exception:
                    pass
            pool.destroy()
            pool.undefine()
        except:
            pass

        if virsh_domain.isActive():
            virsh_domain.destroy()
        else:
            virsh_domain.undefine()
            
        subprocess.call(["sudo", "rmdir", f"{storage_path}/{machine}"])


############################################################################################
@click.command()
@click.help_option("--help")
@click.option("-c", "--create", is_flag=True, help="Create nodes to manage")
@click.option("-w", "--wipe", is_flag=True, help="Wipe nodes created previously")
@click.option("-C", "--count", type=click.IntRange(1, 5000, clamp=True), required=True, is_eager=True, help="Create 'n' machines for use")
@click.option("-s", "--start", type=int, is_eager=True, default=1, help="First node is 'x'")
@click.option("-e", "--end", type=int, default=None, callback=validate_range, help="Last node is 'y'")
@click.option("-m", "--memory", type=int, default=1024, help="How much memory to allocate (eg: 1024, 2048, 4096)") 
@click.option("-n", "--network", default='maas', help="Which network to place these nodes on [default: 'maas']") 
@click.option("--vcpu", type=int, default=1, help="How many vCPUs to give each node")
@click.option("-d", "--debug", is_flag=True, help="Increase debug verbosity for all outputs - [disabled]")
def main(create, wipe, debug, count, start, end, memory, vcpu, network):

    total_machines = count
    if start > 1 and not end:
        total_machines = count - start
    elif start > 1 and end > 1:
        total_machines = end - start
    elif end < count:
        total_machines = end

    conn = None
    conn = libvirt.open("qemu:///system")

    if create:
        print(f"Creating a total of {total_machines} machines from {start} to {end}")
        create_machines(conn, start, end, memory, vcpu, network)

    if wipe:
        print(f"Destroying a total of {total_machines} machines from {start} to {end}")
        destroy_machines(conn, start, end)

    conn.close()


node_xml = """
<domain type="kvm">
<name>{machine}</name>
<memory unit="KiB">{memory}</memory>
<currentMemory unit="KiB">{memory}</currentMemory>
<vcpu placement="static">{vcpu}</vcpu>
<os>
    <type arch="x86_64" machine="pc-i440fx-disco">hvm</type>
    <boot dev="network" />
    <boot dev="hd" />
    <bootmenu enable="yes" />
</os>
<features>
    <acpi />
    <apic />
    <vmport state="off" />
</features>
<cpu mode="host-passthrough" check="none">
    <cache mode="passthrough" />
</cpu>
<clock offset="utc">
    <timer name="rtc" tickpolicy="catchup" />
    <timer name="pit" tickpolicy="delay" />
    <timer name="hpet" present="no" />
</clock>
<on_poweroff>destroy</on_poweroff>
<on_reboot>restart</on_reboot>
<on_crash>destroy</on_crash>
<pm>
    <suspend-to-mem enabled="no" />
    <suspend-to-disk enabled="no" />
</pm>
<devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type="file" device="disk">
        <driver name="qemu" type="qcow2" cache="writeback" io="threads" />
        <source file="{machine_path}/{machine}-d1.img" />
        <target dev="sda" bus="scsi" />
        <address type="drive" controller="0" bus="0" target="0" unit="0" />
    </disk>
    <disk type="file" device="disk">
        <driver name="qemu" type="qcow2" cache="writeback" io="threads" />
        <source file="{machine_path}/{machine}-d2.img" />
        <target dev="sdb" bus="scsi" />
        <address type="drive" controller="0" bus="0" target="0" unit="1" />
    </disk>
    <disk type="file" device="disk">
        <driver name="qemu" type="qcow2" cache="writeback" io="threads" />
        <source file="{machine_path}/{machine}-d3.img" />
        <target dev="sdc" bus="scsi" />
        <address type="drive" controller="0" bus="0" target="0" unit="2" />
    </disk>
    <controller type="scsi" index="0" model="virtio-scsi">
        <address type="pci" domain="0x0000" bus="0x00" slot="0x06" function="0x0" />
    </controller>
    <controller type="usb" index="0" model="ich9-ehci1">
        <address type="pci" domain="0x0000" bus="0x00" slot="0x07" function="0x7" />
    </controller>
    <controller type="usb" index="0" model="ich9-uhci1">
        <master startport="0" />
        <address type="pci" domain="0x0000" bus="0x00" slot="0x07" function="0x0" multifunction="on" />
    </controller>
    <controller type="usb" index="0" model="ich9-uhci2">
        <master startport="2" />
        <address type="pci" domain="0x0000" bus="0x00" slot="0x07" function="0x1" />
    </controller>
    <controller type="usb" index="0" model="ich9-uhci3">
        <master startport="4" />
        <address type="pci" domain="0x0000" bus="0x00" slot="0x07" function="0x2" />
    </controller>
    <controller type="pci" index="0" model="pci-root" />
    <controller type="virtio-serial" index="0">
        <address type="pci" domain="0x0000" bus="0x00" slot="0x08" function="0x0" />
    </controller>
    <interface type="network">
        <mac address="{mac1}" />
        <source network="{network}" />
        <model type="virtio" />
        <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x0" />
    </interface>
    <interface type="network">
        <mac address="{mac2}" />
        <source network="{network}" />
        <model type="virtio" />
        <address type="pci" domain="0x0000" bus="0x00" slot="0x04" function="0x0" />
    </interface>
    <serial type="pty">
        <target type="isa-serial" port="0">
            <model name="isa-serial" />
        </target>
    </serial>
    <console type="pty">
        <target type="serial" port="0" />
    </console>
    <channel type="spicevmc">
        <target type="virtio" name="com.redhat.spice.0" />
        <address type="virtio-serial" controller="0" bus="0" port="1" />
    </channel>
    <input type="mouse" bus="ps2" />
    <input type="keyboard" bus="ps2" />
    <graphics type="spice" autoport="yes">
        <listen type="address" />
        <image compression="off" />
        <mouse mode="client" />
        <clipboard copypaste="no" />
        <filetransfer enable="no" />
    </graphics>
    <sound model="ich6">
        <address type="pci" domain="0x0000" bus="0x00" slot="0x05" function="0x0" />
    </sound>
    <video>
        <model type="qxl" ram="65536" vram="256" vgamem="16384" heads="1" primary="yes" />
        <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x0" />
    </video>
    <redirdev bus="usb" type="spicevmc">
        <address type="usb" bus="0" port="1" />
    </redirdev>
    <redirdev bus="usb" type="spicevmc">
        <address type="usb" bus="0" port="2" />
    </redirdev>
    <memballoon model="virtio">
        <address type="pci" domain="0x0000" bus="0x00" slot="0x09" function="0x0" />
    </memballoon>
</devices>
</domain>
"""




if __name__ == "__main__":
    main()
