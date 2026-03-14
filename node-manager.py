#!/usr/bin/env python3

import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import click
import libvirt
from randmac import RandMac
from tqdm import tqdm


# Tunables go here, very little need to touch anything else These values
# control where VM storage lives and how new nodes are provisioned when
# the script runs.
version        = 1.02
storage_path   = Path("/storage/images/maas")
storage_format = "raw"
node_name      = "maas-node"
nic_model      = "virtio"
disk_sizes     = [60, 300, 300]


# Logging handler that works with tqdm so the parallel log output does
# not corrupt the progress bar while nodes are being created or
# destroyed.
class TqdmLoggingHandler(logging.Handler):
    def emit(self, record):
        try:
            msg = self.format(record)
            tqdm.write(msg)
            self.flush()
        except Exception:
            print(record.getMessage())


# Build the minimal base domain XML used when defining a default VM.
# Most device configuration is attached afterward so the XML here stays
# small and easy to maintain. I've added some tweaks for
# hyperconverged, over-subscribed VMs on the same host.
def build_base_domain(machine, memory_mb, vcpu):
    return f"""
<domain type="kvm">
  <name>{machine}</name>

  <memory unit="MiB">{memory_mb}</memory>
  <vcpu placement="static">{vcpu}</vcpu>

  <blkiotune>
    <weight>500</weight>
  </blkiotune>

  <cputune>
    <shares>2048</shares>
  </cputune>

  <os>
    <type arch="x86_64" machine="pc-q35-noble">hvm</type>
    <boot dev="network"/>
    <boot dev="hd"/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <pae/>
    <hap state="on"/>
    <vmport state="off"/>
  </features>

  <cpu mode="host-passthrough" check="none" migratable="off">
    <topology sockets="1" dies="1" cores="{vcpu}" threads="1"/>
  </cpu>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <memballoon model="virtio"/>
  </devices>
</domain>
"""


# Attach virtio disks to an already-defined domain XML. Disks are created
# separately through storage pools and then connected to the domain
# using libvirt device XML.
def attach_disk(dom, path, dev):
    disk_xml = f"""
<disk type='file' device='disk'>
  <driver name='qemu' type='raw' cache='none' io='native'/>
  <source file='{path}'/>
  <target dev='{dev}' bus='virtio'/>
</disk>
"""
    dom.attachDeviceFlags(disk_xml, libvirt.VIR_DOMAIN_AFFECT_CONFIG)


# Attach a bridged NIC to the domain. MAAS will later discover these
# MACs and associate them with nodes when it does its commissioning.
def attach_nic(dom, mac, bridge, model):
    nic_xml = f"""
<interface type='bridge'>
  <mac address='{mac}'/>
  <source bridge='{bridge}'/>
  <model type='{model}'/>
</interface>
"""
    dom.attachDeviceFlags(nic_xml, libvirt.VIR_DOMAIN_AFFECT_CONFIG)


# Generate the XML block describing a libvirt storage pool dedicated to
# a single VM. Each node receives its own pool so disks remain isolated
# and easier to clean up later. This was initially quite messy.
def generate_pool_xml(machine: str, path: Path) -> str:
    return f"""
<pool type='dir'>
  <name>{machine}</name>
  <target>
    <path>{path}</path>
  </target>
</pool>
"""


# Generate the XML block describing a disk volume inside the node’s pool.
# Disks are preallocated logically but start with zero allocation to
# keep provisioning fast until bytes are scribbled to the storage.
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
  </target>
