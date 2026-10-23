# Studying storage

Exercises that use the lab to learn how distributed storage behaves, rather
than to run it. Everything here is deliberate breakage and measurement on a
lab you can rebuild, so none of it belongs on a cluster you care about.

Read [Operations](operations.md) and [Instances](instances.md) first: this
manual assumes you can already reach the CLI and create volumes, and it does
not repeat the day-to-day commands.

## What the lab gives you

| | |
|---|---|
| Nodes | 3 (`os-1`, `os-2`, `os-3`), hyperconverged: control plane, compute and Ceph on each |
| OSDs | 2 per node, 250 GB each – 6 OSDs, ~1.5 TB raw, ~500 GB usable at 3 replicas |
| Failure domain | `host`, so three of them |
| Networks | Client traffic on `stor`, replication on its own isolated network ([NETWORK.md](../NETWORK.md)) |
| RBD pools | `volumes` (Cinder), `images` (Glance), `vms` (Nova), `backups` (cinder-backup) |
| Other pools | `gnocchi` (metrics), the RGW pools behind Swift and S3 |
| Cinder | Active-active `cinder-volume` on all three nodes, one cluster, coordinated through Valkey |
| Extras | Barbican for encrypted volumes, the Ceph dashboard, the `ceph_mgr` Prometheus exporter |

Three failure domains and six OSDs is the smallest cluster where CRUSH
behaviour, quorum and recovery are visible rather than theoretical. That is
the point of the exercises below.

### What the lab cannot teach you

All six OSDs share the Proxmox host's physical disks, and the storage and
replication networks share one NIC. So:

- **Relative comparisons and failure semantics are sound.** Replica versus
  erasure coding, where writes block, how much data moves during recovery.
- **Absolute numbers are not.** Throughput, latency and IOPS figures say more
  about `hddpool` than about Ceph. Do not quote them anywhere.

## Before you start

