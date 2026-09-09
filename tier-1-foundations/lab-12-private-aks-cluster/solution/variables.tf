variable "subscription_id" {
  description = "Target subscription. Leave null and set ARM_SUBSCRIPTION_ID instead."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for every resource in this lab."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group holding the whole lab."
  type        = string
  default     = "rg-lab12"
}

variable "vnet_name" {
  description = "Virtual network name."
  type        = string
  default     = "vnet-lab12"
}

variable "vnet_address_space" {
  description = "Address space for the lab virtual network."
  type        = string
  default     = "10.120.0.0/16"
}

variable "cluster_name" {
  description = "AKS cluster name."
  type        = string
  default     = "aks-lab12"
}

variable "kubernetes_version" {
  description = "Leave null to take the region's default supported version."
  type        = string
  default     = null
}

variable "node_count" {
  description = "Nodes in the default pool. With overlay, each one uses a single VNet address."
  type        = number
  default     = 2
}

variable "node_size" {
  description = "VM size for the cluster nodes."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "pod_cidr" {
  description = <<-EOT
    Overlay pod address range. Invisible outside the cluster, so it may overlap
    other clusters - but it must NOT overlap this VNet, any peered network,
    on-premises, or anything the pods need to reach.
  EOT
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service range. Also invisible outside the cluster."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = <<-EOT
    Address for CoreDNS. Must be inside service_cidr - CoreDNS is itself a
    Kubernetes service. Pick one outside and the cluster comes up and then fails
    every name lookup.
  EOT
  type        = string
  default     = "172.16.0.10"
}

variable "overlapping_pod_cidr" {
  description = <<-EOT
    Set to true to attempt a pod CIDR that overlaps the virtual network, and see
    how Azure responds. Worth doing once so you know what the error looks like.
  EOT
  type        = bool
  default     = false
}

variable "deploy_bastion" {
  description = "Deploy Azure Bastion so you can sign in to the jump host."
  type        = bool
  default     = true
}

variable "jump_vm_size" {
  description = "Size of the jump host."
  type        = string
  default     = "Standard_B2s"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "12-private-aks-cluster"
  }
}
