# Tenants

Customers are set up the way a provider would: all in the domain
`customers`, one project per customer, with its own users, quota, network
and router. The demo customer (`ansible/cloud.yml`) is an example of the
result. Run everything here as admin, on the deployment host
([Conventions](README.md#conventions)).

| Keystone object | Use |
|---|---|
| Domain `customers` | Holds every customer's projects and users; keeps them apart from the service accounts in `Default` |
| Project | One per customer (or per customer environment, such as `acme-prod`, `acme-test`). Owns all resources and quotas |
| User | A person or an automation account, in `customers` |
| Role | What a user may do in a project, see below |

Roles worth knowing (`openstack role list` has all of them):

| Role | Can |
|---|---|
| `reader` | See everything in the project, change nothing |
| `member` | Create and manage resources in the project; the normal customer role |
| `manager` | `member`, plus some project-level administration, such as managing the project's users' roles where the policy allows it |
| `load-balancer_member` | Use Octavia. With the default policies `member` is enough; add this if a policy demands it |
| `heat_stack_owner` | Create Heat stacks. As above |
| `admin` | Everything, everywhere. Never give it to a customer |

## Create a customer

Set the names once; the rest of the steps use them:

```sh
CUST=acme                     # project name
USER=acme-admin               # first user
CIDR=10.20.0.0/24             # the customer's first subnet; any private range
```

1. **Project**:

   ```sh
   openstack project create --domain customers \
     --description "Acme Ltd" --tag customer "$CUST"
   PROJECT=$(openstack project show --domain customers "$CUST" -f value -c id)
   ```

2. **User** and its role in the project:

   ```sh
   openstack user create --domain customers --project "$PROJECT" \
     --email ops@acme.example --password-prompt "$USER"
   openstack role add --user "$USER" --user-domain customers \
     --project "$PROJECT" member
   ```

   `--password-prompt` asks for the password. To generate one instead:
   `--password "$(openssl rand -base64 18)"`, and print it with
   `echo` before you lose it.

3. **Quota**. The defaults are generous; set what the customer pays for:

   ```sh
   openstack quota set --instances 10 --cores 20 --ram 40960 \
     --volumes 10 --gigabytes 500 --snapshots 10 \
     --floating-ips 5 --networks 5 --routers 2 --ports 100 \
     --secgroups 10 --secgroup-rules 100 "$PROJECT"
   openstack loadbalancer quota set --loadbalancer 2 --listener 10 --pool 10 "$PROJECT"
   ```

   RAM is in MB. Object storage (RGW) has no quota by default.

4. **Network, subnet and router**, so the customer can start straight away:

   ```sh
   openstack network create --project "$PROJECT" "$CUST-net"
   openstack subnet create --project "$PROJECT" --network "$CUST-net" \
     --subnet-range "$CIDR" --dns-nameserver 192.168.8.50 "$CUST-subnet"
   openstack router create --project "$PROJECT" \
     --external-gateway public "$CUST-router"
   openstack router add subnet "$CUST-router" "$CUST-subnet"
   ```

   Each project has its own address space, so customers may reuse the same
   `CIDR`. Skip this step if the customer builds their own networks.

5. **Security group** for SSH and ping. Every project has a `default` group
   that allows no incoming traffic; customers usually manage their own, but
   a starter group saves a support call:

   ```sh
   openstack security group create --project "$PROJECT" \
     --description "SSH and ICMP from anywhere" ssh-icmp
   SG=$(openstack security group list --project "$PROJECT" -f value -c ID -c Name \
     | awk '$2 == "ssh-icmp" {print $1}')
   openstack security group rule create --project "$PROJECT" --protocol tcp --dst-port 22 "$SG"
   openstack security group rule create --project "$PROJECT" --protocol icmp "$SG"
   ```

6. **Check** by logging in as the customer, see
   [Give the customer a clouds.yaml](#give-the-customer-a-cloudsyaml), and
   run `openstack server list`.

### In Horizon

Identity → Projects → Create Project (pick domain `customers` first in
Identity → Domains → Set Domain Context). Then Identity → Users → Create
User, and Project → Network for the network and router while acting as the
project. Quotas are under the project's dropdown → Modify Quotas.

### With Ansible

`ansible/cloud.yml` onboards the one customer in `customer:` in
`ansible/group_vars/openstack.yml`. Change those values and re-run it to
onboard another; the earlier customer stays. Only the steps above are done,
with the password written to `secrets/<user>-password`, plus a mail domain
and mailboxes on hermes (`customer.mail`, see [Mail](../README.md#mail)), and
a DNS zone for that domain with an MX for hermes. Keep the domain under
`example.`: the LAN's resolver forwards the whole reserved TLD to the lab's
PowerDNS, so any other domain resolves nowhere and the cloud's mail to the
customer bounces. The teardown removes only the mail domain of the customer
configured at the time, and its zone.

## Give the customer a clouds.yaml

```yaml
clouds:
  acme:
    auth:
      auth_url: https://api.openstack.home:5000
      user_domain_name: customers
      project_domain_name: customers
      project_name: acme
      username: acme-admin
      password: <password>
    region_name: RegionOne
    interface: public
    identity_api_version: 3
    cacert: /path/to/root.crt
```

Send `secrets/root.crt` along with it. Horizon is the same
[https://api.openstack.home/](https://api.openstack.home/) the operators use;
the customer fills in domain `customers` in the login form.

For automation, prefer an **application credential**: the customer creates
it themselves, it is limited to one project, can expire and can be revoked
without changing the password.

```sh
openstack --os-cloud acme application credential create \
  --role member --expiration 2027-01-01T00:00:00 terraform
```

```yaml
clouds:
  acme-ci:
    auth_type: v3applicationcredential
    auth:
      auth_url: https://api.openstack.home:5000
      application_credential_id: <id>
      application_credential_secret: <secret>
    region_name: RegionOne
    cacert: /path/to/root.crt
```

## View customers

```sh
openstack project list --domain customers --long
openstack project show "$PROJECT"
openstack role assignment list --project "$PROJECT" --names
openstack user list --domain customers --long

# Quota and what is used of it
openstack quota show --usage "$PROJECT"
openstack loadbalancer quota show "$PROJECT"

# Their resources
openstack server list --project "$PROJECT"
openstack volume list --project "$PROJECT"
openstack floating ip list --project "$PROJECT"
openstack loadbalancer list --project "$PROJECT"
openstack usage show --project "$PROJECT" --start 2026-10-01
```

## Change a customer

| Task | Command |
|---|---|
| Rename, describe | `openstack project set --name <new> --description "..." "$PROJECT"` |
| Change the quota | `openstack quota set --cores 40 --ram 81920 "$PROJECT"` |
| Add a user | Steps 2 above, with the new user's name |
| Give an existing user access | `openstack role add --user <user> --user-domain customers --project "$PROJECT" member` |
| Make a user read-only | `openstack role remove ... member`, then `openstack role add ... reader` |
| Reset a password | `openstack user set --password-prompt --domain customers <user>` |
| Lock a user out | `openstack user set --disable --domain customers <user>` |
| Remove a user's access | `openstack role remove --user <user> --user-domain customers --project "$PROJECT" member` |

### Suspend a customer

Disabling the project stops anyone getting a token for it, but leaves its
instances running. To suspend it entirely:

```sh
openstack project set --disable "$PROJECT"
for s in $(openstack server list --project "$PROJECT" -f value -c ID); do
  openstack server stop "$s"
done
```

To resume, `openstack project set --enable` and start the servers again.

## Delete a customer

Deleting a project in Keystone doesn't delete its resources: they keep
running and keep using capacity, with nothing to log in as. Empty the project
first.

1. **Suspend it** as above, so nothing new appears while you clean up.

2. **Remove what `project cleanup` doesn't handle**: load balancers, Heat
   stacks, DNS zones, secrets and object storage. As admin:

   ```sh
   openstack loadbalancer list --project "$PROJECT" -f value -c id \
     | xargs -r -n1 openstack loadbalancer delete --cascade
   openstack stack list --project "$PROJECT" -f value -c ID \
     | xargs -r openstack stack delete --yes --wait
   openstack zone list --all-projects -f value -c id -c project_id \
     | awk -v p="$PROJECT" '$2 == p {print $1}' \
     | xargs -r -n1 openstack zone delete --all-projects
   ```

   Object containers and Barbican secrets are only visible to the project
   itself. Give yourself access, clean up, then take it away again (`$CUST`
   is the project's name):

   ```sh
   openstack role add --user admin --user-domain Default --project "$PROJECT" member
   openstack --os-project-name "$CUST" --os-project-domain-name customers container list
   openstack --os-project-name "$CUST" --os-project-domain-name customers container delete --recursive <container>
   openstack --os-project-name "$CUST" --os-project-domain-name customers secret list
   openstack --os-project-name "$CUST" --os-project-domain-name customers secret delete <href>
   openstack role remove --user admin --user-domain Default --project "$PROJECT" member
   ```

3. **Delete the rest**: servers, volumes, snapshots, backups, images,
   floating IPs, routers, networks, security groups. Look first:

   ```sh
   openstack project cleanup --project "$PROJECT" --dry-run
   openstack project cleanup --project "$PROJECT" --auto-approve
   ```

   Run the dry run again afterwards; it should list nothing. Volumes in
   `error` or `in-use` states may need `openstack volume set --state
   available <id>` before they delete.

4. **Delete the users and the project**:

   ```sh
   openstack role assignment list --project "$PROJECT" --names
   openstack user delete --domain customers "$USER"
   openstack project delete "$PROJECT"
   ```

   Only delete users that belong to this customer alone.

5. **Check** nothing is left with the project's ID:

   ```sh
   openstack port list --project "$PROJECT"
   openstack volume list --all-projects --project "$PROJECT"
   ```
