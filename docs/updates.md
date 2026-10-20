# Updates

Everything in the lab that needs updating, and how to do it without taking
the cloud down. Unattended upgrades are off on the nodes on purpose: an
unplanned Docker upgrade restarts every container on a node.

| What | How often | Downtime | Section |
|---|---|---|---|
| Node OS (Ubuntu, kernel, Docker) | Monthly, or for security fixes | None for the control plane; instances move or restart | [Patching the node OS](#patching-the-node-os) |
| OpenStack, within 2026.1 | Monthly or so | Brief API blips | [Minor updates](#openstack-minor-updates) |
| OpenStack, to a new release | Every six or twelve months | Brief API blips; a rollback plan is advised | [Release upgrades](#openstack-release-upgrades) |
| Ceph | When a point release comes out | None | [Ceph](#ceph) |
| Images: guest and amphora | When the distributions publish new ones | None | [Images](#images) |
| Certificates | Before **11 October 2027** | Brief | [Certificates](#certificates) |
| The Proxmox host | Monthly | The whole lab | [The Proxmox host](#the-proxmox-host) |

## Before you start

For anything beyond OS patching, take a backup first.

**Configuration** (on `os-1`):

```sh
sudo tar czf ~/kolla-etc-$(date +%F).tgz /etc/kolla
```

Copy it off the node: `scp ubuntu@os-1.openstack.home:kolla-etc-*.tgz secrets/`.

**Databases** (on any node):

```sh
pw=$(sudo awk '/^database_password:/ {print $2}' /etc/kolla/passwords.yml)
sudo docker exec mariadb mariadb-dump -uroot -p"$pw" --all-databases \
  --single-transaction --routines --events | gzip > ~/mariadb-$(date +%F).sql.gz
```

Only `os-1` has `passwords.yml`; on another node take the password from
`secrets/passwords.yml`.

**The whole lab**, before a release upgrade: snapshot the three VMs with the
lab stopped ([Stop](operations.md#stop)). On lenora:

```sh
for id in 9201 9202 9203; do qm snapshot $id pre-upgrade --description "before 2026.2"; done
```

Rolling back is then `qm rollback <id> pre-upgrade` on all three, followed by
the [start procedure](operations.md#start). Snapshots on ZFS cost little at
first but grow as the disks change; delete them once the upgrade has proved
itself (`qm delsnapshot <id> pre-upgrade`). OpenTofu doesn't notice them.

**Health**: run the [health checks](operations.md#health-checks). Don't
start an update on a cloud that is already unhealthy.

## Patching the node OS

One node at a time. Never start the next until the previous one is fully
back: Galera and RabbitMQ survive one node away, not two.

For each of `os-3`, `os-2` and then `os-1`:

1. **Move the instances off it**, on `os-1`, as in
   [Emptying a node](instances.md#emptying-a-node-for-maintenance):

   ```sh
   N=os-3
   openstack compute service set --disable --disable-reason "patching" $N nova-compute
   for s in $(openstack server list --all-projects --host $N -f value -c ID); do
     openstack server migrate --live-migration --wait "$s"
   done
   ```

   Skipping this is fine for a lab; the instances then restart with the node.

2. **Tell Ceph not to rebalance**. `noout` is a cluster-wide flag, so run this
   once, on any node:

   ```sh
   sudo ceph osd set noout
   ```

3. **Upgrade and reboot**, on the node:

   ```sh
   sudo apt update
   apt list --upgradable
   sudo apt full-upgrade
   sudo reboot
   ```

   When patching `os-1`, the venv and the CLI are away until it is back;
   `sudo ceph` works on every node in the meantime.

4. **Wait until it is back**, then check:

   ```sh
   sudo ceph -s                           # all OSDs up, PGs active+clean
   kolla-ansible check -i /etc/kolla/multinode
   ```

   and [Galera](operations.md#galera-status): cluster size 3, `Synced`.

5. **Let Ceph rebalance again and re-enable compute**:

   ```sh
   sudo ceph osd unset noout
   openstack compute service set --enable $N nova-compute
   ```

6. Next node.

Afterwards, spread the instances out again if needed: everything that was on
`os-1` is now on `os-2` or `os-3`.

**ceph-common** on the nodes comes from Ubuntu and may move to a newer Squid
point release than the cluster runs. That's fine: newer clients talk to
older clusters. See [Ceph](#ceph) for the other direction.

## OpenStack minor updates

Within 2026.1, fixes arrive as new Kolla-Ansible commits on
`stable/2026.1` and as rebuilt images under the same tag
(`2026.1-ubuntu-noble`). On `os-1`:

1. **Update Kolla-Ansible** and its dependencies:

   ```sh
   source /opt/kolla/venv/bin/activate
   pip install --upgrade "git+https://opendev.org/openstack/kolla-ansible@stable/2026.1"
   kolla-ansible install-deps
   ```

2. **Merge new passwords**, in case the update added any. New entries are
   generated, existing ones kept:

   ```sh
   cd /etc/kolla
   cp passwords.yml passwords.yml.old
   cp /opt/kolla/venv/share/kolla-ansible/etc_examples/kolla/passwords.yml passwords.yml.new
   kolla-genpwd -p passwords.yml.new
   kolla-mergepwd --old passwords.yml.old --new passwords.yml.new --final passwords.yml
   diff <(cut -d: -f1 passwords.yml.old) <(cut -d: -f1 passwords.yml)   # new keys, if any
   rm passwords.yml.new
   ```

3. **Pull, check and upgrade**:

   Horizon isn't pulled: the lab builds its own image on top of Kolla's
   (Kolla's image with the lab's dashboard patches). Rebuild it first, from
   your own machine, so it starts from the new upstream image:

   ```sh
   ansible-playbook ansible/horizon.yml
   ```

   If a patch no longer applies, the build fails. Either upstream has
   merged it (delete it from `ansible/templates/horizon/patches`) or the code
   around it changed (refresh it from the branch it came from).

   Then, on `os-1`:

   ```sh
   kolla-ansible pull -i /etc/kolla/multinode --skip-tags horizon
   kolla-ansible prechecks -i /etc/kolla/multinode --use-test-images
   kolla-ansible upgrade -i /etc/kolla/multinode
   ```

   `upgrade` runs the database migrations and restarts the services one node
   at a time. It takes about as long as a deploy. Add `-t <service>` to
   update one service only.

4. **Check** the [health](operations.md#health-checks), boot a test
   instance, and clean up the old images:

   ```sh
   kolla-ansible prune-images -i /etc/kolla/multinode --yes-i-really-really-mean-it
   ```

5. **Update the clients** in the venv:

   ```sh
   pip install --upgrade -c https://releases.openstack.org/constraints/upper/2026.1 \
     python-openstackclient python-octaviaclient python-designateclient \
     python-heatclient python-barbicanclient gnocchiclient python-cloudkittyclient openstacksdk
   ```

## OpenStack release upgrades

Kolla-Ansible upgrades one release at a time (2026.1 → 2026.2), or straight
from one SLURP release to the next (2026.1 → 2027.1). Not further.

1. **Read the release notes** for Kolla-Ansible and for each service the lab
   runs, for removed options and upgrade notes. Check the new release still
   supports Ubuntu 24.04; if it needs a newer Ubuntu, that upgrade comes
   first, node by node, and is a project of its own.

2. **Back up and snapshot** as in [Before you start](#before-you-start).

3. **Change the release in the repository**, `ansible/group_vars/openstack.yml`:

   ```yaml
   openstack_release: "2026.2"
   ```

   Commit it; this is what the playbooks deploy from now on.

4. **Upgrade Kolla-Ansible and the clients**, on `os-1`:

   ```sh
   source /opt/kolla/venv/bin/activate
   pip install --upgrade "git+https://opendev.org/openstack/kolla-ansible@stable/2026.2"
   kolla-ansible install-deps
   pip install --upgrade -c https://releases.openstack.org/constraints/upper/2026.2 \
     python-openstackclient python-octaviaclient python-designateclient \
     python-heatclient python-barbicanclient gnocchiclient python-cloudkittyclient openstacksdk
   ```

5. **Merge the passwords**, as in step 2 of [Minor updates](#openstack-minor-updates).

6. **Rewrite `globals.yml`** with the new release, from your own machine:

   ```sh
   ansible-playbook ansible/kolla-host.yml --tags kolla-config
   ```

   Then, on `os-1`, check that the settings in it still exist in the new
   release (the release notes list removed and renamed ones):

   ```sh
   kolla-ansible validate-config -i /etc/kolla/multinode
   ```

   Fix anything in `ansible/templates/globals.yml.j2` and run the playbook
   again.

7. **Pull, check and upgrade**:

   Horizon isn't pulled: the lab builds its own image on top of Kolla's
   (Kolla's image with the lab's dashboard patches). Rebuild it first, from
   your own machine, so it starts from the new upstream image:

   ```sh
   ansible-playbook ansible/horizon.yml
   ```

   If a patch no longer applies, the build fails. Either upstream has
   merged it (delete it from `ansible/templates/horizon/patches`) or the code
   around it changed (refresh it from the branch it came from).

   Then, on `os-1`:

   ```sh
   kolla-ansible pull -i /etc/kolla/multinode --skip-tags horizon
   kolla-ansible prechecks -i /etc/kolla/multinode --use-test-images
   kolla-ansible upgrade -i /etc/kolla/multinode
   ```

   If `upgrade` fails part-way, fix the cause and run it again; it picks up
   where things are. If it can't be fixed, roll back to the snapshots.

8. **Afterwards**:

   ```sh
   kolla-ansible post-deploy -i /etc/kolla/multinode
   kolla-ansible prune-images -i /etc/kolla/multinode --yes-i-really-really-mean-it
   ```

   Copy the refreshed credentials to `secrets/` from your own machine:

   ```sh
   for f in admin-openrc.sh clouds.yaml passwords.yml; do
     scp ubuntu@os-1.openstack.home:/etc/kolla/$f secrets/
   done
   ```

   Run the [health checks](operations.md#health-checks), the test from the
   README (boot, ping, SSH, Swift, a load balancer), and update the
   "Tested" section there. Remove the VM snapshots once satisfied.

## Ceph

The cluster runs `quay.io/ceph/ceph:v19.2.3` (Squid). cephadm upgrades it
daemon by daemon, keeping the cluster available.

1. **Check** it is healthy (`sudo ceph -s`; the BlueStore warning is fine)
   and see what runs now:

   ```sh
   sudo ceph versions
   ```

2. **Upgrade**:

   ```sh
   sudo ceph orch upgrade check --image quay.io/ceph/ceph:v19.2.4
   sudo ceph orch upgrade start --image quay.io/ceph/ceph:v19.2.4
   sudo ceph orch upgrade status        # or: sudo ceph -W cephadm
   ```

   Pause with `ceph orch upgrade pause`, abandon with `ceph orch upgrade
   stop`. When it's done, `ceph versions` shows one version throughout.

3. **Record it** in `ceph_image` in `ansible/group_vars/openstack.yml`.

Mind the comment there: later Squid releases (19.2.6 at least) create new
client keys in a format older clients can't read. The keys OpenStack uses already exist and
keep working; the risk is in creating new ones (re-running `ceph.yml`
against a cluster that lacks them, or a rebuilt lab). The node CLI must be
at least as new as the cluster (`ceph --version` on the nodes); the
OpenStack containers ship a newer Ceph client than the cluster runs, so they
are not the limit. Test after upgrading: create and attach a volume, boot an
instance, upload an image.

**Major releases** (Squid → Tentacle) work the same way, after reading the
upgrade notes for that release.

## Images

### Guest images

Refresh `ubuntu-24.04` and `debian-13` from time to time, so new instances
don't start with months of updates to install. See
[Public images](instances.md#public-images).

### Amphora image

Octavia uses the newest image tagged `amphora` in the `service` project. On
`os-1`:

```sh
cd /var/cache/openstack-lab
wget -O amphora-new.qcow2 https://tarballs.opendev.org/openstack/octavia/test-images/test-only-amphora-x64-haproxy-ubuntu-noble.qcow2
qemu-img convert -p -O raw amphora-new.qcow2 amphora-new.raw
openstack image create --disk-format raw --container-format bare --private \
  --project service --tag amphora --file amphora-new.raw amphora-x64-haproxy-$(date +%F)
openstack image unset --tag amphora amphora-x64-haproxy
```

Existing load balancers keep their amphorae until failed over:

```sh
for lb in $(openstack loadbalancer list -f value -c id --provider amphora); do
  openstack loadbalancer failover --wait "$lb"
done
```

Delete the old image once no amphora uses it.

## Certificates

| Certificate | Expires | Used for |
|---|---|---|
| Lab CA, `/etc/kolla/certificates/ca/root.crt` | 31 July 2029 | Signs the public endpoint and Ceph dashboard certificates |
| Public endpoints, `/etc/kolla/certificates/haproxy.pem` | **11 October 2027** | HTTPS on `api.openstack.home` |
| Octavia client, `/etc/kolla/config/octavia/client.cert-and-key.pem` | **11 October 2027** | Octavia's controllers talking to amphorae |
| Ceph dashboard, `/etc/ceph/dashboard/dashboard.crt` | 14 January 2029 | HTTPS on the dashboard, every node |
| Octavia CAs | October 2036 | Sign the above and the amphorae's certificates |

Check with `openssl x509 -noout -enddate -in <file>` on `os-1`, or for Octavia:

```sh
kolla-ansible octavia-certificates -i /etc/kolla/multinode --check-expiry 60
```

### Renew the Ceph dashboard certificate

Remove it and re-run the Ceph playbook, which signs a new one and restarts
the dashboard. On `os-1`, then from the repository:

```sh
sudo rm /etc/ceph/dashboard/dashboard.crt
ansible-playbook ansible/ceph.yml
```

### Renew the public endpoint certificate

Kolla-Ansible only creates certificates that are missing, so remove the old
one first. Same CA, so clients need nothing new. On `os-1`:

```sh
mkdir -p ~/old-certs
mv /etc/kolla/certificates/haproxy.pem /etc/kolla/certificates/private/external/external.{crt,csr,key} ~/old-certs/
kolla-ansible certificates -i /etc/kolla/multinode
kolla-ansible reconfigure -i /etc/kolla/multinode -t haproxy
```

### Renew the Octavia client certificate

```sh
mkdir -p ~/old-certs
cp -a /etc/kolla/config/octavia ~/old-certs/
cd /etc/kolla/octavia-certificates/client_ca
mv client.cert.pem client.csr.pem client.key.pem client.cert-and-key.pem ~/old-certs/
kolla-ansible octavia-certificates -i /etc/kolla/multinode
kolla-ansible reconfigure -i /etc/kolla/multinode -t octavia
```

Then check that load balancers stay `ONLINE` (`openstack loadbalancer list`).

## The Proxmox host

Updating and rebooting lenora takes the whole lab down.

1. [Stop the lab](operations.md#stop).
2. On lenora: `apt update && apt full-upgrade`, then reboot if a new kernel
   came in.
3. Check nested virtualisation survived: `cat
   /sys/module/kvm_intel/parameters/nested` (or `kvm_amd`) says `Y`. If not,
   re-run `ansible-playbook ansible/prepare-proxmox.yml`.
4. [Start the lab](operations.md#start).

Major Proxmox upgrades (8 → 9 and so on) follow Proxmox's own upgrade guide;
check afterwards that the SDN zone `openstk` and its vnets are still there
(Datacenter → SDN), and re-run `ansible-playbook ansible/bootstrap.yml` if
not.
