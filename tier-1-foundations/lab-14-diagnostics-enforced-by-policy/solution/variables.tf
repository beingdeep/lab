variable "subscription_id" {
  description = "Target subscription. Leave null and set ARM_SUBSCRIPTION_ID instead."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for every resource in this lab, and for the policy assignment's identity."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group holding the workspace and the test resource."
  type        = string
  default     = "rg-lab14"
}

variable "policy_definition_name" {
  description = "Name of the custom policy definition."
  type        = string
  default     = "deploy-nsg-diagnostics"
}

variable "assignment_name" {
  description = "Name of the subscription-scope policy assignment."
  type        = string
  default     = "enforce-nsg-diagnostics"
}

variable "name_suffix" {
  description = "Suffix for the globally unique workspace name. Empty means random."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Log Analytics retention."
  type        = number
  default     = 30
}

variable "assignment_enforcement" {
  description = <<-EOT
    "Default" deploys. "DoNotEnforce" evaluates and reports compliance without
    changing anything - which is how you would introduce this to an estate you do
    not own, before turning it on.
  EOT
  type        = string
  default     = "Default"

  validation {
    condition     = contains(["Default", "DoNotEnforce"], var.assignment_enforcement)
    error_message = "assignment_enforcement must be Default or DoNotEnforce."
  }
}

variable "create_test_nsg" {
  description = <<-EOT
    Create a network security group after the assignment exists, so you have
    something for Step 6 to have caught. Give it a few minutes, then look at its
    diagnostic settings.
  EOT
  type        = bool
  default     = true
}

variable "role_propagation_delay" {
  description = <<-EOT
    How long to wait after granting the policy identity its roles before creating
    the remediation task. Role assignments are eventually consistent, and a
    remediation started too early fails every deployment.
  EOT
  type        = string
  default     = "60s"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "14-diagnostics-enforced-by-policy"
  }
}
