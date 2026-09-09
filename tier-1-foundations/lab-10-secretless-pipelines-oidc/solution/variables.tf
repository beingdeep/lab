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
  description = "The only scope the pipeline is allowed to deploy into."
  type        = string
  default     = "rg-lab10"
}

variable "identity_name" {
  description = <<-EOT
    User-assigned managed identity the pipeline becomes. A managed identity has no
    secret and no way to add one, which removes the temptation to undo this lab
    later by adding a client secret "just for now".
  EOT
  type        = string
  default     = "id-deploy-lab10"
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository. Required."
  type        = string
}

variable "github_repo" {
  description = "Repository name, without the owner. Required."
  type        = string
}

variable "github_branch" {
  description = "The single branch permitted to authenticate."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "The single GitHub environment permitted to authenticate."
  type        = string
  default     = "production"
}

variable "use_wildcard_subject" {
  description = <<-EOT
    Set to true to build the broken version: a subject that matches any branch in
    the repository. The "wrong branch fails" test then stops failing, which is the
    mistake this lab exists to prevent. Entra does not pattern match subjects, so
    this works by registering a credential for the repository rather than a branch.
  EOT
  type        = bool
  default     = false
}

variable "role_definition_name" {
  description = <<-EOT
    Role granted to the pipeline identity on the resource group. Not Owner: Owner
    includes creating role assignments, which lets the pipeline grant itself
    anything.
  EOT
  type        = string
  default     = "Contributor"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "10-secretless-pipelines-oidc"
  }
}
