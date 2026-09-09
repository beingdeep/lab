output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.lab.name
}

output "web_app_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_linux_web_app.app.name
}

output "sql_server_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_mssql_server.sql.name
}

output "jump_vm_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_linux_virtual_machine.jump.name
}

output "web_private_endpoint_ip" {
  description = "What the app's hostname should resolve to from inside the VNet."
  value       = azurerm_private_endpoint.web.private_service_connection[0].private_ip_address
}

output "sql_private_endpoint_ip" {
  description = "What the SQL server's hostname should resolve to from inside the VNet."
  value       = azurerm_private_endpoint.sql.private_service_connection[0].private_ip_address
}

output "web_app_public_hostname" {
  description = "Request this from your laptop - it should return HTTP 403."
  value       = azurerm_linux_web_app.app.default_hostname
}

output "jump_vm_password" {
  description = "Sign in through Bastion as 'azureuser' with this password."
  value       = random_password.vm.result
  sensitive   = true
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-VnetName ${azurerm_virtual_network.lab.name}",
    "-WebAppName ${azurerm_linux_web_app.app.name}",
    "-SqlServerName ${azurerm_mssql_server.sql.name}",
    "-JumpVmName ${azurerm_linux_virtual_machine.jump.name}",
  ])
}

output "manual_sql_step" {
  description = <<-EOT
    Step 9 cannot be done from Terraform - it needs a live database connection.
    Connect to the database as the Entra admin and run this.
  EOT
  value        = <<-EOT
    CREATE USER [${azurerm_linux_web_app.app.name}] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [${azurerm_linux_web_app.app.name}];
    ALTER ROLE db_datawriter ADD MEMBER [${azurerm_linux_web_app.app.name}];
  EOT
}
