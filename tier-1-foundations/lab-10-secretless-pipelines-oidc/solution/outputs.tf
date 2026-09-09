output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "identity_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_user_assigned_identity.deploy.name
}

output "client_id" {
  description = "AZURE_CLIENT_ID in the workflow. Not a secret - it is an identifier."
  value       = azurerm_user_assigned_identity.deploy.client_id
}

output "tenant_id" {
  description = "AZURE_TENANT_ID in the workflow. Not a secret."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "AZURE_SUBSCRIPTION_ID in the workflow. Not a secret."
  value       = data.azurerm_client_config.current.subscription_id
}

output "trusted_subjects" {
  description = "The exact strings Entra will accept. Anything else fails at login."
  value = compact([
    local.branch_subject,
    local.environment_subject,
    var.use_wildcard_subject ? local.wildcard_subject : "",
  ])
}

output "workflow_variables" {
  description = "Set these as repository variables (not secrets) in GitHub."
  value        = <<-EOT
    AZURE_CLIENT_ID       = ${azurerm_user_assigned_identity.deploy.client_id}
    AZURE_TENANT_ID       = ${data.azurerm_client_config.current.tenant_id}
    AZURE_SUBSCRIPTION_ID = ${data.azurerm_client_config.current.subscription_id}

    Then copy pipelines/deploy.yml into .github/workflows/ in your repository.
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-IdentityName ${azurerm_user_assigned_identity.deploy.name}",
  ])
}
