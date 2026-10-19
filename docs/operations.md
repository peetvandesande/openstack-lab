# Operations

Day-to-day running of the lab: getting in, starting and stopping it, checking
its health, reading logs, changing the configuration, recovering from
failures, and taking it down. See the [conventions](README.md#conventions) first.

## Access

### Web interfaces

Passwords are in `secrets/passwords.yml`.

| What | URL | User | Password |
|---|---|---|---|
| Horizon | [https://api.openstack.home/](https://api.openstack.home/) | `admin` (domain `Default`) | `keystone_admin_password` |
| Grafana | [https://api.openstack.home:3000/](https://api.openstack.home:3000/) | `admin` | `grafana_admin_password` |
| OpenSearch Dashboards | [https://api.openstack.home:5601/](https://api.openstack.home:5601/) | `opensearch` | `opensearch_dashboards_password` |
| Alertmanager | [https://api.openstack.home:9093/](https://api.openstack.home:9093/) | `admin` | `prometheus_alertmanager_password` |
| Prometheus | [http://192.168.32.10:9091/](http://192.168.32.10:9091/) (internal VIP only) | `admin` | `prometheus_password` |
| Ceph dashboard | [https://os-1.openstack.home:8443/](https://os-1.openstack.home:8443/) (or the active manager) | `admin` | `ceph_dashboard_password` |

Your browser needs to trust `secrets/root.crt`, the lab CA, which signs the
Ceph dashboard's certificate as well. On macOS:

```sh
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain secrets/root.crt
```

If `os-1` isn't the active manager, the Ceph dashboard redirects you to the
one that is, by IP address.

### CLI on the deployment host

See [Conventions](README.md#conventions). The clients for every service
(Nova, Neutron, Octavia, Designate, Heat, Barbican, Gnocchi, CloudKitty) are
in the virtualenv.

### CLI on your own machine

```sh
pipx install python-openstackclient
pipx inject python-openstackclient python-octaviaclient python-designateclient \
  python-heatclient python-barbicanclient
```

Make a copy of `clouds.yaml` that points at your copy of the CA. Keep it in
`secrets/`, which is git-ignored, but under a different name: a deploy
overwrites `secrets/clouds.yaml`.

```sh
sed "s#/etc/kolla/certificates/ca/root.crt#$PWD/secrets/root.crt#" \
  secrets/clouds.yaml > secrets/clouds-local.yaml
export OS_CLIENT_CONFIG_FILE=$PWD/secrets/clouds-local.yaml OS_CLOUD=kolla-admin
openstack token issue
```

`kolla-admin` is the admin project over the public endpoints; you need that
one from outside. `kolla-admin-system` is system scope, which a few
admin-only APIs need. The `-internal` entries only work from the nodes.

For a customer's own entry, see [Tenants](tenants.md#give-the-customer-a-cloudsyaml).

### Consoles

- Node consoles: Proxmox web UI on [https://lenora.home:8006/](https://lenora.home:8006/), VMs 9201–9203
  in pool `openstack-lab`.
- Instance consoles: Horizon, or `openstack console url show <server>`.

## Starting and stopping the lab

The nodes don't start with the Proxmox host (`on_boot = false`). The
control plane survives one node going down, but not all three at once:
MariaDB Galera then has no member left to rejoin and needs a recovery step.

### Stop

1. Optionally stop the instances, so they shut down cleanly:

   ```sh
   openstack server list --all-projects --status ACTIVE -f value -c ID \
     | xargs -r -n1 openstack server stop
   ```

2. Stop Ceph rebalancing while nodes go down. `noout` is a cluster-wide flag,
   so set it once, on any node (`os-1` is simplest):

   ```sh
   sudo ceph osd set noout
   ```

3. Shut the nodes down one at a time, `os-1` last (it is the deployment host
   and you want its shell until the end). On lenora:

   ```sh
   for id in 9203 9202 9201; do qm shutdown $id --timeout 300; done
   ```

### Start

A cold start never comes back on its own. Three things are true of this
deployment, and together they mean every full stop needs the sequence below.

* **Galera cannot bootstrap itself.** When all three nodes stop at once,
  none of them is left holding `safe_to_bootstrap: 1` in
  `/var/lib/docker/volumes/mariadb/_data/grastate.dat` (an unclean stop also
  leaves `seqno: -1`), so no node will form the cluster on its own. That is
  Galera refusing to risk a split brain, not a fault. Until you recover it,
  nothing that needs the database works.
* **Nothing is ordered.** Kolla manages each container with its own
  `kolla-<container>-container.service` unit, and every one of the 81 units
  only says `After=docker.service`. So on boot, all of them start at once,
  long before MariaDB is usable.
* **Two failure behaviours follow from that**, and only one of them heals:
  * Services that **exit** on failure are restarted for ever
    (`Restart=always`, `RestartSec=11`). `nova_conductor` and
    `nova_scheduler` crash-loop while placement is down, with restart
    counters in the hundreds, and come back by themselves once it answers.
  * The **API services never exit**. They all run under uwsgi
    (`placement_api`, `nova_api`, `nova_metadata`, `cinder_api`,
    `neutron_server`, `barbican_api`, `octavia_api`), which loads the
    application once: the database error leaves it with `no python
    application found` in `/var/log/kolla/<service>/*-uwsgi.log`, and the
    master process keeps answering HTTP 500 for ever. Docker marks the
    container unhealthy, but because the process is still running, neither
    Docker nor systemd ever restarts it. **These need restarting by hand** —
    that is step 5.

HAProxy drops those unhealthy backends, so the first thing you see is
`503 Service Unavailable: No server is available to handle this request` from
`api.openstack.home`, whichever service you ask for.

Work through the steps in order and check each one before moving on. Steps 1
to 4 build the foundation; step 5 is where the control plane comes back.

1. **Start the nodes.** On lenora:

   ```sh
   for id in 9201 9202 9203; do qm start $id; done
   ```

   Wait until all three answer SSH. Everything below runs on `os-1`.

2. **Check the hostnames.** Kolla needs each node's short name to resolve to
   its own management address; if cloud-init has taken `/etc/hosts` over
   again, RabbitMQ and libvirt both break in confusing ways.

   ```sh
   ansible -i /etc/kolla/multinode control -m shell -a 'getent ahostsv4 $(hostname) | head -1'
   ```

   Each node must answer with its own `192.168.32.x` address and its short
   name — not `127.0.1.1`, not the FQDN. If it doesn't, fix it before going
   on: see [Hostnames](#hostnames).

3. **Check Ceph, then let it rebalance again.**

   ```sh
   sudo ceph -s                  # wait for 6 osds: 6 up, 6 in
   sudo ceph osd unset noout     # cluster-wide, so once, on any node
   sudo ceph health              # HEALTH_OK
   ```

4. **Recover the database.** This is the step the rest depends on:

   ```sh
   kolla-ansible mariadb-recovery -i /etc/kolla/multinode
   ```

   It finds the node with the most recent data, bootstraps the cluster from it
   and starts the others. It is safe to run when unsure. Then confirm all
   three are in one primary cluster, with the [Galera
   check](#galera-status) — cluster size 3, `Primary`, `Synced`. Don't carry
   on until it says that.

   Check RabbitMQ too, with the [RabbitMQ check](#rabbitmq-status): three
   running nodes and no partitions. It normally survives a cold start by
   itself, now that the hostnames stay put.

5. **Restart everything that started too early.** Begin with placement,
   because nova's conductor and scheduler crash-loop until it answers, then
   sweep up whatever else is still unhealthy:

   ```sh
   ansible -i /etc/kolla/multinode control -m shell -f 1 -a "docker restart placement_api"

   ansible -i /etc/kolla/multinode control -m shell -f 1 -a \
     "docker ps --filter health=unhealthy -q | xargs -r docker restart"
   ```

   Give it a minute and repeat the sweep until it reports nothing: a
   container can need a second pass if it came up while its own dependency
   was still restarting. Then check nothing is left behind:

   ```sh
   ansible -i /etc/kolla/multinode control -m shell \
     -a "docker ps -a | grep -E 'unhealthy|Exited|Restarting' || true"
   ```

6. **Verify from the API side.** Container health only says the process
   answers locally; these lists are written by the services themselves and
   prove they reached both the message bus and the database:

   ```sh
   openstack compute service list        # all up, including nova-compute on all three
   openstack network agent list
   openstack volume service list
   openstack orchestration service list
   openstack dns service list
   ```

   If `nova-compute` is `down` on a node while its container looks healthy,
   it lost libvirt at start-up: restart `nova_libvirt`, then `nova_compute`,
   on that node. If a service logs `Timed out waiting for nova-conductor`
   while the conductors are up, see
   [A poisoned quorum queue](#a-poisoned-quorum-queue).

7. **Start the instances that should run:**

   ```sh
   openstack server list --all-projects --status SHUTOFF
   openstack server start <server> [<server> ...]
   ```

### What the symptom tells you

| Symptom | Cause | Go to |
|---|---|---|
| `503 ... No server is available` from `api.openstack.home` | HAProxy has no healthy backend for that service | Start step 5 |
| `Max connect timeout reached while reaching hostgroup 0` in a service log | ProxySQL can't reach MariaDB: Galera is not up | Start step 4 |
| `no python application found` in a `*-uwsgi.log` | The worker started before the database; it will never retry | Start step 5 |
| `The placement service ... does not have any supported versions` | `placement_api` is stuck, so conductor and scheduler crash-loop | Restart `placement_api`, then re-check |
| `epmd error for host os-X: address` in the RabbitMQ log | The node's short name doesn't resolve to its management address | [Hostnames](#hostnames) |
| `authentication failed` from libvirt, `nova-compute` down | Same hostname problem: the SASL realm no longer matches `nova@os-X` | [Hostnames](#hostnames) |
| `Timed out waiting for nova-conductor` while conductors are up | A diverged quorum queue that RabbitMQ won't deliver to | [A poisoned quorum queue](#a-poisoned-quorum-queue) |
| `PRECONDITION_FAILED - stream queue ... does not have a running replica` | A `*_fanout` stream lost its replicas | [Under-replicated stream queues](#under-replicated-stream-queues) |
| A container restarting over and over | Its dependency is still down; it will recover on its own | Fix the dependency first |
| A container `Up` but `(unhealthy)` for ages | Nothing will ever restart it | Restart it by hand |

To see it from the systemd side on a node:

```sh
systemctl list-units 'kolla-*-container.service' --all --no-legend | grep -vE 'active +running'
systemctl show kolla-nova_scheduler-container.service -p NRestarts
journalctl -u kolla-nova_scheduler-container.service -n 50
sudo docker inspect --format '{{.State.Health.Status}}' nova_api
```

A high `NRestarts` is the signature of a service waiting for a dependency; a
container that is unhealthy with no restarts at all is the signature of a
stuck uwsgi worker.

### Rebooting one node

Fine at any time; the other two carry the control plane, and keepalived moves
the VIPs. Move the instances off it first if they matter, as in
[Patching the nodes](updates.md#patching-the-node-os). Set `noout` for the
duration, so Ceph doesn't start copying the node's data elsewhere. The flag is
cluster-wide, so set and unset it on any node:

```sh
sudo ceph osd set noout
sudo reboot            # on the node
sudo ceph osd unset noout   # once its OSDs are back up
```

## Health checks

A quick round, from the deployment host:

```sh
# OpenStack services
openstack compute service list
openstack network agent list
openstack volume service list
openstack orchestration service list
openstack loadbalancer amphora list

# Containers that are unhealthy, stopped or restarting, on every node
ansible -i /etc/kolla/multinode control -m shell \
  -a "docker ps -a | grep -E 'unhealthy|Exited|Restarting' || true"

# Units systemd is retrying or has given up on, on every node
ansible -i /etc/kolla/multinode control -m shell \
  -a "systemctl list-units 'kolla-*-container.service' --all --no-legend | grep -vE 'active +running' || true"

# Ceph
sudo ceph -s
sudo ceph health detail

# Which node holds the VIPs
ansible -i /etc/kolla/multinode control -m shell \
  -a "ip -br addr | grep -E '192.168.3[23].10' || true"
```

Everything should report `up`, `:-)` or `enabled`. Ceph currently reports
slow BlueStore operations because its disks are on the HDD pool; that
warning is expected. Anything else under `ceph health detail` isn't.

### Galera status

```sh
pw=$(sudo awk '/^database_password:/ {print $2}' /etc/kolla/passwords.yml)
sudo docker exec mariadb mariadb -uroot -p"$pw" \
  -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment')"
```

Expect a cluster size of 3, `Primary` and `Synced`.

### RabbitMQ status

```sh
sudo docker exec rabbitmq rabbitmqctl cluster_status
```

All three nodes should be listed under running nodes, with no network
partitions.

### Grafana and alerts

Grafana has dashboards for the nodes, OpenStack, RabbitMQ, MariaDB, HAProxy
and Ceph. Firing alerts are in Alertmanager.

## Logs

| Where | What |
|---|---|
| `/var/log/kolla/<service>/` on each node | Every OpenStack service's log files |
| `sudo docker logs <container>` | A container's start-up output |
| `sudo journalctl` on each node | The system: sshd, sudo, cron, systemd, the kernel, and every Ceph daemon |
| OpenSearch Dashboards | All of the above from every node, searchable (index pattern `flog-*`, created by Kolla) |
| `~ubuntu/kolla-logs/<action>.log` on `os-1` | Output of the Kolla-Ansible runs the playbooks started |
| `sudo cephadm logs --name <daemon>` | A Ceph daemon's log; daemon names from `sudo ceph orch ps` |

To follow a request through the services, search OpenSearch for its request
ID (`req-...`), which the CLI prints with `--debug`.

In OpenSearch, `programname` says where a line came from: the service
(`nova-api`), or for the journal its identifier (`sshd`, `sudo`). The Ceph
daemons run under `bash` there; filter on `systemd_unit` (`ceph-*@osd.3.service`)
to pick one. Kolla's Fluentd configuration leaves out a few of its own
services; `kolla-host.yml` adds Gnocchi, Grafana, OpenSearch and its
dashboards, Prometheus and ProxySQL, unparsed. It also gives Fluentd read
access to the journal. Not collected: the Proxmox host, the amphorae and the
instances.

The `flog-*` index pattern keeps a list of the fields, which `openstack.yml`
refreshes after a deploy. If a field you can see in the documents is missing
from the filters, refresh it under Dashboards Management → Index patterns →
`flog-*` → Refresh field list.

## Kolla containers

Every OpenStack service runs as a Docker container on every node.

```sh
sudo docker ps                         # what runs here
sudo docker restart nova_compute       # restart one service on this node
kolla-ansible check -i /etc/kolla/multinode   # are the expected containers running?
```

To restart a service on every node, either loop over the nodes or let
Kolla-Ansible do it:

```sh
kolla-ansible deploy-containers -i /etc/kolla/multinode -t nova
```

Each container also has a systemd unit, `kolla-<container>-container.service`,
which is what starts it at boot and restarts it when it exits. That is the
layer to look at when a container is missing rather than unhealthy:

```sh
systemctl status kolla-nova_api-container.service
sudo systemctl restart kolla-nova_api-container.service   # same as docker restart
```

Turning a service off leaves its unit behind, permanently `failed`, which
clutters the checks. Remove it on every node:

```sh
ansible -i /etc/kolla/multinode control -m shell -b -a \
  "systemctl disable --now kolla-prometheus_cadvisor-container.service;
   rm -f /etc/systemd/system/kolla-prometheus_cadvisor-container.service;
   systemctl daemon-reload; systemctl reset-failed"
```

Don't change files inside containers: Kolla regenerates their configuration
on every deploy. Change the configuration as below instead.

## Changing the configuration

There are three places, depending on what you change.

1. **Settings the repository manages**: the optional services and the
   day-2 settings in `ansible/group_vars/openstack.yml`, Kolla's settings in
   `ansible/templates/globals.yml.j2`. Edit them in the repository, then
   rewrite `/etc/kolla/globals.yml` without re-running the rest of the host
   setup:

   ```sh
   ansible-playbook ansible/kolla-host.yml --tags kolla-config
   ```

2. **Service options** (`nova.conf`, `neutron.conf` and so on): put an
   override file in `/etc/kolla/config/` on `os-1`. Kolla merges it into the
   generated file. For example, `/etc/kolla/config/nova.conf`:

   ```ini
   [DEFAULT]
   cpu_allocation_ratio = 4.0
   ```

   The repository doesn't manage these files (except the Ceph files
   `ceph.yml` writes there and the Fluentd files from `kolla-host.yml`), so
   note any you add.

3. **Passwords**: `/etc/kolla/passwords.yml`. Don't change them by hand on
   a running cloud; most services don't handle it.

Then apply it to the service you changed:

```sh
kolla-ansible validate-config -i /etc/kolla/multinode -t nova   # optional
kolla-ansible reconfigure -i /etc/kolla/multinode -t nova
```

`-t` takes the service names Kolla uses (`nova`, `neutron`, `cinder`,
`octavia`, `horizon` …); leave it out to reconfigure everything, which takes
about as long as a deploy. Use `genconfig` instead of `reconfigure` to write
the configuration files without restarting anything.

**Turning a service on**, such as one of the `enable_*` flags in
`group_vars`, needs a `deploy` rather than a `reconfigure`, and HAProxy needs
to learn about it too:

```sh
ansible-playbook ansible/kolla-host.yml --tags kolla-config
kolla-ansible deploy -i /etc/kolla/multinode -t haproxy,<service>
```

Turning one off stops Kolla managing it, but leaves its containers running.
Remove those by hand (`docker rm -f`) on every node.

## Recovery

### MariaDB

If Galera has lost quorum (after a full stop, or two nodes failing), run
`kolla-ansible mariadb-recovery -i /etc/kolla/multinode`. A single node that
won't rejoin usually recovers with `sudo docker restart mariadb` on that
node.

Why it can't do this by itself: each node records what it knows in
`/var/lib/docker/volumes/mariadb/_data/grastate.dat`.

```sh
ansible -i /etc/kolla/multinode control -m shell \
  -a "cat /var/lib/docker/volumes/mariadb/_data/grastate.dat"
```

After a graceful, staggered shutdown the last node to stop has
`safe_to_bootstrap: 1` and starts the cluster again on its own. After a
simultaneous stop every node has `safe_to_bootstrap: 0`, and an unclean one
also leaves `seqno: -1`, meaning "I don't know how far I got". No node will
then bootstrap, because the wrong choice loses writes — which is what
`mariadb-recovery` decides for you, by comparing the nodes' recovered
positions. Expect to run it after every full stop.

### Hostnames

Symptoms after a boot: RabbitMQ won't start (`epmd error for host os-1:
address`), and nova-compute dies with `authentication failed` against
libvirt. Both mean the node's own short name no longer resolves to its
management address. Kolla keeps those entries in `/etc/hosts`; cloud-init
rewrites the file at boot if the `update_etc_hosts` module is still enabled,
which `ansible/nodes.yml` disables. Check and restore:

```sh
ansible -i /etc/kolla/multinode control -m shell -a 'getent ahostsv4 $(hostname) | head -1'
```

Each node must answer with its own `192.168.32.x` address and the short name.
If not, re-run `ansible/nodes.yml` and `ansible/kolla-host.yml`, then restart
`rabbitmq`, `nova_libvirt` and `nova_compute` on every node.

### RabbitMQ

Symptoms: services log `AMQP server ... is unreachable`, or instances stay
in `BUILD`. Try restarting it on every node, one at a time:

```sh
ansible -i /etc/kolla/multinode control -m shell -a "docker restart rabbitmq" -f 1
```

If the cluster still doesn't form, reset it. This drops the queues, so the
services then need restarting too:

```sh
kolla-ansible rabbitmq-reset-state -i /etc/kolla/multinode
kolla-ansible deploy-containers -i /etc/kolla/multinode
```

### A poisoned quorum queue

Symptoms: a service keeps logging `Timed out waiting for nova-conductor`
while every container looks healthy, and the RabbitMQ log on another node
repeats `operation basic.publish caused a connection exception
resource_error`, with a Ra crash in the detail (`{case_clause,undefined}` or
`PrevIdx < SnapIdx` in `ra_server`). One queue's Raft members have diverged,
usually a `reply_*` queue left behind by a crash loop. Find it from the
publish error, then look at its members:

```sh
sudo docker exec rabbitmq rabbitmq-queues quorum_status 'reply_os-1:nova-compute:1'
```

A member in `noproc`/`unknown`, or a last log index far ahead of the leader's,
is the broken one. The queues only hold RPC replies, so deleting them is
safe; the clients redeclare them:

```sh
sudo docker exec rabbitmq rabbitmqctl delete_queue 'reply_os-1:nova-compute:1'
```

If that fails with the same Ra crash, drop the replicas on the node holding
the bad member and put them back afterwards:

```sh
sudo docker exec rabbitmq rabbitmq-queues shrink rabbit@os-3   # then delete_queue
sudo docker exec rabbitmq rabbitmq-queues grow rabbit@os-3 all
```

If it still fails, the stale Raft log is on disk on the node whose member has
diverged. `rabbitmqctl reset` does not clear it. Stop RabbitMQ on that node
only — the other two keep serving — move the queue's directory aside and
start it again:

```sh
Q=/var/lib/docker/volumes/rabbitmq/_data/mnesia/rabbit@os-1/quorum/rabbit@os-1
sudo docker exec rabbitmq sh -c "cd $Q && grep -al 'reply_os-2:nova-compute:1' 2F_REP*/*"
sudo docker stop rabbitmq
sudo mv $Q/<dir> /var/tmp/              # the directory from the grep
sudo docker start rabbitmq
```

Then delete the queue, `grow` the replicas back and restart the services that
used it. Finally check no queue is short of a replica:

```sh
sudo docker exec rabbitmq rabbitmqctl list_queues name type members
```

### Under-replicated stream queues

Symptom: a service loops on `Unable to connect to AMQP server ... (406)
PRECONDITION_FAILED - stream queue '<name>_fanout' in vhost '/' does not have
a running replica on the local node`, and its container stays unhealthy.

The `*_fanout` queues are streams, not quorum queues, and they are replicated
separately: `rabbitmq-queues grow` does not touch them, so they stay
one-replica after a node has been shrunk out, reset or rebuilt. A client that
then connects to a node without a replica cannot consume. Count the replicas:

```sh
sudo docker exec rabbitmq rabbitmqctl list_queues name type members \
  | awk -F'\t' '$2=="stream"'
```

Every stream should list all three nodes. Add the missing ones, then restart
the services that were looping:

```sh
sudo docker exec rabbitmq rabbitmq-streams add_replica '<name>_fanout' rabbit@os-2
```

### Ceph

```sh
sudo ceph health detail
sudo ceph orch ps --refresh           # are all daemons running?
sudo ceph orch daemon restart osd.3   # restart one daemon
```

An OSD that stays down after its node is back: `sudo ceph orch daemon
restart osd.<id>`, then check its log with `sudo cephadm logs --name
osd.<id>` on the node it lives on (`sudo ceph osd tree`).

### A stuck instance

```sh
openstack server set --state active <server>   # clear an error or stuck task state
openstack server reboot --hard <server>
```

### Re-running the playbooks

`ansible/site.yml` and each of its parts are safe to re-run on a working
lab. A re-run deploys again, so it restarts services that changed, but keeps
the data, the passwords and the certificates. `cloud.yml` on its own is
quick: it only puts back missing flavours, images and the demo customer.

## Disk space

Docker images and logs live on each node's 100 GB system disk. Check it now
and then, and clean up after upgrades:

```sh
ansible -i /etc/kolla/multinode control -m shell -a "df -h / | tail -1"
kolla-ansible prune-images -i /etc/kolla/multinode --yes-i-really-really-mean-it
```

Ceph capacity: `sudo ceph df`. With 3 replicas, usable space is a third of
raw, and Ceph stops writes at 95% full. Keep it under 80%.

## Taking down the lab

Removing the lab deletes `secrets/`, so take the lab CA out of your
laptop's trust store first, while `secrets/root.crt` is still there.

1. Remove the lab CA from the System keychain. Its name, `KollaTestCA`, is
   the same for every Kolla lab, so delete it by fingerprint:

   ```sh
   sudo security remove-trusted-cert -d secrets/root.crt
   sudo security delete-certificate -Z "$(openssl x509 -in secrets/root.crt \
     -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)" /Library/Keychains/System.keychain
   ```

   If `secrets/` is already gone, look up the fingerprint in the keychain
   and pass that to `-Z`:

   ```sh
   security find-certificate -a -c KollaTestCA -Z /Library/Keychains/System.keychain | grep SHA-1
   ```

2. Destroy the VMs and remove the lab from Proxmox, as in
   [Removing the lab](../README.md#removing-the-lab):

   ```sh
   tofu destroy -var-file=secret.tfvars
   ansible-playbook ansible/teardown.yml
   ```

   This also deletes `secrets/` (including `clouds-local.yaml`),
   `secret.tfvars`, the Terraform state and the inventory.

3. Remove the nodes' SSH host keys from `~/.ssh/known_hosts`:

   ```sh
   for h in os-1 os-2 os-3; do ssh-keygen -R $h.openstack.home; done
   for ip in 192.168.32.1{1,2,3}; do ssh-keygen -R $ip; done
   ```

4. Clean up the rest, if you set it up:

   - `OS_CLOUD` and `OS_CLIENT_CONFIG_FILE` in your shell profile
   - the OpenStack client: `pipx uninstall python-openstackclient`

Your own SSH key (`~/.ssh/id_ed25519`) stays: the lab only copied the
public half onto the nodes, and those are gone.
