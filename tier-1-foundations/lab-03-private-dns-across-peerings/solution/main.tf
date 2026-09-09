###############################################################################
# Lab 03 - Private DNS Resolution Across Peered Networks
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
  suffix = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result

  storage_account_name = "stglab03${local.suffix}"
  key_vault_name       = "kv-lab03-${local.suffix}"
  sql_server_name      = "sql-lab03-${local.suffix}"

  vnet_names = sort(keys(var.vnets))

  # One private endpoint per network, deliberately spread out so no network can
  # resolve everything by accident.
  vnet_for_storage = local.vnet_names[0]
  vnet_for_vault   = local.vnet_names[1]
  vnet_for_sql     = local.vnet_names[2]

  # Two subnets carved out of each address space.
  workload_subnets = {
    for name, cfg in var.vnets : name => cidrsubnet(cfg.address_space, 8, 1)
  }
  pe_subnets = {
    for name, cfg in var.vnets : name => cidrsubnet(cfg.address_space, 8, 2)
  }

  # Every ordered pair of distinct networks. Peering is one-directional, so a
  # full mesh across three networks is six objects, not three.
  peer_pairs = {
    for pair in setproduct(local.vnet_names, local.vnet_names) :
    "${pair[0]}-to-${pair[1]}" => { from = pair[0], to = pair[1] }
    if pair[0] != pair[1]
  }

  # The zone name for each service is fixed by Azure. Note that Key Vault's
  # public name is vault.azure.net but its private zone is vaultcore.azure.net.
  zones = {
    blob  = "privatelink.blob.core.windows.net"
    vault = "privatelink.vaultcore.azure.net"
    sql   = "privatelink.database.windows.net"
  }

  # Three zones seen by three networks is nine links. Peering does not shortcut
  # this - a network with no link to a zone gets public answers.
  zone_links = {
    for pair in setproduct(keys(local.zones), local.vnet_names) :
    "${pair[0]}|${pair[1]}" => { zone = pair[0], vnet = pair[1] }
    # Step 10: optionally drop vnet-c's link to the blob zone to reproduce the
    # silent failure.
    if !(var.break_vnet_c_blob_link && pair[0] == "blob" && pair[1] == local.vnet_names[2])
  }
}

###############################################################################
# Step 1 - Two resource groups
###############################################################################

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "dns" {
  name     = var.dns_resource_group_name
  location = var.location
  tags     = var.tags
}

###############################################################################
# Step 2 - Three virtual networks
#
# No dns_servers argument anywhere. Private DNS zones only work through Azure's
# built-in resolver at 168.63.129.16; setting a custom DNS server here would
# stop every private zone applying to these machines.
###############################################################################

resource "azurerm_virtual_network" "this" {
  for_each = var.vnets

  name                = each.key
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [each.value.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "workload" {
  for_each = var.vnets

  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.this[each.key].name
  address_prefixes     = [local.workload_subnets[each.key]]
}

resource "azurerm_subnet" "pe" {
  for_each = var.vnets

  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.this[each.key].name
  address_prefixes     = [local.pe_subnets[each.key]]
}

###############################################################################
# Step 3 - Full mesh peering
#
# Routing is deliberately made a non-issue so that DNS is the only variable left
# when something does not resolve.
###############################################################################

resource "azurerm_virtual_network_peering" "mesh" {
  for_each = local.peer_pairs

  name                         = each.key
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.this[each.value.from].name
  remote_virtual_network_id    = azurerm_virtual_network.this[each.value.to].id
  allow_virtual_network_access = true
}

###############################################################################
# Step 4 - One set of private DNS zones
###############################################################################

resource "azurerm_private_dns_zone" "this" {
  for_each = local.zones

  name                = each.value
  resource_group_name = azurerm_resource_group.dns.name
  tags                = var.tags
}

###############################################################################
# Step 5 - Nine virtual network links
#
# registration_enabled stays false everywhere. Registration auto-creates records
# for VMs, which is not what these zones are for, and a zone accepts only one
# registration link - turning it on makes the second and third links fail.
###############################################################################

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.zone_links

  name                  = "link-${each.value.vnet}"
  resource_group_name   = azurerm_resource_group.dns.name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone].name
  virtual_network_id    = azurerm_virtual_network.this[each.value.vnet].id
  registration_enabled  = false
  tags                  = var.tags
}

###############################################################################
# Step 6 - Three services, all with public access off
#
# Closing public access is what makes the Step 10 failure visible. Left open, a
# machine that resolves the public address still connects and you learn nothing.
###############################################################################

resource "azurerm_storage_account" "this" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  tags                            = var.tags
}

resource "azurerm_key_vault" "this" {
  name                          = local.key_vault_name
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  public_network_access_enabled = false
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  tags                          = var.tags
}

resource "azurerm_mssql_server" "this" {
  name                          = local.sql_server_name
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = var.tags

  # Entra-only, so no administrator password exists anywhere in this build.
  azuread_administrator {
    login_username              = data.azurerm_client_config.current.object_id
    object_id                   = data.azurerm_client_config.current.object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }
}

###############################################################################
# Step 7 - One private endpoint per network, each with a DNS zone group
#
# The private_dns_zone_group block is the only thing that writes the A record.
# Without it you get a working private IP that nothing resolves to.
###############################################################################

resource "azurerm_private_endpoint" "storage" {
  name                = "pe-storage"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = azurerm_subnet.pe[local.vnet_for_storage].id
  tags                = var.tags

  private_service_connection {
    name                           = "pe-storage-conn"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["blob"].id]
  }
}

resource "azurerm_private_endpoint" "vault" {
  name                = "pe-kv"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = azurerm_subnet.pe[local.vnet_for_vault].id
  tags                = var.tags

  private_service_connection {
    name                           = "pe-kv-conn"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["vault"].id]
  }
}

resource "azurerm_private_endpoint" "sql" {
  name                = "pe-sql"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = azurerm_subnet.pe[local.vnet_for_sql].id
  tags                = var.tags

  private_service_connection {
    name                           = "pe-sql-conn"
    private_connection_resource_id = azurerm_mssql_server.this.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["sql"].id]
  }
}

###############################################################################
# Step 8 - One VM per network to run the nine lookups from
###############################################################################

resource "random_password" "vm" {
  count            = var.deploy_test_vms ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

resource "azurerm_network_interface" "vm" {
  for_each = var.deploy_test_vms ? var.vnets : {}

  name                = "nic-vm-${replace(each.key, "vnet-", "")}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.workload[each.key].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = var.deploy_test_vms ? var.vnets : {}

  name                            = "vm-${replace(each.key, "vnet-", "")}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.vm_size
  admin_username                  = "azureuser"
  admin_password                  = random_password.vm[0].result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.vm[each.key].id]
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
}
