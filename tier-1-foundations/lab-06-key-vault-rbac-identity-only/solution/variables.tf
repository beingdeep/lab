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
  default     = "rg-lab06"
}

variable "vnet_name" {
  description = "Virtual network name."
  type        = string
  default     = "vnet-lab06"
}

variable "vnet_address_space" {
  description = "Address space for the lab virtual network."
  type        = string
  default     = "10.60.0.0/16"
}

variable "name_suffix" {
  description = "Suffix for the globally unique Key Vault name. Empty means random."
  type        = string
  default     = ""
}

variable "grant_app_identity" {
  description = <<-EOT
    Assign Key Vault Secrets User to the application's managed identity. Set to
    false and re-apply to perform Step 8 - removing the grant without touching
    anything else - then time how long the application keeps working on its
    cached token.
  EOT
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
    lab = "06-key-vault-rbac-identity-only"
  }
}
