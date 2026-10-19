# openstack-lab

A three-node OpenStack cloud running as nested VMs on Proxmox VE, built the
way a small service provider would run one. OpenTofu creates the VMs;
Ansible configures the Proxmox host and the nodes, and deploys Ceph and
OpenStack (Kolla-Ansible, 2026.1).

OpenTofu only manages the VMs it creates. The API token is limited to one
resource pool, so it cannot touch other VMs on the host.

## What you get

- **HA control plane** on all three nodes: HAProxy and keepalived on an
  internal and a public VIP, MariaDB Galera, clustered RabbitMQ
- **Public endpoints behind TLS** at `https://api.openstack.home`, signed by
  a lab CA, on their own network
- **Compute** with nested KVM, live migration on shared Ceph storage
- **Networking**: Neutron with OVN, distributed floating IPs, QoS, trunks,
  port forwarding
- **Storage on Ceph** (cephadm): images, volumes, volume backups, ephemeral
  disks, object storage (Swift and S3 through RGW, authenticated by Keystone)
- **Load balancers** (Octavia, Amphora and OVN providers), **DNS** (Designate
  with BIND), **secrets** (Barbican), **orchestration** (Heat)
- **Metering and rating**: Ceilometer, Gnocchi on Ceph, CloudKitty
- **Operations**: Prometheus, Alertmanager and Grafana (including the Ceph
  exporter), Fluentd to OpenSearch with OpenSearch Dashboards
