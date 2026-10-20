# Networking and services

Networks, load balancers, DNS, object storage, secrets and orchestration.
Commands are written as the customer runs them (`export OS_CLOUD=acme`); the
admin-only parts say so.

## Networks

Tenant networks are Geneve overlays (OVN), private to the project. A router
connects them to `public`, the provider network on `192.168.37.0/24`, which
the LAN routes to the lab. Routing and floating IPs are distributed: traffic
leaves from the node the instance runs on.

### Create

```sh
openstack network create app-net
openstack subnet create --network app-net --subnet-range 10.30.0.0/24 \
  --dns-nameserver 192.168.8.50 app-subnet
openstack router create --external-gateway public app-router
openstack router add subnet app-router app-subnet
```

- **No internet access needed?** Leave out the router; instances then reach
  only each other.
- **A second subnet on an existing router**: `openstack router add subnet
  app-router other-subnet`. Subnets on the same router can reach each other.
- **Fixed address** for an instance: create the port first and boot with it:

  ```sh
  openstack port create --network app-net --fixed-ip subnet=app-subnet,ip-address=10.30.0.50 db-port
  openstack server create ... --port db-port db-1
  ```

### View, change, delete

```sh
openstack network list
openstack subnet show app-subnet
openstack router show app-router
openstack port list --server web-1
```

| Task | Command |
|---|---|
| Change DNS servers | `openstack subnet set --no-dns-nameservers --dns-nameserver <ip> app-subnet` |
| Add a static route | `openstack router set --route destination=10.40.0.0/24,gateway=10.30.0.1 app-router` |
| Disable DHCP | `openstack subnet set --no-dhcp app-subnet` |
| Delete | in order: instances and ports, `router remove subnet`, `router delete`, `subnet delete`, `network delete` |

### Admin: shared and provider networks

- A network every project can use: `openstack network create --share
  shared-net`. Or share one with a single project: `openstack network rbac
  create --target-project <id> --action access_as_shared --type network
  <network>`.
- The provider network `public` is created by `cloud.yml`. Don't delete it
  while routers or floating IPs use it.

## Security groups

Stateful firewalls on each port. The `default` group allows all outgoing
traffic and traffic between members of the same group, but nothing in.

```sh
openstack security group create web
openstack security group rule create --protocol tcp --dst-port 80 web
openstack security group rule create --protocol tcp --dst-port 443 web
openstack security group rule create --protocol tcp --dst-port 22 --remote-ip 192.168.8.0/24 web
openstack security group rule create --protocol tcp --dst-port 5432 --remote-group web db
openstack server add security group web-1 web
```

`--remote-group` admits members of another group, so rules keep working as
instances come and go.

```sh
openstack security group rule list web
openstack security group rule delete <rule-id>
openstack server remove security group web-1 web
```

## Floating IPs and port forwarding

```sh
openstack floating ip create public
openstack server add floating ip web-1 <ip>
openstack server remove floating ip web-1 <ip>
openstack floating ip delete <ip>
openstack floating ip list
```

Floating IPs count against the project's quota until deleted, attached or
not.

**Port forwarding** shares one floating IP among several instances:

```sh
openstack floating ip port forwarding create --internal-ip-address 10.30.0.21 \
  --port <port-of-web-1> --internal-protocol-port 22 --external-protocol-port 2201 \
  --protocol tcp <floating-ip>
```

The floating IP must not also be attached to an instance.

## QoS (admin)

Policies are made by admin and used by customers:

```sh
openstack network qos policy create --share 100mbit
openstack network qos rule create --type bandwidth-limit --max-kbps 100000 \
  --max-burst-kbits 10000 --egress 100mbit
```

Customers apply them to a port or network:
`openstack port set --qos-policy 100mbit <port>`.

## Load balancers

Two providers:

| Provider | What it is | Use for |
|---|---|---|
| `amphora` (default) | An HAProxy VM per load balancer, in the service project | HTTP/HTTPS (layer 7), TLS termination, health checks, everything |
| `ovn` | Built into OVN, no VM | TCP/UDP (layer 4) only; instant and free of overhead |

