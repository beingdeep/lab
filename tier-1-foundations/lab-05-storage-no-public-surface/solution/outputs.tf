output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.lab.name
}

output "storage_account_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_storage_account.this.name
}

output "blob_endpoint" {
  description = "Resolve this from the VM - expect a private address."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "private_endpoint_ip" {
  description = "What the blob endpoint should resolve to inside the VNet."
  value       = azurerm_private_endpoint.blob.private_service_connection[0].private_ip_address
}

output "app_identity_principal_id" {
  description = "The managed identity holding Storage Blob Data Contributor."
  value       = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

output "vm_password" {
  description = "Sign in to vm-app through Bastion as 'azureuser' with this password."
  value       = random_password.vm.result
  sensitive   = true
}

output "test_from_vm" {
  description = "Run this on vm-app once the Azure CLI is installed there."
  value = join(" ", [
    "az login --identity;",
    "az storage blob list --auth-mode login",
    "--account-name ${azurerm_storage_account.this.name}",
    "-c ${azurerm_storage_container.app_data.name} -o table",
  ])
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-VnetName ${azurerm_virtual_network.lab.name}",
    "-StorageAccountName ${azurerm_storage_account.this.name}",
    "-VmName ${azurerm_linux_virtual_machine.app.name}",
  ])
}
