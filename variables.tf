# Proxmox connection

variable "pm_endpoint" {
  description = "Proxmox API endpoint, without /api2/json, e.g. https://lenora.home:8006/"
  type        = string
}

variable "pm_api_token" {
  description = "Proxmox API token, e.g. terraform@pve!openstack-lab=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  type        = string
  sensitive   = true
}

variable "pm_insecure" {
  description = "Skip TLS verification (only if the Proxmox CA is not in the system trust store)"
  type        = bool
  default     = false
}

# Placement

variable "node_name" {
  description = "Proxmox node to create the VMs on"
  type        = string
}

variable "pool_id" {
  description = "Existing resource pool the VMs are placed in; the API token should only have rights on this pool"
  type        = string
  default     = "openstack-lab"
}

variable "vm_id_start" {
  description = "First VMID; the nodes use vm_id_start to vm_id_start + node_count - 1. Make sure these are free."
  type        = number
}

variable "datastore_id" {
  description = "Datastore for the VM disks and the cloud-init drives"
  type        = string
  default     = "local-zfs"
}

variable "cloud_image_file_id" {
  description = "Ubuntu 24.04 cloud image as an import volume; ansible/bootstrap.yml downloads it"
  type        = string
  default     = "local:import/noble-server-cloudimg-amd64.qcow2"
}

variable "cloud_image_url" {
  description = "Where ansible/bootstrap.yml downloads the cloud image from"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ssh_public_key_file" {
  description = "Public key for the ubuntu user on the nodes"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# Node sizing. Every node runs the control plane, compute, networking and
# Ceph (hyperconverged)

variable "node_count" {
  description = "Number of OpenStack nodes; 3 for a quorum of MariaDB, RabbitMQ and the Ceph monitors"
  type        = number
  default     = 3
}

variable "name_prefix" {
  description = "VM name and hostname prefix; nodes are named <prefix>-1, <prefix>-2, ..."
  type        = string
  default     = "os"
}

variable "cores" {
  description = "vCPUs per node"
  type        = number
  default     = 16
}

variable "memory_mb" {
  description = "RAM per node in MB"
  type        = number
  default     = 65536
}

variable "os_disk_gb" {
  description = "System disk size in GB (Docker images and logs live here)"
  type        = number
  default     = 100
}

variable "osd_disk_count" {
  description = "Ceph OSD disks per node"
  type        = number
  default     = 2
}

variable "osd_disk_gb" {
  description = "Size of each Ceph OSD disk in GB"
  type        = number
  default     = 250
}
