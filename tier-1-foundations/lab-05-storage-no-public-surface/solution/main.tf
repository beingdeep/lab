###############################################################################
# Lab 05 - Storage Account with No Public Surface
#
# Reference build. Section numbers match the steps in the README.
###############################################################################

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix               = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result
  storage_account_name = "stglab05${local.suffix}"

  subnet_pe      = cidrsubnet(var.vnet_address_space, 8, 1)  # 10.50.1.0/24
  subnet_app     = cidrsubnet(var.vnet_address_space, 8, 2)  # 10.50.2.0/24
  subnet_bastion = cidrsubnet(var.vnet_address_space, 10, 12) # 10.50.3.0/26
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
# Step 2 - Private DNS zone, created before the endpoint that registers into it
###############################################################################

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "link-${var.vnet_name}"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = var.tags
}

###############################################################################
# Step 3 - The storage account
#
# shared_access_key_enabled = false is the setting that matters most here. While
# keys exist, every data-plane role assignment below is advisory: anyone able to
# read the keys is the storage account, with no identity in the audit log.
###############################################################################

resource "azurerm_storage_account" "this" {
  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  public_network_access_enabled   = false
  shared_access_key_enabled       = var.allow_shared_key_access
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
  min_tls_version                 = "TLS1_2"

  # A separate setting from public_network_access_enabled, and both show up in
  # audits. This one is what still means something if someone re-enables public
  # access later.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

# Uses the Resource Manager API rather than the storage data plane, so it works
# even though the account has no public endpoint. If your provider version still
# routes this through the data plane, create the container from inside the VNet
# instead and set create_container = false.
resource "azurerm_storage_container" "app_data" {
  name               = var.container_name
  storage_account_id = azurerm_storage_account.this.id
}

###############################################################################
# Step 4 - Private endpoint for the blob sub-resource only
#
# blob, file, table, queue and dfs are separate sub-resources. This endpoint
# gives you blob. Anything else needs its own endpoint and its own zone.
###############################################################################

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-blob"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "pe-blob-conn"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
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
# Step 6 - Data-plane role assignments
#
# "Storage Blob Data Contributor", not "Contributor". Contributor is a control
# plane role: it can change the account and read its keys, but grants no blob
# access at all once keys are disabled.
###############################################################################

resource "azurerm_role_assignment" "app_identity" {
  scope                = var.scope_role_to_container ? azurerm_storage_container.app_data.id : azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

# So the portal data browser works for you, from a network that can reach the
# account. With keys off, RBAC applies to humans exactly as it does to the app.
resource "azurerm_role_assignment" "current_user" {
  count                = var.grant_current_user_data_reader ? 1 : 0
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = data.azurerm_client_config.current.object_id
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
  name                = "bastion-lab05"
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