</volume>
"""


# Create the storage pool and associated volumes for each VM. Pools are
# built, started, and configured to autostart so libvirt maintains them
# across host restarts.
def create_storage(conn, machine: str):
    pool_path = storage_path / machine
    pool_path.mkdir(parents=True, exist_ok=True)

    pool_xml = generate_pool_xml(machine, pool_path)

    pool = conn.storagePoolDefineXML(pool_xml, 0)
    pool.build(0)
    pool.create(0)
    pool.setAutostart(True)

    for idx, size in enumerate(disk_sizes, start=1):
        vol_xml = generate_volume_xml(machine, idx, size, pool_path)
        pool.createXML(vol_xml, 0)

    pool.refresh()


# Destroy the storage pool and all associated volumes for a VM. This is
# necessary when wiping nodes between test resets or rebuilds.
def destroy_storage(conn, machine: str):
    try:
        pool = conn.storagePoolLookupByName(machine)

        for vol in pool.listVolumes():
            try:
                pool.storageVolLookupByName(vol).delete()
            except libvirt.libvirtError:
                pass

        pool.destroy()
        pool.undefine()

    except libvirt.libvirtError:
        pass

    try:
        (storage_path / machine).rmdir()
    except OSError:
        pass


# Format node names consistently so MAAS sees deterministic hostnames, eg:
# maas-node-01, maas-node-02, etc.
def format_machine_name(idx: int, end: int) -> str:
    width = max(2, len(str(end)))
    return f"{node_name}-{idx:0{width}d}"


# Worker routine executed by the thread pool when creating the nodes.
def create_machine_worker(idx, end, memory, vcpu, bridge, nic):

    conn = libvirt.open("qemu:///system")
    if conn is None:
        raise RuntimeError("Failed to open libvirt connection")

    machine = format_machine_name(idx, end)

    create_storage(conn, machine)

    mac1 = RandMac("52:54:00:00:00:00", False)
    mac2 = RandMac("52:54:00:00:00:00", False)

    xml = build_base_domain(machine, memory, vcpu)

    dom = conn.defineXML(xml)

    machine_path = storage_path / machine

    # Attach disks sequentially
    for disk_idx, size in enumerate(disk_sizes, start=1):
        dev = f"vd{chr(ord('a') + disk_idx - 1)}"
        attach_disk(dom, f"{machine_path}/{machine}-d{disk_idx}.img", dev)

    # Attach two NICs so MAAS can PXE and provision the node for bridges or
    # openstack deployments through juju bundles/terraform
    attach_nic(dom, mac1, bridge, nic)
    attach_nic(dom, mac2, bridge, nic)

    conn.close()

    return machine


# Parallel node creation driver. Initializes a thread pool to provision
# multiple VMs simultaneously while tqdm provides progress feedback on
# the main thread.
def create_machines(conn, start, end, memory, vcpu, bridge, nic):

    total = end - start + 1

    # Select a conservative worker count to avoid saturating libvirt
    workers = min(16, os.cpu_count() or 4)

    with ThreadPoolExecutor(max_workers=workers) as executor:

        futures = []

        for idx in range(start, end + 1):
            futures.append(
                executor.submit(
                    create_machine_worker,
                    idx,
                    end,
                    memory,
                    vcpu,
                    bridge,
                    nic,
                )
            )

        with tqdm(total=total, desc="Creating nodes") as pbar:
            for future in as_completed(futures):
                future.result()
                pbar.update(1)


# Sequential destruction routine for nodes and their storage pools. Used
# when resetting the lab environment from 'n' nodes to 0.
def destroy_machines(conn, start, end):

    for idx in tqdm(range(start, end + 1), desc="Destroying nodes"):

        machine = format_machine_name(idx, end)

        try:
            dom = conn.lookupByName(machine)

            if dom.isActive():
                dom.destroy()

            dom.undefine()

        except libvirt.libvirtError:
            pass

        destroy_storage(conn, machine)


# All the Click options go here. Add more as needed.
@click.command()
@click.option("-c", "--create", is_flag=True)
@click.option("-w", "--wipe", is_flag=True)
@click.option("-C", "--count", type=int, required=True)
@click.option("-s", "--start", default=1)
@click.option("-m", "--memory", default=1024)
@click.option("--vcpu", default=1)
@click.option("-b", "--bridge", default="br0")
@click.option("-N", "--nic", default=nic_model)
@click.option("-d", "--debug", is_flag=True)
def main(create, wipe, debug, count, start, memory, vcpu, bridge, nic):

    logging.root.handlers.clear()

    handler = TqdmLoggingHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s: %(message)s"))

    logging.getLogger().addHandler(handler)
    logging.getLogger().setLevel(logging.DEBUG if debug else logging.INFO)

    end = start + count - 1

    conn = libvirt.open("qemu:///system")

    if not conn:
        logging.error("Failed to connect to libvirt")
        return

    if create:
        create_machines(conn, start, end, memory, vcpu, bridge, nic)

    if wipe:
        destroy_machines(conn, start, end)

    conn.close()


if __name__ == "__main__":
    main()