### HTTP load balancer

```sh
openstack loadbalancer create --vip-subnet-id app-subnet --name web-lb --wait
openstack loadbalancer listener create --protocol HTTP --protocol-port 80 --name web-http --wait web-lb
openstack loadbalancer pool create --listener web-http --protocol HTTP \
  --lb-algorithm ROUND_ROBIN --name web-pool --wait
openstack loadbalancer healthmonitor create --type HTTP --url-path / \
  --delay 5 --timeout 3 --max-retries 3 --wait web-pool
openstack loadbalancer member create --subnet-id app-subnet --address 10.30.0.21 --protocol-port 80 --wait web-pool
openstack loadbalancer member create --subnet-id app-subnet --address 10.30.0.22 --protocol-port 80 --wait web-pool
```

Make it reachable from the LAN with a floating IP on its VIP port:

```sh
VIP_PORT=$(openstack loadbalancer show web-lb -f value -c vip_port_id)
openstack floating ip create --port "$VIP_PORT" public
```

Don't put the VIP on `public` itself (`--vip-subnet-id public-subnet`). It
shows `ACTIVE` and `ONLINE` but only answers when the amphora happens to run
on a node that hosts a router gateway. OVN 26.03 only accepts ARP requests
from the provider network on those nodes, and drops them everywhere else. The
same goes for instances attached to `public` directly. Floating IPs aren't
affected.

The members' security group must allow the traffic from the load balancer.
An amphora load balancer takes a minute or two to reach `ACTIVE`.

### TLS termination

Store the certificate in Barbican as a PKCS#12 bundle, then use a
`TERMINATED_HTTPS` listener:

```sh
openssl pkcs12 -export -inkey site.key -in site.crt -certfile chain.crt -passout pass: -out site.p12
openstack secret store --name site-cert -t 'application/octet-stream' -e base64 \
  --payload "$(base64 < site.p12)"
openstack loadbalancer listener create --protocol TERMINATED_HTTPS --protocol-port 443 \
  --default-tls-container-ref <secret-href> --default-pool web-pool --name web-https web-lb
```

### Layer-4 with OVN

```sh
openstack loadbalancer create --provider ovn --vip-subnet-id app-subnet --name tcp-lb --wait
openstack loadbalancer listener create --protocol TCP --protocol-port 5432 --name pg tcp-lb --wait
openstack loadbalancer pool create --listener pg --protocol TCP --lb-algorithm SOURCE_IP_PORT --name pg-pool --wait
```

Members as above.

### View, change, delete

```sh
openstack loadbalancer list
openstack loadbalancer status show web-lb        # the whole tree, with health
openstack loadbalancer member list web-pool
openstack loadbalancer member set --weight 0 web-pool <member>   # drain a member
openstack loadbalancer delete --cascade web-lb
```

### Traffic and metrics

`openstack loadbalancer stats show web-lb` (or `listener stats show`) gives
the totals since the load balancer was created: connections, bytes in and
out, request errors. For graphs, add a `PROMETHEUS` listener: the amphora then
serves HAProxy's metrics per listener, pool and member on that port, for any
Prometheus to scrape.

```sh
openstack loadbalancer listener create --protocol PROMETHEUS --protocol-port 8088 \
  --allowed-cidr 192.168.0.0/16 --name web-metrics --wait web-lb
curl http://<lb-floating-ip>:8088/metrics
```

