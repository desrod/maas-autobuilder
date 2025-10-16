#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import logging
import time
import click
import libvirt
from pathlib import Path
from randmac import RandMac
from tqdm import tqdm

version = 1.01
storage_path = Path("/storage/images/maas")
storage_format = "raw"  # Use raw images instead of qcow2
node_name = "maas-node"
nic_model = "virtio"
disk_sizes = [60, 300, 300]  # in GiB


class TqdmLoggingHandler(logging.Handler):
    """Logging handler that routes messages through tqdm.write()."""

    def emit(self, record):
        try:
            msg = self.format(record)
            tqdm.write(msg)
            self.flush()
        except Exception:
            # fallback to normal print if tqdm fails
            print(record.getMessage())


# Domain XML template (leaner & faster defaults for headless MAAS/juju nodes)
node_xml = """
<domain type="kvm" xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>{machine}</name>
  <memory unit="KiB">{memory}</memory>
  <currentMemory unit="KiB">{memory}</currentMemory>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
      <libosinfo:os id="http://ubuntu.com/ubuntu/22.04"/>
    </libosinfo:libosinfo>
  </metadata>
  <vcpu placement="static">{vcpu}</vcpu>
  <iothreads>{iothreads}</iothreads>
  <os>
    <type arch="x86_64" machine="q35">hvm</type>
    <loader readonly="yes" type="rom">/usr/share/ovmf/OVMF.fd</loader>
    <boot dev="network"/>
    <boot dev="hd"/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <pae/>
    <hap/>
    <vmport state="off"/>
  </features>
  <cpu mode="host-passthrough" check="none">
    <model name="host"/>
    <feature name="pcid" policy="require"/>
    <feature name="spec-ctrl" policy="require"/>
    <feature name="ssbd" policy="require"/>
    <feature name="pdpe1gb" policy="require"/>
    <topology sockets="1" cores="{vcpu}" threads="1"/>
  </cpu>
  <power_management>
    <suspend_mem/>
    <suspend_disk/>
    <suspend_hybrid/>
  </power_management>
  <migration_features>
    <live/>
    <uri_transports>
      <uri_transport>tcp</uri_transport>
    </uri_transports>
  </migration_features>
  <clock offset="utc">
    <timer name="rtc" tickpolicy="catchup" track="guest">
      <catchup threshold="123" slew="120" limit="10000"/>
    </timer>
    <timer name="pit" tickpolicy="delay"/>
    <timer name="hpet" present="no"/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled="no"/>
    <suspend-to-disk enabled="no"/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Disable ballooning for steadier performance -->
    <memballoon model="none"/>

    {disk_xml}

    <!-- (Removed USB controllers & virtio-serial/SPICE to cut emulator overhead) -->

    <controller type="pci" index="0" model="pcie-root"/>

    <!-- Faster RNG that won't block under boot storms -->
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>

    <interface type="bridge">
      <mac address="{mac1}"/>
      <link state="up"/>
      <source bridge="{bridge}"/>
      <mtu size="1500"/>
      <model type="{nic}"/>
      <driver name="vhost" queues="{vcpu}" packed="on"/>
      <address type="pci" domain="0x0000" bus="0x00" slot="0x11" function="0x0"/>
    </interface>

    <serial type="pty">
      <target type="isa-serial" port="0">
        <model name="isa-serial"/>
      </target>
    </serial>

    <console type="pty">
      <target type="serial" port="0"/>
    </console>
  </devices>
</domain>
"""


def validate_range(ctx, param, value):
    start = ctx.params["start"]
    count = ctx.params["count"]
    if value is None:
        return start + count - 1
    max_end = start + count - 1
    if value > max_end:
        logging.warning(
            f"Requested end={value} exceeds count limit; capping to {max_end}"
        )
        return max_end
    return value


def generate_pool_xml(machine: str, path: Path) -> str:
    return f"""
<pool type='dir'>
  <name>{machine}</name>
  <target>
    <path>{path}</path>
    <permissions>
      <mode>0755</mode>
      <owner>0</owner>
      <group>0</group>
    </permissions>
  </target>
</pool>
"""


def generate_volume_xml(
    machine: str, disk_number: int, disk_size: int, path: Path
) -> str:
    vol_name = f"{machine}-d{disk_number}.img"
    vol_path = path / vol_name
    return f"""
<volume type='file'>
  <name>{vol_name}</name>
  <capacity unit="G">{disk_size}</capacity>
  <allocation unit="G">0</allocation>
  <target>
    <path>{vol_path}</path>
    <format type='{storage_format}'/>
    <permissions>
      <mode>0644</mode>
      <owner>0</owner>
      <group>0</group>
    </permissions>
  </target>
</volume>
"""


def create_storage(conn, machine: str):
    pool_path = storage_path / machine
    pool_path.mkdir(parents=True, exist_ok=True)
    logging.debug(f"Ensured directory {pool_path}")

    pool_xml = generate_pool_xml(machine, pool_path)
    pool = conn.storagePoolDefineXML(pool_xml, 0)
    pool.build(0)
    pool.create(0)
    try:
        pool.setAutostart(True)
    except libvirt.libvirtError as e:
        logging.warning(f"Could not set autostart for pool {machine}: {e}")

    for idx, size in enumerate(disk_sizes, start=1):
        vol_xml = generate_volume_xml(machine, idx, size, pool_path)
        pool.createXML(vol_xml, 0)
    pool.refresh()


