output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.lab.name
}

output "app_gateway_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_application_gateway.agw.name
}

output "web_app_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_linux_web_app.app.name
}

output "gateway_public_ip" {
  description = "Send your test requests here."
  value       = azurerm_public_ip.agw.ip_address
}

output "app_public_hostname" {
  description = "Request this directly - it should return 403, not your app."
  value       = azurerm_linux_web_app.app.default_hostname
}

output "waf_mode" {
  description = "Prevention blocks. Detection logs and serves the request anyway."
  value       = azurerm_web_application_firewall_policy.waf.policy_settings[0].mode
}

output "test_requests" {
  description = "The three checks from Step 7. Self-signed certificate, so -k is required."
  value        = <<-EOT
    # normal traffic, expect 200
    curl -k -s -o /dev/null -w '%%{http_code}\n' "https://${azurerm_public_ip.agw.ip_address}/"

    # injection payload, expect 403 in Prevention mode
    curl -k -s -o /dev/null -w '%%{http_code}\n' "https://${azurerm_public_ip.agw.ip_address}/?id=1%%27%%20or%%20%%271%%27=%%271"

    # straight at the app, expect 403 - the gateway must be the only way in
    curl -s -o /dev/null -w '%%{http_code}\n' "https://${azurerm_linux_web_app.app.default_hostname}/"
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-VnetName ${azurerm_virtual_network.lab.name}",
    "-AppGatewayName ${azurerm_application_gateway.agw.name}",
    "-WebAppName ${azurerm_linux_web_app.app.name}",
    "-Probe",
  ])
}
