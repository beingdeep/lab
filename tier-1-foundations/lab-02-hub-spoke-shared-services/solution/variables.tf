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
  default     = "rg-lab02"
}

variable "hub_vnet_name" {
  description = "Hub virtual network name."
  type        = string
  default     = "vnet-hub"
}

variable "app_spoke_vnet_name" {
  description = "Application workload spoke virtual network name."
  type        = string
  default     = "vnet-spoke-app"
}

variable "shared_spoke_vnet_name" {
  description = "Shared services spoke virtual network name."
  type        = string
  default     = "vnet-spoke-shared"
}

variable "hub_address_space" {
  description = "Hub address space."
  type        = string
  default     = "10.0.0.0/16"
}

variable "app_spoke_address_space" {
  description = "Application spoke address space. Must not overlap the others."
  type        = string
  default     = "10.1.0.0/16"
}

variable "shared_spoke_address_space" {
  description = "Shared services spoke address space. Must not overlap the others."
  type        = string
  default     = "10.2.0.0/16"
}

variable "allowed_ports" {
  description = "Ports the application spoke may use to reach shared services."
  type        = list(string)
  default     = ["443", "3389", "22"]
}

variable "deploy_firewall" {
  description = <<-EOT
    Deploy Azure Firewall and the route tables that depend on it. Set to false to
    build the broken, non-transitive state from Step 5 and inspect the effective
    routes yourself. Azure Firewall bills by the hour.
  EOT
  type        = bool
  default     = true
}

variable "deploy_explicit_deny" {
  description = <<-EOT
    Also create an explicit Deny rule collection for shared -> app. Not required
    for isolation, but it produces a named log entry instead of a generic
    default-deny one.
  EOT
  type        = bool
  default     = true
}

variable "deploy_test_vms" {
  description = "Deploy vm-app and vm-shared for the connectivity tests."
  type        = bool
  default     = true
}

variable "deploy_bastion" {
  description = "Deploy Azure Bastion in the hub so you can sign in to the test VMs."
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Size of the two test VMs."
  type        = string
  default     = "Standard_B1s"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "02-hub-spoke-shared-services"
  }
}
