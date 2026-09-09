output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.state.name
}

output "storage_account_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_storage_account.state.name
}

output "container_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_storage_container.state.name
}

output "identity_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_user_assigned_identity.pipeline.name
}

output "identity_client_id" {
  description = "Set as ARM_CLIENT_ID when the pipeline authenticates as this identity."
  value       = azurerm_user_assigned_identity.pipeline.client_id
}

output "backend_block" {
  description = "Paste this into the project whose state you want to store here."
  value        = <<-EOT
    terraform {
      backend "azurerm" {
        resource_group_name  = "${azurerm_resource_group.state.name}"
        storage_account_name = "${azurerm_storage_account.state.name}"
        container_name       = "${azurerm_storage_container.state.name}"
        key                  = "workload.tfstate"
        use_azuread_auth     = true
      }
    }

    # No access_key. No sas_token. No connection string. No ARM_ACCESS_KEY.
    # "key" above is the name of the blob, not a credential.
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.state.name}",
    "-StorageAccountName ${azurerm_storage_account.state.name}",
    "-ContainerName ${azurerm_storage_container.state.name}",
    "-IdentityName ${azurerm_user_assigned_identity.pipeline.name}",
  ])
}
