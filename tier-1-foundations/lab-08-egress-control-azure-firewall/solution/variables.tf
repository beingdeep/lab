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
  default     = "rg-lab08"
}

variable "hub_vnet_name" {
  description = "Hub virtual network name."
  type        = string
  default     = "vnet-hub"
}

variable "spoke_vnet_name" {
  description = "Spoke virtual network name."
  type        = string
  default     = "vnet-spoke"
}

variable "hub_address_space" {
  description = "Hub address space."
  type        = string
  default     = "10.80.0.0/16"
}

variable "spoke_address_space" {
  description = "Spoke address space."
  type        = string
  default     = "10.81.0.0/16"
}

variable "allowed_fqdns" {
  description = <<-EOT
    The entire list of hostnames the spoke workloads may reach. Everything not on
    it is denied by the implicit default - you never write a deny rule.
  EOT
  type        = list(string)
  default = [
    "archive.ubuntu.com",
    "security.ubuntu.com",
    "login.microsoftonline.com",
  ]
}

variable "network_rule_destination" {
  description = <<-EOT
    A single address reachable through a network rule rather than an application
    rule. This exists purely so you can send the same kind of request twice and
    compare what lands in AZFWNetworkRule versus AZFWApplicationRule.
  EOT
  type        = string
  default     = "1.1.1.1"
}

variable "add_broad_network_rule" {
  description = <<-EOT
    Set to true to add a network rule allowing all of TCP 443 to anywhere. Because
    network rules are evaluated before application rules, this causes the entire
    FQDN allow-list to stop applying - with no error, no warning and no change to
    any of the application rules. This is how FQDN filtering gets quietly disabled
    in real estates.
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Log Analytics retention."
  type        = number
  default     = 30
}

variable "deploy_bastion" {
  description = "Deploy Azure Bastion in the hub so you can sign in to the workload VM."
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Size of the spoke workload VM."
  type        = string
  default     = "Standard_B1s"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "08-egress-control-azure-firewall"
  }
}
