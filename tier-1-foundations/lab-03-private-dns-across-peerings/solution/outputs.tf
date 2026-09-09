output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "dns_resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.dns.name
}

output "vnet_names" {
  description = "Pass these to validate.ps1."
  value       = local.vnet_names
}

output "service_fqdns" {
  description = "The nine lookups to run - each of these from each of the three VMs."
  value = {
    blob  = "${azurerm_storage_account.this.name}.blob.core.windows.net"
    vault = "${azurerm_key_vault.this.name}.vault.azure.net"
    sql   = "${azurerm_mssql_server.this.name}.database.windows.net"
  }
}

output "expected_private_ips" {
  description = "What every VM should resolve those names to. Anything else is a fail."
  value = {
    blob  = azurerm_private_endpoint.storage.private_service_connection[0].private_ip_address
    vault = azurerm_private_endpoint.vault.private_service_connection[0].private_ip_address
    sql   = azurerm_private_endpoint.sql.private_service_connection[0].private_ip_address
  }
}

output "zone_link_count" {
  description = "Should be 9. Drops to 8 while break_vnet_c_blob_link is true."
  value       = length(local.zone_links)
}

output "vm_names" {
  description = "Pass these to validate.ps1 with -LiveDnsTest."
  value       = var.deploy_test_vms ? sort([for vm in azurerm_linux_virtual_machine.vm : vm.name]) : []
}

output "vm_password" {
  description = "Sign in to any of the VMs as 'azureuser' with this password."
  value       = one(random_password.vm[*].result)
  sensitive   = true
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", compact([
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-DnsResourceGroup ${azurerm_resource_group.dns.name}",
    "-VnetNames ${join(",", local.vnet_names)}",
    var.deploy_test_vms ? "-LiveDnsTest -VmNames ${join(",", sort([for vm in azurerm_linux_virtual_machine.vm : vm.name]))}" : "",
  ]))
}
