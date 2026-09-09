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
  description = "Resource group holding the networks, endpoints and services."
  type        = string
  default     = "rg-lab03"
}

variable "dns_resource_group_name" {
  description = <<-EOT
    Separate resource group for the private DNS zones. Zones are shared platform
    state used by all three networks - keeping them out of an application's
    resource group means deleting that application does not take name resolution
    away from everyone else.
  EOT
  type        = string
  default     = "rg-lab03-dns"
}

variable "vnets" {
  description = <<-EOT
    The three virtual networks, keyed by name. Each gets a workload subnet and a
    private endpoint subnet carved out of its address space.
  EOT
  type = map(object({
    address_space = string
  }))
  default = {
    "vnet-a" = { address_space = "10.0.0.0/16" }
    "vnet-b" = { address_space = "10.1.0.0/16" }
    "vnet-c" = { address_space = "10.2.0.0/16" }
  }
}

variable "name_suffix" {
  description = <<-EOT
    Suffix appended to the globally unique service names. Leave empty to generate
    a random one.
  EOT
  type        = string
  default     = ""
}

variable "deploy_test_vms" {
  description = "Deploy vm-a, vm-b and vm-c so you can run the nine lookups."
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Size of the three test VMs."
  type        = string
  default     = "Standard_B1s"
}

variable "break_vnet_c_blob_link" {
  description = <<-EOT
    Step 10. Set to true and apply again to remove vnet-c's link to the blob zone,
    reproducing the silent failure. vm-c will then resolve the storage account to
    its public address while vm-a and vm-b still resolve it privately. Set back to
    false to repair it.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "03-private-dns-across-peerings"
  }
}