- **Day-2 setup**: public network, flavours, raw images, a volume type and an
  onboarded customer (own domain, project, user, quota, network and router,
  and mailboxes on the homelab's mailcow)

Turn any of the optional services off in
[ansible/group_vars/openstack.yml](ansible/group_vars/openstack.yml).

## Requirements

- OpenTofu 1.6 or later, `ansible-core` with the `ansible.posix` and
  `openstack.cloud` collections
- SSH access as root to the Proxmox host (`lenora.home`)
- The homelab DNS set up for lab zones (`homelab/dns`, "Lab zones")
- About 200 GB of RAM and 48 vCPUs free on the host with the defaults
  (3 × 64 GB, 16 vCPUs), and 1.8 TB on the datastore

## Network

The lab uses `192.168.32.0/21`, routed by the Proxmox host. The LAN router
already routes that range to the host, so the LAN reaches every lab network
directly. `nutanix-lab` uses the same range, so only one of the two labs can
exist at a time; the bootstrap refuses to run while another lab's SDN zone
overlaps it. [NETWORK.md](NETWORK.md) has the design and the address plan.

| Network | Range | Use |
|---|---|---|
| mgmt (`osmgmt`) | `192.168.32.0/24` | SSH, internal API, internal VIP `.10` |
| api (`osapi`) | `192.168.33.0/24` | Public API, Horizon, DNS, external VIP `.10` |
| stor (`osstor`) | `192.168.34.0/24` | Ceph public, isolated |
| repl (`osrepl`) | `192.168.35.0/24` | Ceph replication, isolated |
| tun (`ostun`) | `192.168.36.0/24` | Geneve tunnels, isolated |
| ext (`osext`) | `192.168.37.0/24` | Provider network, floating IPs `.100-.250` |
| lbm, lbmp (`oslbm`) | `192.168.38.0/24` | Octavia management, isolated |

## DNS

The bootstrap registers the lab in the homelab's PowerDNS, under
`openstack.home`; the teardown removes it again.

| Name | Address |
|---|---|
| `os-1/2/3.openstack.home` | `192.168.32.11/12/13` (management) |
| `api.openstack.home` | `192.168.33.10` (external VIP: public endpoints, Horizon, Grafana) |
| `api-int.openstack.home` | `192.168.32.10` (internal VIP) |
| `ns1.openstack.home` | `192.168.33.11/12/13` (Designate's BIND) |

Reverse records are added for the management addresses and both VIPs.

The zone `openstack.home` and the reverse zones `32.168.192.in-addr.arpa`
and `33.168.192.in-addr.arpa` are created through Pythia's API, from
lenora. They live in Pythia's API-managed backend, not in the homelab
repository; see "Lab zones" in `homelab/dns/README.md` for the one-time
setup. The API key is read from `../homelab/dns/secrets.env`, or from
`PDNS_API_KEY` in the environment. Set `PDNS_API=` (empty) in `network.conf`
to skip DNS altogether.

The nodes resolve through Themis (`192.168.8.50`), like any other LAN client.

## Mail

`cloud.yml` gives the demo customer a mail domain, `demo.test`, with the
mailboxes `ops`, `alice` and `bob` on hermes, the homelab's mailcow. `ops` is
the Keystone user's email address. The mail is read in SOGo at
[https://hermes.home/SOGo/](https://hermes.home/SOGo/); the passwords are in
`secrets/<address>-password`. The teardown deletes the domain and every
mailbox in it.

Like the DNS zones, they are created through hermes's API from lenora, the
only address it accepts. The API key is read from
`../homelab/hermes/secrets.env`, which `homelab/hermes/scripts/deploy.sh`
generates, or from `MAILCOW_API_KEY` in the environment. Set `MAILCOW_API=`
(empty) in `network.conf` to skip mail. The domain and mailboxes are in
`customer.mail` in
[ansible/group_vars/openstack.yml](ansible/group_vars/openstack.yml).

## Usage

1. Configure the project:

   ```sh
   cp terraform.tfvars.example terraform.tfvars
   ```

   Set the endpoint, node and a free `vm_id_start`. The subnets are in
   `network.conf`; change them if they clash with your LAN.

2. Prepare the Proxmox host. Run this once per host, not once per lab:

   ```sh
   ansible-playbook ansible/prepare-proxmox.yml
   ```

   This enables nested virtualisation and IPv4 forwarding.

3. Set up the lab on Proxmox:

   ```sh
   ansible-playbook ansible/bootstrap.yml
   ```

   This builds SDN zone `openstk` with the seven vnets, registers the lab in
   DNS, downloads the Ubuntu
   24.04 cloud image, and creates the pool, a `terraform@pve` user and an API
   token with the minimum permissions. It checks that the VMIDs are free and
   writes the token to `secret.tfvars`. It is safe to re-run. Use
   `-e rotate_token=true` to replace the token.

4. Create the VMs:

   ```sh
   tofu init
   tofu plan  -var-file=secret.tfvars   # only "+ create" expected
   tofu apply -var-file=secret.tfvars
   ```

   This also writes `ansible/inventory/hosts.yml`. After a `tofu destroy`,
   re-run the bootstrap before the next apply. Proxmox drops a VM's
   permissions when the VM is destroyed.

5. Deploy Ceph and OpenStack:

   ```sh
   ansible-playbook ansible/site.yml
   ```

   This takes an hour or more. The steps are in order and each can be run on
   its own: `nodes.yml`, `kolla-host.yml`, `ceph.yml`, `openstack.yml`,
   `cloud.yml`. The first node, `os-1`, is the deployment host. Kolla-Ansible
   and the OpenStack clients live in `/opt/kolla/venv` there, and the output
   of each Kolla-Ansible run goes to `~ubuntu/kolla-logs/`.

   Credentials go to `secrets/` (git-ignored): `admin-openrc.sh`,
   `clouds.yaml`, `passwords.yml`, the lab CA `root.crt`, the demo customer's
   password and its mailbox passwords. `passwords.yml` also holds the Ceph dashboard password,
   `ceph_dashboard_password`.

## Using the cloud

| What | Where |
|---|---|
| Horizon | [https://api.openstack.home/](https://api.openstack.home/), domain `Default`, user `admin`, `keystone_admin_password` from `secrets/passwords.yml` |
| Customer login | domain `customers`, user `demo`, password in `secrets/demo-password` |
| Customer mail | [https://hermes.home/SOGo/](https://hermes.home/SOGo/), e.g. `ops@demo.test`, password in `secrets/ops@demo.test-password` |
| Grafana | [https://api.openstack.home:3000/](https://api.openstack.home:3000/) |
| Ceph dashboard | [https://os-1.openstack.home:8443/](https://os-1.openstack.home:8443/) (or the active manager), user `admin`, `ceph_dashboard_password` from `secrets/passwords.yml` |
| CLI | `ssh ubuntu@os-1.openstack.home`, then `source /opt/kolla/venv/bin/activate` and `export OS_CLOUD=kolla-admin OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml` |

For the CLI on your own machine, use `secrets/clouds.yaml` and trust
`secrets/root.crt`.

After a full stop of all three nodes, the cloud does not come back on its
own — Galera will not bootstrap itself and the API services never retry their
database connection. `ansible-playbook ansible/recover.yml` checks each layer
and restarts what is stuck; [Start](docs/operations.md#start) explains why.

The [manuals](docs/README.md) cover running the cloud: customers,
instances, networking and services, containers, operations and updates.

## Removing the lab

Destroy the VMs first, then run the playbook:

```sh
tofu destroy -var-file=secret.tfvars
ansible-playbook ansible/teardown.yml
```

The playbook stops if the pool still holds VMs. It removes:

- the token, its permissions and the pool
- the Terraform user, if no other project uses it
- the lab's DNS zones
- the customer's mail domain and mailboxes on hermes
- the SDN zone and the NAT unit
- the local state, the inventory, `secrets/` and `secret.tfvars`

Pass `-e confirm=<pool>` to skip the prompt. It leaves the cloud image and
the host preparation in place.

## Tested

Built end to end on lenora on 11 October 2026. All services are up on all
three nodes. As the demo customer, an instance booted from a raw image on
Ceph, was reachable by ping and SSH on its floating IP from the LAN,
stored and listed objects through Swift (RGW), and got an Amphora load
balancer to ACTIVE/ONLINE.

Known:

- Ceph reports slow BlueStore operations on the OSDs when they sit on
  `hddpool`, which is HDD-backed zvols. Expected; put the OSD disks on SSD if
  that matters.
- The CloudKitty rating rules and Designate zones are not configured; the
  services are deployed and empty.
