output "workspace_resource_group" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "workspace_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_log_analytics_workspace.law.name
}

output "policy_definition_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_policy_definition.nsg_diagnostics.name
}

output "assignment_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_subscription_policy_assignment.nsg_diagnostics.name
}

output "policy_identity_principal_id" {
  description = "The unattended principal that can create diagnostic settings across the subscription."
  value       = azurerm_subscription_policy_assignment.nsg_diagnostics.identity[0].principal_id
}

output "test_nsg_name" {
  description = "Created after the assignment, so Step 6 is a genuine new-resource test."
  value       = var.create_test_nsg ? azurerm_network_security_group.test[0].name : null
}

output "step_6_check" {
  description = "Give it a few minutes, then look for a diagnostic setting nobody created by hand."
  value        = <<-EOT
    az monitor diagnostic-settings list \
      --resource ${var.create_test_nsg ? azurerm_network_security_group.test[0].id : "<your-nsg-id>"} \
      -o table

    Judge this by the diagnostic setting appearing, not by the compliance
    dashboard. The deployment happens in minutes; compliance state is
    recalculated on a much slower cycle and will convince you it is broken.
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-WorkspaceResourceGroup ${azurerm_resource_group.lab.name}",
    "-WorkspaceName ${azurerm_log_analytics_workspace.law.name}",
    "-PolicyDefinitionName ${azurerm_policy_definition.nsg_diagnostics.name}",
    "-AssignmentName ${azurerm_subscription_policy_assignment.nsg_diagnostics.name}",
    "-TestResourceGroup ${azurerm_resource_group.lab.name}",
  ])
}
