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
  default     = "rg-lab01"
}

variable "vnet_name" {
  description = "Virtual network name."
  type        = string
  default     = "vnet-lab01"
}

variable "vnet_address_space" {
  description = "Address space for the lab virtual network."
  type        = string
  default     = "10.10.0.0/16"
}

variable "jump_vm_name" {
  description = "Name of the jump VM."
  type        = string
  default     = "vm-jump"
}

variable "jump_vm_size" {
  description = "Size of the jump VM. B-series keeps the lab cheap."
  type        = string
  default     = "Standard_B2s"
}

variable "name_suffix" {
  description = <<-EOT
    Suffix appended to globally unique names (the web app and the SQL server).
    Leave empty to generate a random one.
  EOT
  type        = string
  default     = ""
}

variable "entra_admin_login" {
  description = <<-EOT
    Display name of the Microsoft Entra administrator on the SQL server, for
    example your user principal name. Leave empty to use the object ID of
    whoever is running Terraform.
  EOT
  type        = string
  default     = ""
}

variable "entra_admin_object_id" {
  description = <<-EOT
    Object ID of the Microsoft Entra administrator on the SQL server. Leave empty
    to use whoever is running Terraform.
  EOT
  type        = string
  default     = ""
}

variable "deploy_bastion" {
  description = <<-EOT
    Deploy Azure Bastion so you can sign in to the jump VM. Set to false if you
    only want to inspect the network configuration - it saves a few pounds a day.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "01-private-web-app-jump-vm"
  }
}