1. **Work as admin on the deployment host**, per the
   [conventions](README.md#conventions). Ceph commands are `sudo ceph ...`.

2. **Check the cluster is healthy.** Never start an exercise from a degraded
   cluster – you will not be able to tell your damage from the existing kind.

   ```sh
   sudo ceph -s                 # HEALTH_OK, all OSDs up/in
   sudo ceph osd tree           # 2 OSDs under each of the 3 hosts
   sudo ceph df                 # raw and per-pool usage
   ```

3. **Take a baseline** (see [Measuring](#measuring)) and keep it. Without
   one, every exercise below is just clicking.

4. **Know the way back.** Most exercises are undone by reverting the setting
   and waiting for `HEALTH_OK`; each section says how. If a cluster ends up
   wedged, [Recovery](operations.md#ceph) covers Ceph, and rebuilding the lab
   from scratch is always available.

Use your own scratch pools and volumes, named `lab-*` below, and leave the
pools OpenStack uses alone except where an exercise says otherwise.

## 1. RADOS, the layer under everything

### Replication versus erasure coding

The most instructive exercise in the lab: the trade-off is quantitative and
you can measure every side of it. Three hosts allow `k=2,m=1` at host
failure domain – 1.5× overhead against 3× for replication.

```sh
sudo ceph osd erasure-code-profile set lab-ec k=2 m=1 crush-failure-domain=host
sudo ceph osd erasure-code-profile get lab-ec

sudo ceph osd pool create lab-ec-pool erasure lab-ec
sudo ceph osd pool create lab-rep-pool
sudo ceph osd pool set lab-rep-pool size 3
```

Compare, for the same data:

```sh
sudo ceph df                      # usable capacity per pool: STORED vs USED
sudo rados bench -p lab-rep-pool 60 write --no-cleanup
sudo rados bench -p lab-ec-pool  60 write --no-cleanup
sudo rados bench -p lab-rep-pool 60 rand
sudo rados bench -p lab-ec-pool  60 rand
```

Then run both again with `-b 4096` for small writes, where erasure coding
has to read-modify-write a whole stripe. Watch the replication network in
Grafana while each runs.

- **For RBD on erasure coding** you also need
  `sudo ceph osd pool set lab-ec-pool allow_ec_overwrites true`.
- **Clean up**: `sudo rados -p lab-rep-pool cleanup` (and the EC pool), or
  delete the pools at the end of the section.

### CRUSH and failure domains

```sh
sudo ceph osd crush rule ls
sudo ceph osd crush rule dump replicated_rule
sudo ceph osd getcrushmap -o /tmp/crush.bin
crushtool -d /tmp/crush.bin -o /tmp/crush.txt   # read it
```

See for yourself that the rule descends to `host`, then prove what that
means: pick a PG with `sudo ceph pg ls-by-pool lab-rep-pool`, look at its
acting set, and confirm the three OSDs sit on three different hosts.

Now skew the distribution, which is what bites real clusters:

```sh
sudo ceph osd df tree                  # note how even the fill is
sudo ceph osd reweight <id> 0.5        # half the data of its peers
sudo ceph osd df tree                  # and again, after backfill settles
sudo ceph osd reweight <id> 1.0        # undo
```

### Placement groups

```sh
sudo ceph osd pool autoscale-status    # what the autoscaler chose, and why
```

Then set it badly on a scratch pool and watch per-OSD fill go uneven:

```sh
sudo ceph osd pool set lab-rep-pool pg_autoscale_mode off
sudo ceph osd pool set lab-rep-pool pg_num 4
sudo rados bench -p lab-rep-pool 60 write --no-cleanup
sudo ceph osd df                       # compare VAR and %USE across OSDs
sudo ceph osd pool set lab-rep-pool pg_autoscale_mode on
```

### Failure drills

Work up in severity, and wait for `HEALTH_OK` between drills.

1. **One OSD down.** `mon_osd_down_out_interval` is 600 s by default, so
   there is a grace period before data moves:

   ```sh
   sudo ceph orch daemon stop osd.<id>
   sudo ceph -s                    # degraded, not yet undersized
   sudo ceph orch daemon start osd.<id>
   ```

   Leave it down past ten minutes to see the OSD marked `out` and backfill
   start. `sudo ceph osd set noout` suppresses that, which is what you would
   do for planned maintenance.

2. **A whole node.** Reboot one node ([Rebooting one
   node](operations.md#rebooting-one-node)) and watch `degraded` versus
   `undersized`, recovery throughput, and what client I/O does meanwhile.

3. **Two OSDs on different hosts, replica-3.** With `min_size` at 2, writes
   to affected PGs stall – reads continue. This teaches `min_size` better
   than any document:

   ```sh
   sudo ceph osd pool get lab-rep-pool min_size
   sudo ceph orch daemon stop osd.<a>      # on one host
   sudo ceph orch daemon stop osd.<b>      # on another
   sudo rados bench -p lab-rep-pool 30 write    # blocks
   ```

   Start them again to recover. Do this on a scratch pool, not `volumes`:
   with the OSDs chosen badly it can stall instances and the control plane.

4. **The monitors.** One node down leaves 2 of 3 monitors – quorum holds.
   Stopping two breaks it and the cluster stops answering entirely. See
   [Stop](operations.md#stop) for taking the lab down cleanly instead.

### Scrubbing and repair

Worth doing once by hand, because watching Ceph catch silent corruption is
not the same as reading that it does.

```sh
sudo ceph pg ls-by-pool lab-rep-pool          # pick a PG, note its acting set
sudo ceph pg deep-scrub <pgid>                # baseline: scrub finds nothing
```

Then corrupt one replica's object in the OSD's store on the host holding it,
re-run the deep scrub to get an inconsistent PG, and repair it:

```sh
sudo ceph pg deep-scrub <pgid>
sudo ceph health detail                       # PG_DAMAGED, inconsistent
sudo rados list-inconsistent-obj <pgid> --format=json-pretty
sudo ceph pg repair <pgid>
```

## 2. Block storage: Cinder on RBD

The `standard` volume type is Ceph RBD at three replicas
([Volumes](instances.md#volumes)).

### Thin provisioning and copy-on-write clones

Images are uploaded raw precisely so Ceph clones them instead of copying
them. The gap between apparent and actual size *is* the lesson.

```sh
openstack volume create --size 50 --type standard lab-thin
sudo rbd -p volumes du                       # provisioned vs used
sudo rbd -p volumes ls
```

Boot an instance from an image, then follow the parent-child chain:

```sh
sudo rbd -p vms ls
sudo rbd -p vms info <disk>                  # 'parent:' points into images
sudo rbd -p images children <image>@snap     # every clone of that image
```

Then flatten one and watch the space get consumed:

```sh
sudo rbd -p vms du <disk>
sudo rbd -p vms flatten <disk>
sudo rbd -p vms du <disk>                    # no parent, full size
```

### Snapshots versus backups

The clearest way to internalise why a snapshot is not a backup.

```sh
openstack volume snapshot create --volume lab-thin lab-snap
sudo rbd -p volumes snap ls volume-<id>      # same pool, copy-on-write, cheap

openstack volume backup create --name lab-bk lab-thin
sudo rbd -p backups ls                       # a full copy, different pool
openstack volume backup create --name lab-bk2 --incremental lab-thin
```

Compare how long each takes and what each costs in `sudo ceph df`. Then ask
what each survives: a snapshot dies with its pool, a backup dies with the
cluster. Neither survives losing the lab.

### Active-active cinder-volume

All three nodes run `cinder-volume` in one cluster, coordinated through
Valkey. Distributed locking is usually invisible – here you can break it.

```sh
openstack volume service list                # three cinder-volume hosts, one cluster
openstack --os-volume-api-version 3.7 volume cluster list
```

Create volumes in a loop and watch which host services each request in the
logs ([Logs](operations.md#logs)). Then stop `cinder-volume` on one node
mid-operation and watch the work land elsewhere:

```sh
ssh ubuntu@os-2.openstack.home sudo docker stop cinder_volume
# create a volume, watch it succeed
ssh ubuntu@os-2.openstack.home sudo docker start cinder_volume
```

### Volume types and QoS

Connects storage policy to scheduler behaviour. Map a type onto the EC pool
from [above](#replication-versus-erasure-coding) to make the comparison
reachable from OpenStack, and cap another with QoS:

```sh
openstack volume qos create --consumer front-end \
  --property total_iops_sec=200 --property total_bytes_sec=20971520 lab-slow
openstack volume type create --property volume_backend_name=rbd-1 lab-capped
openstack volume qos associate lab-slow lab-capped
```

Attach one volume of each type to an instance and verify enforcement with
`fio` inside it. A cap that is set but not enforced is a common and quiet
misconfiguration, so check rather than assume.

### Encrypted volumes

Barbican is already enabled ([Secrets](services.md#secrets-barbican)).

```sh
openstack volume type create --encryption-provider luks \
  --encryption-cipher aes-xts-plain64 --encryption-key-size 256 \
  --encryption-control-location front-end lab-enc
openstack volume create --size 1 --type lab-enc lab-secret
```

Write a recognisable string to it from an instance, then confirm it is not
there at the RBD layer:

```sh
sudo rbd -p volumes export volume-<id> - | strings | grep -i <your-string>
```

Finding nothing is the result. Check where the key lives
(`openstack secret list`) and work out what an attacker with the OSD disks
has, and what one with Barbican has.

## 3. Object storage: RGW

Credentials and endpoints are in [Object
storage](services.md#object-storage). `radosgw-admin` is easiest through
`sudo cephadm shell -- radosgw-admin ...`.

### One backend, two APIs

Swift and S3 over the same RGW, with `ceph_rgw_swift_account_in_url` set.
Write through one, read through the other, and find where the models stop
lining up – ACLs and permissions, metadata, multipart against SLO/DLO,
container versus bucket naming.

```sh
openstack container create lab-box
openstack object create lab-box somefile
aws --endpoint-url <rgw-endpoint> s3 ls s3://lab-box
```

### Multipart uploads and garbage collection

Real operational ground that labs rarely cover.

```sh
# upload a few GB, interrupt it part-way
aws --endpoint-url <rgw-endpoint> s3 cp bigfile s3://lab-box/bigfile
aws --endpoint-url <rgw-endpoint> s3api list-multipart-uploads --bucket lab-box
sudo cephadm shell -- radosgw-admin gc list
sudo cephadm shell -- radosgw-admin gc process --include-all
sudo ceph df                     # space returns after GC, not after the abort
```

### Versioning and lifecycle

```sh
aws --endpoint-url <rgw-endpoint> s3api put-bucket-versioning \
  --bucket lab-box --versioning-configuration Status=Enabled
# delete an object, then list versions and recover it
aws --endpoint-url <rgw-endpoint> s3api list-object-versions --bucket lab-box
```

Then set a lifecycle rule with a short expiry and watch it run:

```sh
sudo cephadm shell -- radosgw-admin lc list
sudo cephadm shell -- radosgw-admin lc process
```

### Bucket index sharding

The classic RGW scaling failure, cheap to reach here. Push 100k small
objects into one bucket, then:

```sh
sudo cephadm shell -- radosgw-admin bucket stats --bucket lab-box
sudo cephadm shell -- radosgw-admin bucket limit check --uid <uid>
```

Watch listing latency grow, see dynamic resharding trigger, and compare the
index pool's PG load against the data pool's.

## Measuring

Do this first, not last. Prometheus already scrapes the `ceph_mgr`
exporter, so the data is there; Grafana and the Ceph dashboard are in [Web
interfaces](operations.md#web-interfaces).

Take the same measurement at all three layers, on the same workload:

| Layer | Tool |
|---|---|
| RADOS | `sudo rados bench -p <pool> 60 write --no-cleanup`, then `seq` and `rand` |
| RBD | `sudo rbd bench --io-type write --io-size 4K --io-threads 16 volumes/<img>` |
| Guest file system | `fio` inside an instance on an attached volume |

The overhead at each hop surprises most people the first time. Keep the
baseline so that every change above – EC against replica, a QoS cap, a node
failure, encryption – becomes a before-and-after you can defend.

Watch while a drill runs, not only after:

```sh
sudo ceph -w                        # cluster events as they happen
sudo ceph osd pool stats            # per-pool client and recovery I/O
sudo ceph pg stat
```

## Extensions worth building

- **Manila and CephFS.** The biggest gap: an MDS, metadata-heavy workloads
  and POSIX semantics are a whole topic the lab cannot currently reach. Of
  the extensions, this is the one most worth closing.
- **A second device class.** If the Proxmox host has SSD as well as
  `hddpool`, giving each node a mixed set of OSD disks opens up device
  classes, a CRUSH rule per class, and tiering. Node and disk sizing is in
  `variables.tf` (`osd_disk_count`, `osd_disk_gb`, `datastore_id`).
- **A second Cinder backend.** LVM or NFS alongside RBD makes the driver
  abstraction concrete, and lets you migrate volumes between unlike
  backends.

## Cleaning up

Scratch pools and profiles, once you are done with a section:

```sh
openstack volume delete lab-thin lab-secret
openstack volume type delete lab-capped lab-enc
openstack volume qos delete lab-slow
sudo ceph osd pool delete lab-ec-pool lab-ec-pool --yes-i-really-really-mean-it
sudo ceph osd pool delete lab-rep-pool lab-rep-pool --yes-i-really-really-mean-it
sudo ceph osd erasure-code-profile rm lab-ec
```

Then confirm you left nothing behind: `sudo ceph -s` is `HEALTH_OK`, every
OSD is `up`/`in` at weight 1, no pool has `pg_autoscale_mode off`, and no
flags are set (`sudo ceph osd dump | grep flags`).

Deleting pools needs `mon_allow_pool_delete`, which cephadm leaves off;
`sudo ceph config set mon mon_allow_pool_delete true` while you clean up,
and set it back to `false` afterwards.
