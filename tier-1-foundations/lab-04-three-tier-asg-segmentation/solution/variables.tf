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
  default     = "rg-lab04"
}

variable "vnet_name" {
  description = "Virtual network name."
  type        = string
  default     = "vnet-lab04"
}

variable "vnet_address_space" {
  description = "Address space for the lab virtual network."
  type        = string
  default     = "10.40.0.0/16"
}

variable "web_instance_count" {
  description = <<-EOT
    Number of web tier VMs. Raise it and re-apply: the new machines pick up every
    rule the moment their NICs join asg-web, with no rule changes at all. That is
    the "survives scaling out" requirement.
  EOT
  type        = number
  default     = 2
}

variable "deploy_deny_rules" {
  description = <<-EOT
    Set to false to build the trap: allow rules present, deny rules absent. The
    built-in AllowVnetInBound rule at priority 65000 then lets the web tier reach
    the database directly, and nothing looks wrong. Worth seeing once.
  EOT
  type        = bool
  default     = true
}

variable "deploy_bastion" {
  description = "Deploy Azure Bastion so you can sign in and run the connectivity tests."
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Size of the tier VMs."
  type        = string
  default     = "Standard_B1s"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "04-three-tier-asg-segmentation"
  }
}
