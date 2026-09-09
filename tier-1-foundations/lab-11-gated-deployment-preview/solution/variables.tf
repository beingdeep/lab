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
  description = "The scope this pipeline manages."
  type        = string
  default     = "rg-lab11"
}

variable "name_suffix" {
  description = "Suffix for the globally unique storage account name. Empty means random."
  type        = string
  default     = ""
}

variable "simulate_destructive_change" {
  description = <<-EOT
    Step 7. Set to true and run "terraform plan" to produce a plan that replaces
    the storage account rather than updating it - the plan then reports
    "1 to destroy". Changing account_kind forces replacement, which is exactly
    the kind of change that hides in the middle of a four hundred line plan and
    gets approved at five o'clock on a Friday.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "11-gated-deployment-preview"
  }
}
