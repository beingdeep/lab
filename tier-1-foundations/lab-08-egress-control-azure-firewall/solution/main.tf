###############################################################################
# Lab 08 - Egress Control with Azure Firewall
#
# Reference build. Section numbers match the steps in the README.
###############################################################################

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  subnet_firewall = cidrsubnet(var.hub_address_space, 10, 4) # 10.80.1.0/26
  subnet_bastion  = cidrsubnet(var.hub_address_space, 10, 8) # 10.80.2.0/26
  subnet_workload = cidrsubnet(var.spoke_address_space, 8, 1) # 10.81.1.0/24

  firewall_private_ip = azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

###############################################################################
# Step 1 - Resource group, hub and spoke
###############################################################################

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = var.hub_vnet_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.hub_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.subnet_firewall]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.subnet_bastion]
}

resource "azurerm_virtual_network" "spoke" {
  name                = var.spoke_vnet_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.spoke_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "workload" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.subnet_workload]
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "hub-to-spoke"
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "spoke-to-hub"
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

###############################################################################
# Step 2 - Somewhere for the logs to go
#
# Created before the firewall, because logs that were not configured before an
# event do not exist after it. There is no way to enable logging for last week.
###############################################################################

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-lab08-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

###############################################################################
# Step 3 - The policy
#
# Azure Firewall evaluates network rules BEFORE application rules. A network rule
# that already allows a flow means the application rule collection is never
# consulted for it, and the hostname allow-list silently stops applying.
###############################################################################

resource "azurerm_firewall_policy" "policy" {
  name                = "fwp-lab08"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "rcg-egress"
  firewall_policy_id = azurerm_firewall_policy.policy.id
  priority           = 200

  # Matched at layer 7. The firewall reads the requested hostname from the TLS
  # handshake, so these log entries name the host that was asked for.
  application_rule_collection {
    name     = "allow-fqdns"
    priority = 200
    action   = "Allow"

    rule {
      name             = "allowed-hostnames"
      source_addresses = [var.spoke_address_space]
      destination_fqdns = var.allowed_fqdns

      protocols {
        type = "Https"
        port = 443
      }

      protocols {
        type = "Http"
        port = 80
      }
    }
  }

  # Matched at layer 3/4. Same sort of request, but these log entries contain an
  # address and a port and no hostname at all - because at this layer the
  # firewall never saw one. That contrast is the last part of the problem.
  network_rule_collection {
    name     = "allow-one-address"
    priority = 300
    action   = "Allow"

    rule {
      name                  = "single-destination"
      protocols             = ["TCP"]
      source_addresses      = [var.spoke_address_space]
      destination_addresses = [var.network_rule_destination]
      destination_ports     = ["443"]
    }
  }

  # Deliberately broken, off by default. Turning this on disables the entire FQDN
  # allow-list above, silently, because network rules win.
  dynamic "network_rule_collection" {
    for_each = var.add_broad_network_rule ? [1] : []

    content {
      name     = "allow-all-443-DANGEROUS"
      priority = 100
      action   = "Allow"

      rule {
        name                  = "any-https"
        protocols             = ["TCP"]
        source_addresses      = [var.spoke_address_space]
        destination_addresses = ["*"]
        destination_ports     = ["443"]
      }
    }
  }
}

###############################################################################
# Step 4 - The firewall
###############################################################################

resource "azurerm_public_ip" "firewall" {
  name                = "pip-afw"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "hub" {
  name                = "afw-hub"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.policy.id
  tags                = var.tags

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }
}

###############################################################################
# Step 5 - Force everything through it
#
# 0.0.0.0/0, not a list of destinations. The point is that anything you did not
# think of also goes to the firewall instead of taking the default route out.
#
# Note there is no route table on AzureFirewallSubnet.
###############################################################################

resource "azurerm_route_table" "spoke" {
  name                = "rt-spoke"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "spoke" {
  subnet_id      = azurerm_subnet.workload.id
  route_table_id = azurerm_route_table.spoke.id
}

###############################################################################
# Step 6 - Diagnostics
#
# Resource-specific tables, not the legacy AzureDiagnostics one. AzureDiagnostics
# is a single shared table with a hard column limit that every service competes
# for; AZFWApplicationRule and AZFWNetworkRule have real schemas and are far
# cheaper to query.
###############################################################################

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                           = "diag-to-law"
  target_resource_id             = azurerm_firewall.hub.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.law.id
  log_analytics_destination_type = "Dedicated"

  enabled_log { category = "AZFWApplicationRule" }
  enabled_log { category = "AZFWNetworkRule" }
  enabled_log { category = "AZFWNatRule" }
  enabled_log { category = "AZFWThreatIntel" }
  enabled_log { category = "AZFWDnsQuery" }

  metric {
    category = "AllMetrics"
    enabled  = false
  }
}

###############################################################################
# Step 7 - A workload to test from, and Bastion to reach it
###############################################################################

resource "random_password" "vm" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

resource "azurerm_network_interface" "spoke" {
  name                = "nic-vm-spoke"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.workload.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "spoke" {
  name                            = "vm-spoke"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.vm_size
  admin_username                  = "azureuser"
  admin_password                  = random_password.vm.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.spoke.id]
  tags                            = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # The route table has to exist first, or the VM's own provisioning traffic goes
  # out by the default route and you have not really tested anything.
  depends_on = [azurerm_subnet_route_table_association.spoke]
}

resource "azurerm_public_ip" "bastion" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "pip-bastion"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "hub" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "bastion-lab08"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "Basic"
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}