def destroy_storage(conn, machine: str):
    try:
        pool = conn.storagePoolLookupByName(machine)
        for vol in pool.listVolumes():
            try:
                pool.storageVolLookupByName(vol).delete()
            except libvirt.libvirtError as e:
                logging.warning(f"Couldn't delete volume {vol}: {e}")
        pool.destroy()
        pool.undefine()
        logging.info(f"Destroyed storage pool {machine}")
    except libvirt.libvirtError:
        logging.debug(f"No storage pool named {machine}")
    finally:
        try:
            (storage_path / machine).rmdir()
        except OSError:
            pass


def format_machine_name(idx: int, end: int) -> str:
    width = max(2, len(str(end)))
    return f"{node_name}-{idx:0{width}d}"


def make_disk_xml(machine_path, machine, disk_sizes):
    disk_entries = []
    # map 1 -> vda, 2 -> vdb, 3 -> vdc and iothreads 1,2,3 (virtio-blk)
    for idx, size in enumerate(disk_sizes, start=1):
        dev = f"vd{chr(ord('a') + idx - 1)}"
        disk_entries.append(
            f"""
    <disk type="file" device="disk">
      <driver name="qemu"
              type="raw"
              cache="none"
              io="threads"
              discard="unmap"
              detect_zeroes="unmap"
              iothread="{idx}"/>
      <source file="{machine_path}/{machine}-d{idx}.img"/>
      <target dev="{dev}" bus="virtio"/>
    </disk>"""
        )
    return "\n".join(disk_entries)


def create_machines(conn, start: int, end: int, memory: int, vcpu: int, bridge: str, nic: str):
    mem_kb = memory * 1024
    for idx in tqdm(range(start, end + 1), desc="Creating nodes"):
        machine = format_machine_name(idx, end)
        create_storage(conn, machine)

        mac1 = RandMac("00:00:00:00:00:00", False)
        disk_xml = make_disk_xml(storage_path / machine, machine, disk_sizes)
        xml = node_xml.format(
            machine=machine,
            memory=mem_kb,
            vcpu=vcpu,
            iothreads=len(disk_sizes),
            disk_xml=disk_xml,
            machine_path=storage_path / machine,
            mac1=mac1,
            bridge=bridge,
            nic=nic,
        )
        conn.defineXML(xml)
        time.sleep(0.1)


def destroy_or_undefine_domain(dom):
    try:
        if dom.isActive():
            dom.destroy()
        dom.undefine()
    except libvirt.libvirtError as e:
        logging.warning(f"Could not destroy/undefine {dom.name()}: {e}")


def destroy_machines(conn, start: int, end: int):
    for idx in tqdm(range(start, end + 1), desc="Destroying nodes"):
        machine = format_machine_name(idx, end)
        try:
            dom = conn.lookupByName(machine)
            destroy_or_undefine_domain(dom)
        except libvirt.libvirtError:
            logging.debug(f"No domain named {machine}")
        destroy_storage(conn, machine)


@click.command()
@click.option("-c", "--create", is_flag=True, help="Create nodes to manage")
@click.option("-w", "--wipe", is_flag=True, help="Wipe nodes created previously")
@click.option(
    "-C",
    "--count",
    type=click.IntRange(1, 5000, clamp=True),
    required=True,
    help="Total number of machines",
)
@click.option("-s", "--start", type=int, default=1, help="First node index")
@click.option(
    "-e",
    "--end",
    type=int,
    default=None,
    callback=validate_range,
    help="Last node index (capped to start+count-1)",
)
@click.option("-m", "--memory", type=int, default=1024, help="Memory in MB per node")
@click.option("--vcpu", type=int, default=1, help="vCPUs per node")
@click.option("-b", "--bridge", default="br0", help="Bridge name")
@click.option("-N", "--nic", default=nic_model, help="NIC model")
@click.option("-d", "--debug", is_flag=True, help="Enable DEBUG logging")
def main(create, wipe, debug, count, start, end, memory, vcpu, bridge, nic):
    # configure logging
    logging.root.handlers.clear()
    handler = TqdmLoggingHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s: %(message)s"))
    handler.setLevel(logging.INFO)
    logging.getLogger().addHandler(handler)
    logging.getLogger().setLevel(logging.DEBUG if debug else logging.INFO)

    if end is None:
        end = start + count - 1
    total = end - start + 1
    if total < 1:
        logging.error("No machines to manage (end < start)")
        return

    conn = libvirt.open("qemu:///system")
    if not conn:
        logging.error("Failed to connect to libvirt")
        return

    if create:
        click.echo(f"Creating {total} machines ({start}…{end})")
        create_machines(conn, start, end, memory, vcpu, bridge, nic)

    if wipe:
        click.echo(f"Destroying {total} machines ({start}…{end})")
        destroy_machines(conn, start, end)

    conn.close()
    logging.info("Done.")


if __name__ == "__main__":
    main()

