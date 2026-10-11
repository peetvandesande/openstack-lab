locals {
  # network.conf, as a map of lowercase keys, so the address plan has a
  # single source shared with the playbooks
  net = {
    for m in regexall("(?m)^([A-Z_]+)=\"?([^\"\\r\\n]*)\"?", file("${path.module}/network.conf")) :
    lower(m[0]) => trimspace(m[1])
  }

  # One NIC per network, in this order (net0 = mgmt). The playbooks rename
  # each NIC inside the VM to the key, by MAC address
  networks = {
    mgmt = { vnet = local.net.mgmt_vnet, subnet = local.net.mgmt_subnet }
    api  = { vnet = local.net.api_vnet, subnet = local.net.api_subnet }
    stor = { vnet = local.net.storage_vnet, subnet = local.net.storage_subnet }
    repl = { vnet = local.net.replication_vnet, subnet = local.net.replication_subnet }
    tun  = { vnet = local.net.tunnel_vnet, subnet = local.net.tunnel_subnet }
    ext  = { vnet = local.net.provider_vnet, subnet = null }
  }
  nic_order = ["mgmt", "api", "stor", "repl", "tun", "ext"]

  nodes = {
    for i in range(var.node_count) : "${var.name_prefix}-${i + 1}" => {
      vm_id = var.vm_id_start + i
      host  = tonumber(local.net.node_host_start) + i
    }
  }

  # The OS disk is scsi0; the OSD disks follow
  osd_disks = [for i in range(var.osd_disk_count) : "scsi${i + 1}"]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name        = each.key
  vm_id       = each.value.vm_id
  node_name   = var.node_name
  pool_id     = var.pool_id
  description = "OpenStack node (control, network, compute and Ceph), managed by OpenTofu"
  tags        = ["openstack", "opentofu"]

  on_boot         = false
  started         = true
  stop_on_destroy = true

  machine = "q35"

  operating_system {
    type = "l26"
  }

  # Nested virtualisation for Nova: CPU type must be host
  cpu {
    type    = "host"
    cores   = var.cores
    sockets = 1
  }

  # No ballooning: Ceph and the OpenStack services size themselves on start
  memory {
    dedicated = var.memory_mb
    floating  = 0
  }

  scsi_hardware = "virtio-scsi-single"

  # System disk, imported from the cloud image
  disk {
    interface    = "scsi0"
    datastore_id = var.datastore_id
    import_from  = var.cloud_image_file_id
    size         = var.os_disk_gb
    iothread     = true
    ssd          = true
    discard      = "on"
  }

  # Empty disks, picked up by Ceph as OSDs
  dynamic "disk" {
    for_each = local.osd_disks
    content {
      interface    = disk.value
      datastore_id = var.datastore_id
      size         = var.osd_disk_gb
      file_format  = "raw"
      iothread     = true
      ssd          = true
      discard      = "on"
    }
  }

  boot_order = ["scsi0"]

  # Firewall off: its MAC filtering drops traffic from the instances and the
  # VIPs, which use MACs Proxmox does not know about
  dynamic "network_device" {
    for_each = local.nic_order
    content {
      bridge   = local.networks[network_device.value].vnet
      model    = "virtio"
      firewall = false
    }
  }

  # Only the management NIC is configured at first boot; the playbooks set up
  # the rest
  initialization {
    datastore_id = var.datastore_id

    dns {
      domain  = local.net.domain
      servers = split(" ", local.net.dns_servers)
    }

    ip_config {
      ipv4 {
        address = "${cidrhost(local.net.mgmt_subnet, each.value.host)}/${split("/", local.net.mgmt_subnet)[1]}"
        gateway = local.net.mgmt_gateway
      }
    }

    user_account {
      username = "ubuntu"
      keys     = [local.ssh_public_key]
    }
  }

  # Ubuntu cloud images log to the serial console
  serial_device {}

  lifecycle {
    # Cloud-init only runs on first boot; changing it later has no effect
    ignore_changes = [initialization]
  }
}

# Inventory for the playbooks. Host keys are not checked: the nodes get new
# ones every time they are recreated
resource "local_file" "inventory" {
  filename        = "${path.module}/ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = yamlencode({
    all = {
      children = {
        openstack = {
          hosts = {
            for name, node in local.nodes : name => {
              ansible_host = cidrhost(local.net.mgmt_subnet, node.host)
              vm_id        = node.vm_id
              nics = {
                for idx, nic in local.nic_order : nic => {
                  mac     = lower(proxmox_virtual_environment_vm.node[name].network_device[idx].mac_address)
                  address = local.networks[nic].subnet == null ? null : "${cidrhost(local.networks[nic].subnet, node.host)}/${split("/", local.networks[nic].subnet)[1]}"
                }
              }
            }
          }
          vars = {
            ansible_user            = "ubuntu"
            ansible_become          = true
            ansible_ssh_common_args = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            lab_net                 = local.net
            vips = {
              internal = cidrhost(local.net.mgmt_subnet, tonumber(local.net.vip_host))
              external = cidrhost(local.net.api_subnet, tonumber(local.net.vip_host))
            }
            osd_disk_count = var.osd_disk_count
          }
        }
      }
    }
  })
}
