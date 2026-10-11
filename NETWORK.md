# Network design

All settings live in [network.conf](network.conf). OpenTofu, the Proxmox
playbooks and the OpenStack playbooks all read them from there.

## Address plan

```
LAN 192.168.8.0/24 ── router (routes 192.168.32.0/21 → lenora, NATs to the internet)
      │                    DNS: Themis 192.168.8.50 → Pythia, zone openstack.home
      │
lenora vmbr0 (lenora.home), forwarding on
      │   SDN zone "openstk" (simple)
      ├── osmgmt  192.168.32.0/24  gw .1   net0  mgmt  SSH, internal API, VIP .10
      ├── osapi   192.168.33.0/24  gw .1   net1  api   public API, Horizon, DNS, VIP .10
      ├── osstor  192.168.34.0/24  –       net2  stor  Ceph public network
      ├── osrepl  192.168.35.0/24  –       net3  repl  Ceph cluster network
      ├── ostun   192.168.36.0/24  –       net4  tun   Geneve tunnels
      ├── osext   192.168.37.0/24  gw .1   net5  ext   provider network (br-ex), no node address
      │                                                floating IPs .100-.250
      └── oslbm   192.168.38.0/24  –       net6  lbm   Octavia health managers
                                           net7  lbmp  lb-mgmt-net (br-lbm, physnet2), amphorae .100-.250
```

Nodes `os-1/2/3` are `.11/.12/.13` on every network that has node
addresses. NICs are renamed inside the VMs by MAC to the names in the
fourth column, so Kolla-Ansible's interface settings read the same as the
diagram.

## Decisions

| Decision | Reason |
|---|---|
| Hyperconverged: every node is controller, network, compute and Ceph node | Three nodes are the minimum for a quorum of MariaDB Galera, RabbitMQ and the Ceph monitors. |
| Kolla-Ansible | Containerised, HA by default (HAProxy, keepalived, Galera, clustered RabbitMQ), driven by Ansible like the rest of the lab. |
| Ceph with cephadm, outside Kolla | Kolla no longer deploys Ceph. One cluster backs Glance, Cinder, Cinder backup, Nova ephemeral disks, Gnocchi and the object store (RGW). |
| Separate public API network with its own VIP | Public endpoints behind TLS on a different network from the internal endpoints, as a provider would expose them. |
| Source-based routing for the API network | The default route is on mgmt. Without a second table, replies from the public VIP would leave through mgmt. |
| Isolated storage, replication and tunnel networks | No gateway on lenora, so the host doesn't route them. Only the nodes talk on them. |
| Flat provider network on lenora | Floating IPs are directly connected to lenora, so no static routes to the cloud are needed. |
| Octavia on its own isolated network | With OVN, Kolla only supports a provider network for the amphorae. Each node has two NICs on it: one with an address for the health managers, one for Open vSwitch. |
| OVN with distributed floating IPs | No central network node becomes a bottleneck or a single point of failure. |
| MTU 1500 | OVN lowers the tenant MTU to fit the Geneve header. Jumbo frames on nested VMs aren't worth it in a lab. |
| Same range as nutanix-lab | The router already routes `192.168.32.0/21` to lenora. The labs never run at the same time, and the bootstrap checks for that. |
| Names in the homelab DNS, through the API | Labs come and go, so their zones live in Pythia's API-managed backend rather than in the homelab repository. The bootstrap creates them and the teardown removes them. |
| Routing by the LAN router, NAT optional | The router routes `192.168.32.0/21` to lenora and NATs it. `LAB_SNAT=yes` makes lenora source-NAT the range instead. |
| VMs from the Ubuntu 24.04 cloud image with cloud-init | No installer. A node is ready to configure about a minute after `tofu apply`. |

## Proxmox firewall

Off on every NIC. Its MAC filtering drops traffic from instances and the
VIPs, whose MACs Proxmox doesn't know.
