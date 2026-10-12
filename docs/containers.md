# Containers

The lab offers no containers-as-a-service API. Customers run containers on
instances, which is how most small providers offer them anyway. This
manual covers that, and what it would take to add a managed service.

The Docker containers the OpenStack services themselves run in are covered
in [Operations](operations.md#kolla-containers).

## Why there is no container API

- **Zun** (containers as an OpenStack resource) is no longer maintained, and
  Kolla-Ansible 2026.1 doesn't deploy it.
- **Magnum** (managed Kubernetes clusters) is in Kolla-Ansible, but its
  original Heat-based drivers have been removed. The current drivers (Cluster API based, such
  as `magnum-cluster-api`) need a separate management Kubernetes cluster and
  extra images, and are not in the upstream Kolla images. Possible, but a
  project of its own, not a flag in `group_vars`.

## A Docker host

One instance with Docker, set up by cloud-init on first boot. Save as
`docker-host.yaml`:

```yaml
#cloud-config
package_update: true
packages: [docker.io, docker-compose-v2]
users:
  - default
runcmd:
  - usermod -aG docker ubuntu
  - systemctl enable --now docker
```

```sh
openstack security group create docker-web
openstack security group rule create --protocol tcp --dst-port 80 docker-web
openstack security group rule create --protocol tcp --dst-port 443 docker-web

openstack server create --flavor gp1.medium --image ubuntu-24.04 \
  --boot-from-volume 40 --network acme-net --key-name mykey \
  --security-group ssh-icmp --security-group docker-web \
  --user-data docker-host.yaml --wait docker-1
openstack floating ip create public
openstack server add floating ip docker-1 <floating-ip>
```

After a minute or two:

```sh
ssh ubuntu@<floating-ip> docker run -d -p 80:80 --restart unless-stopped nginx
curl http://<floating-ip>/
```

Tips:

- **Persistent data on a volume**, so the instance can be rebuilt without
  losing it. Create and attach one ([Volumes](instances.md#volumes)), mount
  it at `/var/lib/docker/volumes` or wherever the application writes.
- **Several hosts behind a load balancer**: create them with `--min 2 --max 2`
  in an anti-affinity server group, and put an Octavia load balancer in
  front ([Load balancers](services.md#load-balancers)).
- **Container images from Docker Hub** need internet access, which the
  router's gateway on `public` provides.

### Lifecycle

| Task | How |
|---|---|
| Update the containers | On the instance: `docker compose pull && docker compose up -d` |
| Update the host OS | On the instance: `sudo apt update && sudo apt full-upgrade`, reboot when asked |
| Replace the host | `openstack server rebuild --image ubuntu-24.04 --user-data docker-host.yaml docker-1` (keeps addresses and attached volumes, wipes the root disk) |
| Remove | `openstack server delete docker-1`, then the floating IP and any volumes |

## A small Kubernetes cluster

Three instances with k3s. Fine for testing applications; for anything
long-lived, use a proper installer (Kubespray, Cluster API) instead.

1. Instances, spread over the nodes:

   ```sh
   openstack server group create --policy anti-affinity k8s
   openstack security group create k8s
   openstack security group rule create --protocol tcp --dst-port 6443 k8s
   openstack security group rule create --protocol tcp --remote-group k8s k8s
   openstack security group rule create --protocol udp --remote-group k8s k8s
   openstack server create --flavor gp1.medium --image ubuntu-24.04 \
     --network acme-net --key-name mykey --security-group ssh-icmp --security-group k8s \
     --hint group=<server-group-id> --min 3 --max 3 --wait k8s
   ```

2. The first node as the server, on `k8s-1`:

   ```sh
   curl -sfL https://get.k3s.io | sh -s - server --disable servicelb
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```

3. The others as agents, on `k8s-2` and `k8s-3`:

   ```sh
   curl -sfL https://get.k3s.io | K3S_URL=https://<k8s-1-ip>:6443 K3S_TOKEN=<token> sh -
   ```

4. Check, on `k8s-1`: `sudo k3s kubectl get nodes`.

To let Kubernetes create Octavia load balancers and Cinder volumes itself,
install the OpenStack cloud controller manager and the Cinder CSI driver
(`cloud-provider-openstack`), with an
[application credential](tenants.md#give-the-customer-a-cloudsyaml) for the
project and the lab CA in their `cloud.conf`. That's what
`--disable servicelb` above makes room for.
