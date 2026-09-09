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
  default     = "rg-lab13"
}

variable "vnet_name" {
  description = "Virtual network name."
  type        = string
  default     = "vnet-lab13"
}

variable "vnet_address_space" {
  description = "Address space for the lab virtual network."
  type        = string
  default     = "10.130.0.0/16"
}

variable "scale_set_name" {
  description = "Name of the agent scale set."
  type        = string
  default     = "vmss-agents"
}

variable "name_suffix" {
  description = "Suffix for the globally unique container registry name. Empty means random."
  type        = string
  default     = ""
}

variable "instance_size" {
  description = "VM size for the build agents."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "min_instances" {
  description = <<-EOT
    Autoscale floor. Zero costs nothing when idle but makes the first build of the
    day wait for a machine to boot and register. Whether that is acceptable is a
    real trade-off - decide it deliberately.
  EOT
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Autoscale ceiling."
  type        = number
  default     = 5
}

variable "admin_ssh_public_key" {
  description = <<-EOT
    SSH public key for the agent instances. Leave empty to read ~/.ssh/id_rsa.pub.
    There is no password option: a build agent runs code from every pull request,
    so anything stored on it is readable by anyone who can open one.
  EOT
  type        = string
  default     = ""
}

variable "allowed_service_tags" {
  description = <<-EOT
    The only destinations agents may reach outside the VNet. Service tags rather
    than addresses, because Microsoft updates the ranges behind them without
    notice and a rule written against addresses quietly stops covering them.
  EOT
  type        = list(string)
  default = [
    "AzureActiveDirectory",
    "AzureDevOps",
    "AzureContainerRegistry",
    "Storage",
  ]
}

variable "allow_all_egress" {
  description = <<-EOT
    Set to true to drop the outbound restrictions and let agents reach anything,
    which is the state most self-hosted agent fleets are actually in. Worth seeing
    once, on a machine that runs untrusted pull request code.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "13-self-hosted-build-agents"
  }
}
