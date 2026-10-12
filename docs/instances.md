# Instances

Virtual machines, their disks, and the images and flavours they are built
from. Instance and volume disks all live in Ceph, so instances can move
between nodes without copying their disks.

The customer sections are written as the customer runs them, with their own
`clouds.yaml` entry ([Tenants](tenants.md#give-the-customer-a-cloudsyaml)):

```sh
export OS_CLOUD=acme     # or: demo, with the demo customer's details
```

As admin, add `--all-projects` to the list commands to see every customer's
resources, and `--project <id>` to narrow it to one.

## What's available

```sh
openstack flavor list
openstack image list
openstack network list
openstack keypair list
openstack security group list
openstack quota show --usage
```

| Flavour | vCPUs | RAM | Disk |
|---|---|---|---|
| `t1.tiny` | 1 | 512 MB | 5 GB |
| `gp1.small` | 1 | 2 GB | 20 GB |
| `gp1.medium` | 2 | 4 GB | 40 GB |
| `gp1.large` | 4 | 8 GB | 80 GB |
| `c1.medium` | 4 | 4 GB | 40 GB |
| `m1.medium` | 2 | 8 GB | 40 GB |

| Image | Login user |
|---|---|
| `ubuntu-24.04` | `ubuntu` |
| `debian-13` | `debian` |
| `cirros-0.6.3` | `cirros`, password `gocubsgo` (test image) |

## Create an instance

1. **Key pair**, once per user:

   ```sh
   openstack keypair create --public-key ~/.ssh/id_ed25519.pub mykey
   ```

2. **Instance**:

   ```sh
   openstack server create --flavor gp1.small --image ubuntu-24.04 \
     --network acme-net --key-name mykey --security-group ssh-icmp \
     --wait web-1
   ```

   Options worth knowing:

   | Option | Effect |
   |---|---|
   | `--boot-from-volume 30` | Root disk as a 30 GB Cinder volume instead of the flavour's disk, which can be snapshotted, backed up and grown like any volume |
   | `--user-data cloud-init.yaml` | cloud-init configuration, run on first boot |
   | `--min 3 --max 3` | Three at once, named `web-1-1` … |
   | `--hint group=<server-group-id>` | Place it according to a server group, see below |
   | `--availability-zone nova:os-2` | Pin it to a node (admin only) |

   Both disk types are on Ceph and cloned from the image, so starting is
   quick either way.

3. **Floating IP**, to reach it from the LAN:

   ```sh
   openstack floating ip create public
   openstack server add floating ip web-1 <floating-ip>
   ```

   Floating IPs come from `192.168.37.100–250`, which the LAN routes to the
   lab.

4. **Log in**:

   ```sh
   ssh ubuntu@<floating-ip>
   ```

   If it doesn't answer, check the security group allows the traffic, then
   the console log:

   ```sh
   openstack console log show web-1 | tail -40
   ```

### Spreading instances over nodes

For instances that back each other up, use a server group, so they never
share a node:

```sh
openstack server group create --policy anti-affinity web
openstack server create ... --hint group=<group-id> web-2
```

With three nodes, a strict anti-affinity group holds at most three
instances. Use `--policy soft-anti-affinity` to allow more.

## Inspect

```sh
openstack server list
openstack server show web-1                 # status, addresses, fault if it failed
openstack server event list web-1           # what happened to it, and when
openstack console log show web-1
openstack console url show web-1            # browser console (noVNC)
```

As admin, `openstack server show` also shows which node it runs on
(`OS-EXT-SRV-ATTR:host`).

## Change

| Task | Command |
|---|---|
| Stop, start, reboot | `openstack server stop / start / reboot [--hard] web-1` |
| Pause (in memory) | `openstack server pause / unpause web-1` |
| Suspend (to disk) | `openstack server suspend / resume web-1` |
| Shelve (frees the node's CPU and RAM; quota still counts) | `openstack server shelve / unshelve web-1` |
| Rename | `openstack server set --name web-01 web-1` |
| Add a security group | `openstack server add security group web-1 <group>` |
| Add a network | `openstack server add network web-1 <network>` |
| Rescue (boot from a clean image to fix the disk) | `openstack server rescue --image ubuntu-24.04 web-1`, then `unrescue` |
| Reinstall from an image (keeps the IP, wipes the disk) | `openstack server rebuild --image ubuntu-24.04 web-1` |

### Resize

```sh
openstack server resize --flavor gp1.medium --wait web-1
openstack server resize confirm web-1        # or: resize revert
```

The instance restarts, possibly on another node. It stays in
`VERIFY_RESIZE` until confirmed; Nova confirms on its own after a day. The
disk can grow, not shrink. Boot-from-volume instances keep their volume size;
extend the volume separately.

### Snapshot

```sh
openstack server image create --name web-1-2026-10-12 --wait web-1
openstack server create --image web-1-2026-10-12 ...   # a new instance from it
```

The snapshot is an image in the project. On Ceph it is a copy-on-write
clone, so it's fast; quiesce the application first if it writes a lot. For
boot-from-volume instances the snapshot is a volume snapshot plus a small
image that points at it.

## Delete

```sh
openstack server delete --wait web-1
openstack floating ip delete <floating-ip>    # floating IPs stay allocated otherwise
```

Volumes attached to it are detached and kept, and so is a root volume
created with `--boot-from-volume`. Delete those separately if they're no
longer needed (`openstack volume list --status available`).

## Volumes

Block storage on Ceph (volume type `standard`, three replicas).

```sh
openstack volume create --size 50 --type standard data-1
openstack server add volume web-1 data-1          # appears as /dev/sdb or similar
openstack volume list
```

Inside the instance, format and mount it as any disk. Then:

| Task | Command |
|---|---|
| Detach | `openstack server remove volume web-1 data-1` (unmount it first) |
| Grow, attached or not | `openstack --os-volume-api-version 3.42 volume set --size 100 data-1`, then grow the file system inside |
| Snapshot | `openstack volume snapshot create --volume data-1 [--force] data-1-snap` (`--force` while attached) |
| New volume from a snapshot | `openstack volume create --snapshot data-1-snap --size 50 data-1-copy` |
| Back up (to the `backups` pool) | `openstack volume backup create [--force] [--incremental] --name data-1-bk data-1` |
| Restore a backup | `openstack volume backup restore data-1-bk data-1-restored` |
| Move to another project | `openstack volume transfer request create data-1`, then the other project runs `openstack volume transfer request accept --auth-key <key> <id>` |
| Delete | `openstack volume delete data-1` (after removing its snapshots) |

Snapshots live in the same pool as the volume, so they don't protect against
losing the cluster. Backups go to a different pool but the same cluster; for
real disaster recovery, copy data out of the lab.

## Admin tasks

### Flavours

```sh
openstack flavor create --vcpus 8 --ram 16384 --disk 100 gp1.xlarge
```

- **Private flavour** for one customer: add `--private`, then
  `openstack flavor set --project <project-id> gp1.xlarge`.
- **Change** a flavour: you can't. Create a new one and delete the old;
  existing instances keep their size. Customers move with a resize.
- **Delete**: `openstack flavor delete gp1.xlarge`.
- Add them to `flavors:` in `ansible/group_vars/openstack.yml` to have
  `cloud.yml` recreate them in a rebuilt lab.

### Public images

Upload images raw, so Ceph clones them instead of copying them for every
instance:

```sh
cd /var/cache/openstack-lab
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qemu-img convert -p -O raw noble-server-cloudimg-amd64.img ubuntu-24.04-20261012.raw
openstack image create --disk-format raw --container-format bare --public \
  --file ubuntu-24.04-20261012.raw \
  --property os_distro=ubuntu --property hw_qemu_guest_agent=yes \
  --property hw_disk_bus=scsi --property hw_scsi_model=virtio-scsi \
  ubuntu-24.04-20261012
```

**Refreshing** an image without breaking anyone: upload the new one under a
dated name, then rename them so the plain name points at the new one, and
hide the old one so it stays usable for rebuilds but drops out of the list:

```sh
openstack image set --name ubuntu-24.04-old ubuntu-24.04
openstack image set --name ubuntu-24.04 ubuntu-24.04-20261012
openstack image set --hidden ubuntu-24.04-old
```

An image can only be deleted once no instance, snapshot or volume is cloned
from it (`openstack image delete` fails with `in use` otherwise).

Customers can upload their own images (`--private`, the default). Uploaded
as qcow2 they work, but each instance then gets a full copy instead of a
clone.

To keep `cloud.yml` in step, change `images:` in
`ansible/group_vars/openstack.yml`.

### Capacity

```sh
openstack hypervisor list --long
openstack resource provider list
openstack resource provider usage show <provider-uuid>
openstack resource provider inventory list <provider-uuid>
```

Each node has 16 vCPUs and 62 GB of RAM. Nova overcommits CPU 4:1 by
default, but not RAM. Ceph and the control plane use about 24 GB on each
node, which Nova doesn't know about: it reserves only 512 MB. To stop it
promising memory that isn't there, add to `/etc/kolla/config/nova.conf`:

```ini
[DEFAULT]
reserved_host_memory_mb = 28672
```

and apply it with `kolla-ansible reconfigure -i /etc/kolla/multinode -t nova`
([Changing the configuration](operations.md#changing-the-configuration)).
`No valid host was found` on create usually means no node has the RAM left.

### Moving instances between nodes

Live migration, with no downtime. The disks stay in Ceph, so only memory is
copied:

```sh
openstack server migrate --live-migration --wait web-1               # Nova picks the node
openstack server migrate --live-migration --host os-3 --wait web-1   # you pick it
```

Cold migration (the instance restarts): `openstack server migrate --wait
web-1`, then `openstack server resize confirm web-1`.

### Emptying a node for maintenance

```sh
openstack compute service set --disable --disable-reason "maintenance" os-2 nova-compute
for s in $(openstack server list --all-projects --host os-2 -f value -c ID); do
  openstack server migrate --live-migration --wait "$s"
done
openstack server list --all-projects --host os-2      # should be empty
```

Afterwards: `openstack compute service set --enable os-2 nova-compute`.
Instances don't move back by themselves; spread them again by hand if
needed.

### A node that died

If a node is down and won't come back soon, rebuild its instances elsewhere
from their Ceph disks. Make sure the node really is off first (in Proxmox),
or the same disk ends up in use twice.

```sh
openstack compute service set --down os-2 nova-compute
for s in $(openstack server list --all-projects --host os-2 -f value -c ID); do
  openstack server evacuate "$s"
done
```

When the node is back, Nova cleans up the old copies on start;
`openstack compute service set --up --enable os-2 nova-compute` brings it
back into use.
