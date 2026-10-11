output "nodes" {
  description = "OpenStack nodes with their VMID and management address"
  value = {
    for name, node in local.nodes : name => {
      vm_id = node.vm_id
      mgmt  = cidrhost(local.net.mgmt_subnet, node.host)
    }
  }
}

output "endpoints" {
  description = "VIPs and the public endpoint name, which needs a DNS record or hosts entry on the client"
  value = {
    internal_vip = cidrhost(local.net.mgmt_subnet, tonumber(local.net.vip_host))
    external_vip = cidrhost(local.net.api_subnet, tonumber(local.net.vip_host))
    public_fqdn  = "api.${local.net.domain}"
    horizon      = "https://api.${local.net.domain}/"
  }
}
