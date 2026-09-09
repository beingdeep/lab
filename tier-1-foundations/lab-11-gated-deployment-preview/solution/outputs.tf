output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "storage_account_name" {
  description = "The thing the pipeline manages."
  value       = azurerm_storage_account.data.name
}

output "destructive_change_armed" {
  description = "When true, the next plan replaces the storage account instead of updating it."
  value       = var.simulate_destructive_change
}

output "step_7_instructions" {
  description = "How to produce the destructive plan for the review exercise."
  value        = <<-EOT
    terraform plan -var 'simulate_destructive_change=true' -out=tfplan
    terraform show -no-color tfplan | tail -20

    Look for the "Plan: 1 to add, 0 to change, 1 to destroy" line, and for the
    "# forces replacement" annotation on account_kind. Then reject it.

    Now automate the catch, so nobody has to spot it by eye:

      terraform show -json tfplan \
        | jq '[.resource_changes[] | select(.change.actions[] | . == "delete")] | length'

    Fail the job if that number is greater than zero unless an override is set.
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
  ])
}
