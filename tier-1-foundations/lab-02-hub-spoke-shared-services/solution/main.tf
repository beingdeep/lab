###############################################################################
# Lab 02 - Hub and Spoke with a Shared Services Spoke
#
# Reference build. Section numbers match the steps in the README.
###############################################################################

locals {
  # Hub subnets. Both names are fixed by Azure, not by convention.
  subnet_firewall = cidrsubnet(var.hub_address_space, 10, 4) # 10.0.1.0/26
  subnet_bastion  = cidrsubnet(var.hub_address_space, 10, 8) # 10.0.2.0/26

  subnet_app    = cidrsubnet(var.app_spoke_address_space, 8, 1)    # 10.1.1.0/24
  subnet_shared = cidrsubnet(var.shared_spoke_address_space, 8, 1) # 10.2.1.0/24

  # Azure Firewall always takes the fourth usable address in its subnet, but read
  # it back from the resource rather than assuming. one() yields null when the
  # firewall is not deployed, without erroring on an empty index.
  firewall_private_ip = one([for f in azurerm_firewall.hub : f.ip_configuration[0].private_ip_address])
}

###############################################################################
# Step 1 - Resource group
###############################################################################

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

###############################################################################
# Step 2 - Hub virtual network
###############################################################################

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

###############################################################################
# Step 3 - The two spokes
###############################################################################

resource "azurerm_virtual_network" "app" {
  name                = var.app_spoke_vnet_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.app_spoke_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = [local.subnet_app]
}

resource "azurerm_virtual_network" "shared" {
  name                = var.shared_spoke_vnet_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.shared_spoke_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "shared" {
  name                 = "snet-shared"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.shared.name
  address_prefixes     = [local.subnet_shared]
}

###############################################################################
# Step 4 - Four peerings, and deliberately no fifth
#
# allow_forwarded_traffic is the setting that lets a spoke accept a packet the
# hub is relaying on the other spoke's behalf. Without it the destination spoke
# drops the packet because its source address is not the hub's own range.
###############################################################################

resource "azurerm_virtual_network_peering" "hub_to_app" {
  name                         = "hub-to-app"
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.app.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "app_to_hub" {
  name                         = "app-to-hub"
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.app.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "hub_to_shared" {
  name                         = "hub-to-shared"
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.shared.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "shared_to_hub" {
  name                         = "shared-to-hub"
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.shared.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# There is no peering between vnet-spoke-app and vnet-spoke-shared. That absence
# is the requirement, not an omission.

###############################################################################
# Step 6 - Azure Firewall in the hub
###############################################################################

resource "azurerm_public_ip" "firewall" {
  count               = var.deploy_firewall ? 1 : 0
  name                = "pip-afw"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "hub" {
  count               = var.deploy_firewall ? 1 : 0
  name                = "afw-hub"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  tags                = var.tags

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }
}

###############################################################################
# Step 7 - Route tables forcing spoke-to-spoke traffic through the firewall
#
# Both spokes get one. The shared spoke never starts a conversation, but its
# replies have to return by the same path or the firewall sees half a flow and
# drops it - asymmetric routing.
#
# Note there is deliberately no route table on AzureFirewallSubnet.
###############################################################################

resource "azurerm_route_table" "app" {
  count               = var.deploy_firewall ? 1 : 0
  name                = "rt-app"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  route {
    name                   = "to-shared"
    address_prefix         = var.shared_spoke_address_space
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "app" {
  count          = var.deploy_firewall ? 1 : 0
  subnet_id      = azurerm_subnet.app.id
  route_table_id = azurerm_route_table.app[0].id
}

resource "azurerm_route_table" "shared" {
  count               = var.deploy_firewall ? 1 : 0
  name                = "rt-shared"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  route {
    name                   = "to-app"
    address_prefix         = var.app_spoke_address_space
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "shared" {
  count          = var.deploy_firewall ? 1 : 0
  subnet_id      = azurerm_subnet.shared.id
  route_table_id = azurerm_route_table.shared[0].id
}

###############################################################################
# Step 8 - Rules, in one direction only
###############################################################################

resource "azurerm_firewall_network_rule_collection" "app_to_shared" {
  count               = var.deploy_firewall ? 1 : 0
  name                = "spoke-to-shared"
  azure_firewall_name = azurerm_firewall.hub[0].name
  resource_group_name = azurerm_resource_group.lab.name
  priority            = 200
  action              = "Allow"

  rule {
    name                  = "app-to-shared"
    source_addresses      = [var.app_spoke_address_space]
    destination_addresses = [var.shared_spoke_address_space]
    destination_ports     = var.allowed_ports
    protocols             = ["TCP"]
  }
}

# Optional. Azure Firewall already denies whatever you have not allowed, so this
# changes nothing functionally - it just turns a generic default-deny log entry
# into a named one, which is far easier to explain during an incident.
resource "azurerm_firewall_network_rule_collection" "shared_to_app_deny" {
  count               = var.deploy_firewall && var.deploy_explicit_deny ? 1 : 0
  name                = "shared-to-spoke-deny"
  azure_firewall_name = azurerm_firewall.hub[0].name
  resource_group_name = azurerm_resource_group.lab.name
  priority            = 300
  action              = "Deny"

  rule {
    name                  = "shared-to-app"
    source_addresses      = [var.shared_spoke_address_space]
    destination_addresses = [var.app_spoke_address_space]
    destination_ports     = ["*"]
    protocols             = ["Any"]
  }
}

###############################################################################
# Step 5 / 9 - Test VMs and Bastion
###############################################################################

resource "random_password" "vm" {
  count            = var.deploy_test_vms ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

resource "azurerm_network_interface" "app" {
  count               = var.deploy_test_vms ? 1 : 0
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
  count                           = var.deploy_test_vms ? 1 : 0
  name                            = "vm-app"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.vm_size
  admin_username                  = "azureuser"
  admin_password                  = random_password.vm[0].result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.app[0].id]
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

resource "azurerm_network_interface" "shared" {
  count               = var.deploy_test_vms ? 1 : 0
  name                = "nic-vm-shared"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.shared.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "shared" {
  count                           = var.deploy_test_vms ? 1 : 0
  name                            = "vm-shared"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.vm_size
  admin_username                  = "azureuser"
  admin_password                  = random_password.vm[0].result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.shared[0].id]
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

resource "azurerm_public_ip" "bastion" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "pip-bastion"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Bastion sits in the hub and reaches both spokes over the peerings, so you do
# not need one per network.
resource "azurerm_bastion_host" "hub" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "bastion-lab02"
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
