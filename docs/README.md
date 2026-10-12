# Manuals

How to run the lab once it is built. The [README](../README.md) covers
building and removing it.

| Manual | What's in it |
|---|---|
| [Operations](operations.md) | Access, starting and stopping the lab, health checks, logs, changing the configuration, recovery, taking the lab down |
| [Tenants](tenants.md) | Customers: domains, projects, users, roles, quotas, their networks; offboarding |
| [Instances](instances.md) | VMs: create, access, resize, snapshot, migrate, delete; volumes, images and flavours |
| [Networking and services](services.md) | Networks, routers, floating IPs, security groups, load balancers, DNS, object storage, secrets |
| [Containers](containers.md) | Running containers for tenants, and what the lab does not offer |
| [Updates](updates.md) | Node OS patching, OpenStack minor updates and release upgrades, Ceph, the Proxmox host |

## Conventions

Commands run on the **deployment host** (`os-1`) unless a step says
otherwise. Get a shell there with the admin CLI ready:

```sh
ssh ubuntu@os-1.openstack.home
source /opt/kolla/venv/bin/activate
export OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin
```

Add the last two lines to `~ubuntu/.bashrc` to skip them next time.

- **Kolla commands** (`kolla-ansible ...`) always take `-i /etc/kolla/multinode`
  and run as `ubuntu`, not root.
- **Ceph commands** run as root: `sudo ceph ...`.
- **Repository playbooks** run from the repository root on your own machine.
- `<angle brackets>` are placeholders. Prefer IDs over names for projects and
  users: names are only unique within a domain, so the same name can exist in
  `Default` and `customers`.

The nodes get new SSH host keys every time they are recreated. If SSH refuses
to connect, remove the old keys:

```sh
for h in os-1 os-2 os-3; do ssh-keygen -R $h.openstack.home; done
for ip in 192.168.32.1{1,2,3}; do ssh-keygen -R $ip; done
```