Horizon offers the protocol too, through a patch the lab carries until the
Octavia dashboard has it (see [Updates](updates.md#openstack-minor-updates)).
It doesn't have a pool, so the wizard turns pool and monitor creation off.
PROMETHEUS listeners need the amphora provider.

### Admin: amphorae

```sh
openstack loadbalancer amphora list
openstack loadbalancer amphora failover <amphora-id>   # replace a broken one
openstack loadbalancer failover <lb>                   # replace all of a load balancer's
```

Amphorae run as instances in the `service` project, using the
`amphora-x64-haproxy` image. A load balancer in `ERROR` usually recovers with
a failover. After replacing the amphora image (see
[Updates](updates.md#amphora-image)), fail over each load balancer to move
it onto the new image.

## DNS (Designate)

Designate hosts DNS zones on BIND, at `ns1.openstack.home`
(`192.168.33.11–13`). The LAN's resolvers don't forward to it, so its
zones are only visible when asked directly, or after a delegation is added
in the homelab's PowerDNS.

```sh
openstack zone create --email hostmaster@acme.example acme.example.
openstack recordset create --type A --record 192.168.37.120 acme.example. www
openstack recordset list acme.example.
dig @192.168.33.11 www.acme.example
```

Zone names end in a dot. Changes take a few seconds to reach BIND
(`openstack zone show` returns `ACTIVE` when they have).

| Task | Command |
|---|---|
| Change a record | `openstack recordset set --record <new-ip> acme.example. www.acme.example.` |
| Delete a record | `openstack recordset delete acme.example. www.acme.example.` |
| Delete a zone | `openstack zone delete acme.example.` |
| Move a zone to another project | `openstack zone transfer request create --target-project-id <id> acme.example.` |

**Instance names in DNS**: create a zone and set it as the network's DNS
domain; Neutron then adds a record for each port and floating IP:

```sh
openstack zone create --email hostmaster@acme.example app.acme.example.
openstack network set --dns-domain app.acme.example. app-net
```

## Object storage

Swift and S3 APIs, served by Ceph RGW and authenticated by Keystone. Each
project gets its own namespace.

### Swift

```sh
openstack container create backups
openstack object create backups dump.sql.gz
openstack object list backups
openstack object save backups dump.sql.gz
openstack object delete backups dump.sql.gz
openstack container delete --recursive backups
```

Public read access to a container:
`openstack container set --property read-acl='.r:*,.rlistings' backups`.
Its URL is then
`https://api.openstack.home:6780/swift/v1/AUTH_<project-id>/backups/<object>`.

### S3

Create S3 keys for the current user and project:

```sh
openstack ec2 credentials create        # access and secret
```

Then use any S3 client with endpoint `https://api.openstack.home:6780`,
path-style addressing and the lab CA:

```sh
aws --endpoint-url https://api.openstack.home:6780 --ca-bundle root.crt s3 ls
```

Buckets and Swift containers are the same thing. Revoke keys with
`openstack ec2 credentials delete <access>`.

## Secrets (Barbican)

```sh
openstack secret store --name db-password --payload 's3cret'
openstack secret list
openstack secret get --payload <secret-href>
openstack secret delete <secret-href>
```

Used by Octavia for TLS certificates, and available to applications through
the API. Barbican runs with its new policy defaults
(`/etc/kolla/config/barbican.conf`), so the `member` role is enough. Under
the legacy rules a customer needs `creator` as well, and Horizon's load
balancer wizard fails with a permission error.

## Orchestration (Heat)

Describe a set of resources in a template and create them in one go:

```yaml
# web.yaml
heat_template_version: 2021-04-16
parameters:
  count: { type: number, default: 2 }
resources:
  web:
    type: OS::Heat::ResourceGroup
    properties:
      count: { get_param: count }
      resource_def:
        type: OS::Nova::Server
        properties:
          name: web-%index%
          flavor: gp1.small
          image: ubuntu-24.04
          key_name: mykey
          networks: [{ network: app-net }]
          security_groups: [default, web]
```

```sh
openstack stack create -t web.yaml --wait web
openstack stack update -t web.yaml --parameter count=3 --wait web
openstack stack resource list web
openstack stack delete --yes --wait web
```

## Metering and rating

Ceilometer collects usage into Gnocchi; CloudKitty is deployed but has no
rating rules, so it rates everything at zero. Usage per project:

```sh
openstack usage show --project <id> --start 2026-10-01
openstack metric resource list --type instance
```

Configuring CloudKitty's hashmap rules turns this into prices; see the
CloudKitty documentation.
