output "resource_group_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_resource_group.lab.name
}

output "vnet_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_virtual_network.lab.name
}

output "cluster_name" {
  description = "Pass this to validate.ps1."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "private_fqdn" {
  description = "Resolve this from vm-jump - expect a private address. From your laptop, nothing usable."
  value       = azurerm_kubernetes_cluster.aks.private_fqdn
}

output "node_resource_group" {
  description = "AKS manages this group itself. The outbound load balancer with its public IP lives here."
  value       = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "address_plan" {
  description = "The three ranges, and which of them consumes VNet space."
  value = {
    vnet         = var.vnet_address_space
    node_subnet  = local.subnet_aks
    pod_cidr     = local.effective_pod_cidr
    service_cidr = var.service_cidr
    note         = "Only node_subnet comes out of the VNet. With overlay each node uses one address from it; with traditional CNI it would use one per pod as well."
  }
}

output "vm_password" {
  description = "Sign in to vm-jump through Bastion as 'azureuser' with this password."
  value       = random_password.vm.result
  sensitive   = true
}

output "step_4_from_jump" {
  description = "Run these on vm-jump once the Azure CLI and kubectl are installed."
  value        = <<-EOT
    az login --identity
    az aks get-credentials -g ${azurerm_resource_group.lab.name} -n ${azurerm_kubernetes_cluster.aks.name}

    getent hosts ${azurerm_kubernetes_cluster.aks.private_fqdn}   # expect 10.120.x.x
    kubectl get nodes -o wide                                     # node IPs from ${local.subnet_aks}
    kubectl get pods -A -o wide                                   # pod IPs from ${local.effective_pod_cidr}
  EOT
}

output "validate_command" {
  description = "Ready-made command line for the validation script."
  value = join(" ", [
    "pwsh ../validate.ps1",
    "-ResourceGroup ${azurerm_resource_group.lab.name}",
    "-VnetName ${azurerm_virtual_network.lab.name}",
    "-ClusterName ${azurerm_kubernetes_cluster.aks.name}",
    "-VmName ${azurerm_linux_virtual_machine.jump.name}",
  ])
}
