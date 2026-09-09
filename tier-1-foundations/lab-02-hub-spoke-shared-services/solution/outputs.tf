output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "hub_vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.hub.name
}

output "app_spoke_vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.app.name
}

output "shared_spoke_vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.shared.name
}

output "firewall_private_ip" {
  description = "The next hop your spoke route tables point at."
  value       = local.firewall_private_ip
}

output "app_vm_private_ip" {
  description = "Target this from vm-shared - the connection should time out."
  value       = one(azurerm_network_interface.app[*].private_ip_address)
}

output "shared_vm_private_ip" {
  description = "Target this from vm-app - the connection should succeed."
  value       = one(azurerm_network_interface.shared[*].private_ip_address)
}

output "vm_password" {
  description = "Sign in to either VM through Bastion as 'azureuser' with this password."
  value       = one(random_password.vm[*].result)
  sensitive   = true
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", compact([
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-HubVnetName ${azurerm_virtual_network.hub.name}",
    "-AppSpokeVnetName ${azurerm_virtual_network.app.name}",
    "-SharedSpokeVnetName ${azurerm_virtual_network.shared.name}",
    "-AppSubnetName ${azurerm_subnet.app.name}",
    "-SharedSubnetName ${azurerm_subnet.shared.name}",
    var.deploy_test_vms ? "-AppVmName vm-app -SharedVmName vm-shared" : "",
  ]))
}
