###############################################################################
# Lab 06 - Key Vault with RBAC and Identity-Only Access
#
# Reference build. Section numbers match the steps in the README.
#
# Note there is no azurerm_key_vault_secret anywhere in this file. With public
# network access disabled, Terraform cannot reach the vault's data plane from
# outside the network, and the only way to make it work would be to weaken the
# thing this lab exists to demonstrate. Create the secret from vm-app instead.
###############################################################################

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix         = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result
  key_vault_name = "kv-lab06-${local.suffix}"

  subnet_pe      = cidrsubnet(var.vnet_address_space, 8, 1)  # 10.60.1.0/24
  subnet_app     = cidrsubnet(var.vnet_address_space, 8, 2)  # 10.60.2.0/24
  subnet_bastion = cidrsubnet(var.vnet_address_space, 10, 12) # 10.60.3.0/26
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

resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_pe]
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_app]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_bastion]
}

###############################################################################
# Step 2 - Private DNS zone
#
# vaultcore.azure.net, not vault.azure.net. Different words, and the wrong one
# gives you a perfectly healthy zone that resolves nothing.
###############################################################################

resource "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  name                  = "link-${var.vnet_name}"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.kv.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = var.tags
}

###############################################################################
# Step 3 - The vault
#
# enable_rbac_authorization = true is the whole point. Under the access policy
# model, grants live in a list on the vault itself: not role assignments, so not
# visible to access reviews, PIM, or anything that audits "who can read this".
#
# There is deliberately no access_policy block below.
###############################################################################

resource "azurerm_key_vault" "this" {
  name                = local.key_vault_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  tags                = var.tags

  enable_rbac_authorization = true

  public_network_access_enabled = false
  soft_delete_retention_days    = 7

  # Off so you can delete and rebuild the lab with the same name. Turn it on for
  # anything real - it is what stops an attacker with Contributor from purging
  # your vault and its history.
  purge_protection_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

###############################################################################
# Step 4 - Private endpoint
###############################################################################

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-kv"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "pe-kv-conn"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
}

###############################################################################
# Step 5 - Application VM with a managed identity
###############################################################################

resource "random_password" "vm" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

resource "azurerm_network_interface" "app" {
  name                = "nic-vm-app"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                            = "vm-app"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.vm_size
  admin_username                  = "azureuser"
  admin_password                  = random_password.vm.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.app.id]
  tags                            = var.tags

  identity {
    type = "SystemAssigned"
  }

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
}

###############################################################################
# Step 6 - Exactly one grant, to exactly one identity
#
# "Key Vault Secrets User" reads secret values and nothing else. Nothing is
# assigned to a human: the requirement is that no person can read secrets without
# an explicit, auditable grant, and a standing one for yourself is exactly the
# thing being tested.
###############################################################################

resource "azurerm_role_assignment" "app_secrets_user" {
  count                = var.grant_app_identity ? 1 : 0
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

###############################################################################
# Bastion, so the VM can stay private
###############################################################################

resource "azurerm_public_ip" "bastion" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "pip-bastion"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "lab" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "bastion-lab06"
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
