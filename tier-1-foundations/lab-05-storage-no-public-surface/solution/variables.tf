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
  default     = "rg-lab05"
}

variable "vnet_name" {
  description = "Virtual network name."
  type        = string
  default     = "vnet-lab05"
}

variable "vnet_address_space" {
  description = "Address space for the lab virtual network."
  type        = string
  default     = "10.50.0.0/16"
}

variable "container_name" {
  description = "Blob container the application reads and writes."
  type        = string
  default     = "app-data"
}

variable "name_suffix" {
  description = "Suffix for the globally unique storage account name. Empty means random."
  type        = string
  default     = ""
}

variable "allow_shared_key_access" {
  description = <<-EOT
    Leave false. Set to true to see the hole: your data-plane role assignments are
    still there and still correct, and anyone who can read the account keys
    bypasses every one of them without appearing in the audit trail as anybody.
  EOT
  type        = bool
  default     = false
}

variable "scope_role_to_container" {
  description = <<-EOT
    Scope the application's data role to the container rather than the whole
    account. Account scope covers every container that will ever exist on it.
  EOT
  type        = bool
  default     = true
}

variable "grant_current_user_data_reader" {
  description = "Also give whoever runs Terraform Storage Blob Data Reader, so the portal data browser works."
  type        = bool
  default     = true
}

variable "deploy_bastion" {
  description = "Deploy Azure Bastion so you can sign in to the application VM."
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Size of the application VM."
  type        = string
  default     = "Standard_B1s"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "05-storage-no-public-surface"
  }
}
