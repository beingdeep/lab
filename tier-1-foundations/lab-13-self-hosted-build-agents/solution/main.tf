###############################################################################
# Lab 13 - Self-Hosted Build Agents Inside a Private Network
#
# Reference build. Section numbers match the steps in the README.
#
# The agents are not registered with a build service here - that needs an
# organisation and a pool. Step 8 in the README stays manual, and deliberately
# so: the interesting part is what you do INSTEAD of pasting a personal access
# token onto every machine.
###############################################################################

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix        = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result
  registry_name = "acrlab13${local.suffix}"

  subnet_agents = cidrsubnet(var.vnet_address_space, 8, 1) # 10.130.1.0/24
  subnet_pe     = cidrsubnet(var.vnet_address_space, 8, 2) # 10.130.2.0/24

  ssh_key = var.admin_ssh_public_key != "" ? var.admin_ssh_public_key : try(file(pathexpand("~/.ssh/id_rsa.pub")), null)
}

###############################################################################
# Step 1 - Resource group and virtual network
###############################################################################

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "lab" {
  name                = var.vnet_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "agents" {
  name                 = "snet-agents"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_agents]
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_pe]
}

###############################################################################
# Step 2 - NAT gateway
#
# Without one, every instance does its own outbound translation from a small
# fixed port allocation. A fleet all pulling packages at once exhausts it, and
# you get intermittent failures that look exactly like network flakiness.
###############################################################################

resource "azurerm_public_ip" "nat" {
  name                = "pip-nat"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "lab" {
  name                    = "nat-lab13"
  resource_group_name     = azurerm_resource_group.lab.name
  location                = azurerm_resource_group.lab.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "lab" {
  nat_gateway_id       = azurerm_nat_gateway.lab.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "agents" {
  subnet_id      = azurerm_subnet.agents.id
  nat_gateway_id = azurerm_nat_gateway.lab.id
}

###############################################################################
# Step 3 - A private container registry
#
# Premium, because private endpoints are a Premium feature on ACR - Basic and
# Standard cannot have one at all.
###############################################################################

resource "azurerm_container_registry" "acr" {
  name                          = local.registry_name
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  tags                          = var.tags
}

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "link-${var.vnet_name}"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "pe-acr-conn"
    private_connection_resource_id = azurerm_container_registry.acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
}

###############################################################################
# Step 4 - The NSG
#
# There are no inbound Allow rules at all. The agent opens a connection out to
# the build service and holds it open waiting for work; nothing ever connects to
# it. If you find yourself opening an inbound port here, the model is being
# misunderstood.
###############################################################################

resource "azurerm_network_security_group" "agents" {
  name                = "nsg-agents"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_network_security_rule" "egress_allowed" {
  for_each = var.allow_all_egress ? {} : { for i, tag in var.allowed_service_tags : tag => 100 + (i * 10) }

  name                        = "allow-${lower(each.key)}-out"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.agents.name
  priority                    = each.value
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = each.key
  destination_port_range      = "443"
}

resource "azurerm_network_security_rule" "egress_vnet" {
  count                       = var.allow_all_egress ? 0 : 1
  name                        = "allow-vnet-out"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.agents.name
  priority                    = 300
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = "VirtualNetwork"
  destination_port_range      = "*"
}

resource "azurerm_network_security_rule" "egress_deny" {
  count                       = var.allow_all_egress ? 0 : 1
  name                        = "deny-internet-out"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.agents.name
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = "Internet"
  destination_port_range      = "*"
}

resource "azurerm_subnet_network_security_group_association" "agents" {
  subnet_id                 = azurerm_subnet.agents.id
  network_security_group_id = azurerm_network_security_group.agents.id
}

###############################################################################
# Step 5 - The scale set
#
# No public IP block in the ip_configuration, and no password. A build agent runs
# code from every pull request, so any credential on the machine is readable by
# anyone who can open one. The managed identity is not stored on disk - the
# platform issues it, scoped and short-lived.
###############################################################################

resource "azurerm_linux_virtual_machine_scale_set" "agents" {
  name                = var.scale_set_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = var.instance_size
  instances           = var.min_instances
  admin_username      = "azureuser"
  upgrade_mode        = "Manual"
  tags                = var.tags

  disable_password_authentication = true

  admin_ssh_key {
    username   = "azureuser"
    public_key = local.ssh_key
  }

  identity {
    type = "SystemAssigned"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name    = "nic-agents"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.agents.id
      # Deliberately no public_ip_address block.
    }

    network_security_group_id = azurerm_network_security_group.agents.id
  }

  lifecycle {
    # Autoscale owns the instance count once it exists; without this every apply
    # would fight the autoscale setting back down to min_instances.
    ignore_changes = [instances]
  }
}

###############################################################################
# Step 6 - One role, on the registry
#
# Agents pull images. They do not push, delete tags, or change the registry. If a
# build also publishes images, that is a different identity in a different stage.
###############################################################################

resource "azurerm_role_assignment" "agents_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_virtual_machine_scale_set.agents.identity[0].principal_id
}

###############################################################################
# Step 7 - Autoscale
###############################################################################

resource "azurerm_monitor_autoscale_setting" "agents" {
  name                = "autoscale-agents"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.agents.id
  tags                = var.tags

  profile {
    name = "default"

    capacity {
      default = var.min_instances
      minimum = var.min_instances
      maximum = var.max_instances
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.agents.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.agents.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }
  }
}
