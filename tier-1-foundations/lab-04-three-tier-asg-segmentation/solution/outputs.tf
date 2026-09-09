output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.lab.name
}

output "tier_private_ips" {
  description = "Targets for the connectivity tests."
  value       = { for k, nic in azurerm_network_interface.vm : k => nic.private_ip_address }
}

output "web_asg_member_count" {
  description = "Raise web_instance_count and watch this grow with no rule changes."
  value       = var.web_instance_count
}

output "vm_password" {
  description = "Sign in to any VM through Bastion as 'azureuser' with this password."
  value       = random_password.vm.result
  sensitive   = true
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-VnetName ${azurerm_virtual_network.lab.name}",
    "-WebVmName vm-web-1",
    "-AppVmName vm-app-1",
    "-DbVmName vm-db-1",
  ])
}
