output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.lab.name
}

output "key_vault_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Resolve this hostname from vm-app - expect a private address."
  value       = azurerm_key_vault.this.vault_uri
}

output "private_endpoint_ip" {
  description = "What the vault hostname should resolve to inside the VNet."
  value       = azurerm_private_endpoint.kv.private_service_connection[0].private_ip_address
}

output "app_identity_principal_id" {
  description = "The only principal with a data-plane role on this vault."
  value       = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

output "vm_password" {
  description = "Sign in to vm-app through Bastion as 'azureuser' with this password."
  value       = random_password.vm.result
  sensitive   = true
}

output "step_7_from_vm" {
  description = "Step 7 - create the secret from inside the network, not from your laptop."
  value        = <<-EOT
    # On vm-app, after installing the Azure CLI:
    az login --identity

    # Reading works straight away - the identity holds Key Vault Secrets User:
    az keyvault secret show --vault-name ${azurerm_key_vault.this.name} -n app-connection-string

    # Writing does not. Grant yourself Secrets Officer deliberately, write, remove
    # it again, and notice that all three actions are timestamped and attributable
    # in a way an access policy never would be.
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-VnetName ${azurerm_virtual_network.lab.name}",
    "-KeyVaultName ${azurerm_key_vault.this.name}",
    "-VmName ${azurerm_linux_virtual_machine.app.name}",
  ])
}
