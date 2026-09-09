output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.lab.name
}

output "scale_set_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_linux_virtual_machine_scale_set.agents.name
}

output "registry_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_container_registry.acr.name
}

output "registry_login_server" {
  description = "The only registry the agents can reach."
  value       = azurerm_container_registry.acr.login_server
}

output "egress_ip" {
  description = "Every agent leaves from this one address. Give it to anyone who needs to allow-list you."
  value       = azurerm_public_ip.nat.ip_address
}

output "allowed_destinations" {
  description = "Everything outside the VNet that agents may reach."
  value       = var.allow_all_egress ? ["ANYTHING - allow_all_egress is on"] : var.allowed_service_tags
}

output "step_9_tests" {
  description = "Run these on an agent instance."
  value        = <<-EOT
    # your registry, over the private endpoint - expect success
    getent hosts ${azurerm_container_registry.acr.login_server}   # expect 10.130.2.x
    az login --identity && az acr login -n ${azurerm_container_registry.acr.name}

    # a public registry - expect failure
    curl -sS -m 10 https://registry-1.docker.io/v2/

    # anything else - expect failure
    curl -sS -m 10 https://example.org/
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-VnetName ${azurerm_virtual_network.lab.name}",
    "-ScaleSetName ${azurerm_linux_virtual_machine_scale_set.agents.name}",
    "-RegistryName ${azurerm_container_registry.acr.name}",
  ])
}
