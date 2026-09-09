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
  description = <<-EOT
    Its own resource group. State outlives the things it describes, so it should
    not be inside the group a cleanup might delete.
  EOT
  type        = string
  default     = "rg-lab09-tfstate"
}

variable "container_name" {
  description = "Container holding the state blobs, and the scope of the role assignment."
  type        = string
  default     = "tfstate"
}

variable "identity_name" {
  description = "User-assigned managed identity the pipeline will run as."
  type        = string
  default     = "id-tfstate-pipeline"
}

variable "name_suffix" {
  description = "Suffix for the globally unique storage account name. Empty means random."
  type        = string
  default     = ""
}

variable "retention_days" {
  description = "Blob and container soft delete retention."
  type        = number
  default     = 30

  validation {
    condition     = var.retention_days >= 7 && var.retention_days <= 365
    error_message = "retention_days must be between 7 and 365."
  }
}

variable "scope_role_to_container" {
  description = <<-EOT
    Scope the pipeline's role to the container. Set to false to see the difference:
    at account scope the same role covers every container that will ever exist
    there, including other teams' state files.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "09-terraform-remote-state"
  }
}
