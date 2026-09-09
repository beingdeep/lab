output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "hub_vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.hub.name
}

output "spoke_vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.spoke.name
}

output "firewall_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_firewall.hub.name
}

output "firewall_private_ip" {
  description = "The next hop in rt-spoke."
  value       = local.firewall_private_ip
}

output "allowed_fqdns" {
  description = "Everything the spoke may reach. Anything else is denied by default."
  value       = var.allowed_fqdns
}

output "log_analytics_workspace" {
  description = "Query AZFWApplicationRule and AZFWNetworkRule here."
  value       = azurerm_log_analytics_workspace.law.name
}

output "vm_password" {
  description = "Sign in to vm-spoke through Bastion as 'azureuser' with this password."
  value       = random_password.vm.result
  sensitive   = true
}

output "step_8_tests" {
  description = "Run these on vm-spoke, then compare the two log tables."
  value        = <<-EOT
    # allowed by an application rule - expect success
    curl -sS -o /dev/null -w '%%{http_code}\n' https://${var.allowed_fqdns[0]}/

    # not on the list - expect a failure
    curl -sS -m 10 -o /dev/null -w '%%{http_code}\n' https://example.org/

    # allowed by a network rule, by address - expect a connection
    curl -sS -m 10 -k -o /dev/null -w '%%{http_code}\n' https://${var.network_rule_destination}/
  EOT
}

output "log_queries" {
  description = "Run these against the workspace and compare the columns you get back."
  value        = <<-EOT
    AZFWApplicationRule | where TimeGenerated > ago(1h) | project TimeGenerated, SourceIp, Fqdn, Action, Rule
    AZFWNetworkRule     | where TimeGenerated > ago(1h) | project TimeGenerated, SourceIp, DestinationIp, DestinationPort, Action
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-HubVnetName ${azurerm_virtual_network.hub.name}",
    "-SpokeVnetName ${azurerm_virtual_network.spoke.name}",
    "-FirewallName ${azurerm_firewall.hub.name}",
    "-VmName ${azurerm_linux_virtual_machine.spoke.name}",
  ])
}
