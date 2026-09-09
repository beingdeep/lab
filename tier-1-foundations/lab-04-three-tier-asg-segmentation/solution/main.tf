###############################################################################
# Lab 04 - Three-Tier Segmentation with Application Security Groups
#
# Reference build. Section numbers match the steps in the README.
###############################################################################

locals {
  subnet_web     = cidrsubnet(var.vnet_address_space, 8, 1)  # 10.40.1.0/24
  subnet_app     = cidrsubnet(var.vnet_address_space, 8, 2)  # 10.40.2.0/24
  subnet_db      = cidrsubnet(var.vnet_address_space, 8, 3)  # 10.40.3.0/24
  subnet_bastion = cidrsubnet(var.vnet_address_space, 10, 16) # 10.40.4.0/26
}

###############################################################################
# Step 1 - Resource group, virtual network, four subnets
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

resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_web]
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_app]
}

resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_db]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_bastion]
}

###############################################################################
# Step 2 - Application security groups
#
# An ASG has no settings. It exists so rules can name a tier instead of an
# address range, and so membership can follow the network cards.
###############################################################################

resource "azurerm_application_security_group" "web" {
  name                = "asg-web"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_application_security_group" "app" {
  name                = "asg-app"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_application_security_group" "db" {
  name                = "asg-db"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

###############################################################################
# Step 3 - One NSG for all three tier subnets
#
# Because every rule is written in terms of ASGs, the same rule set is correct on
# all three subnets. One place to read, one place to audit, no drift.
#
# Deliberately NOT attached to AzureBastionSubnet - Bastion manages its own.
###############################################################################

resource "azurerm_network_security_group" "tiers" {
  name                = "nsg-tiers"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.tiers.id
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.tiers.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.tiers.id
}

###############################################################################
# Step 4 - Allow rules
#
# Inbound only. NSGs are stateful, so the reply to a permitted connection is
# allowed automatically and a matching outbound rule would be redundant.
###############################################################################

resource "azurerm_network_security_rule" "web_to_app" {
  name                                       = "allow-web-to-app"
  resource_group_name                        = azurerm_resource_group.lab.name
  network_security_group_name                = azurerm_network_security_group.tiers.name
  priority                                   = 100
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "443"
  source_application_security_group_ids      = [azurerm_application_security_group.web.id]
  destination_application_security_group_ids = [azurerm_application_security_group.app.id]
}

resource "azurerm_network_security_rule" "app_to_db" {
  name                                       = "allow-app-to-db"
  resource_group_name                        = azurerm_resource_group.lab.name
  network_security_group_name                = azurerm_network_security_group.tiers.name
  priority                                   = 110
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "1433"
  source_application_security_group_ids      = [azurerm_application_security_group.app.id]
  destination_application_security_group_ids = [azurerm_application_security_group.db.id]
}

# Bastion's network cards are not yours and cannot join an ASG, so its subnet
# range is the only handle available.
resource "azurerm_network_security_rule" "bastion_in" {
  name                        = "allow-bastion-in"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.tiers.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = local.subnet_bastion
  source_port_range           = "*"
  destination_address_prefix  = "*"
  destination_port_ranges     = ["22", "3389"]
}

###############################################################################
# Step 5 - The deny rules that actually create the isolation
#
# Without these, the built-in AllowVnetInBound rule at priority 65000 lets every
# machine in the VNet reach every other one - including web straight to database.
# Priority 4000 beats 65000. Priority 65100 would never be evaluated.
#
# Note these deny by DESTINATION, not by source. Blocking only the path you
# thought of means the next tier someone adds walks straight through.
###############################################################################

resource "azurerm_network_security_rule" "deny_to_db" {
  count                                      = var.deploy_deny_rules ? 1 : 0
  name                                       = "deny-all-to-db"
  resource_group_name                        = azurerm_resource_group.lab.name
  network_security_group_name                = azurerm_network_security_group.tiers.name
  priority                                   = 4000
  direction                                  = "Inbound"
  access                                     = "Deny"
  protocol                                   = "*"
  source_address_prefix                      = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  destination_application_security_group_ids = [azurerm_application_security_group.db.id]
}

resource "azurerm_network_security_rule" "deny_to_app" {
  count                                      = var.deploy_deny_rules ? 1 : 0
  name                                       = "deny-all-to-app"
  resource_group_name                        = azurerm_resource_group.lab.name
  network_security_group_name                = azurerm_network_security_group.tiers.name
  priority                                   = 4010
  direction                                  = "Inbound"
  access                                     = "Deny"
  protocol                                   = "*"
  source_address_prefix                      = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  destination_application_security_group_ids = [azurerm_application_security_group.app.id]
}

resource "azurerm_network_security_rule" "deny_internet_in" {
  count                       = var.deploy_deny_rules ? 1 : 0
  name                        = "deny-internet-in"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.tiers.name
  priority                    = 4020
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_address_prefix       = "Internet"
  source_port_range           = "*"
  destination_address_prefix  = "*"
  destination_port_range      = "*"
}

###############################################################################
# Step 6 - VMs, and their NICs joined to the right ASG
###############################################################################

resource "random_password" "vm" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

locals {
  # tier => { subnet_id, asg_id, count }
  tiers = {
    web = { subnet_id = azurerm_subnet.web.id, asg_id = azurerm_application_security_group.web.id, count = var.web_instance_count }
    app = { subnet_id = azurerm_subnet.app.id, asg_id = azurerm_application_security_group.app.id, count = 1 }
    db  = { subnet_id = azurerm_subnet.db.id, asg_id = azurerm_application_security_group.db.id, count = 1 }
  }

  # Flatten into one instance per VM, keyed "vm-web-1", "vm-app-1", ...
  instances = merge([
    for tier, cfg in local.tiers : {
      for i in range(cfg.count) :
      "vm-${tier}-${i + 1}" => { tier = tier, subnet_id = cfg.subnet_id, asg_id = cfg.asg_id }
    }
  ]...)
}

resource "azurerm_network_interface" "vm" {
  for_each = local.instances

  name                = "nic-${each.key}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = merge(var.tags, { tier = each.value.tier })

  ip_configuration {
    name                          = "internal"
    subnet_id                     = each.value.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# This association is the entire mechanism. A machine is "in the web tier"
# because its NIC is in asg-web - nothing about the rules mentions addresses,
# so adding a fifth web server changes no rule at all.
resource "azurerm_network_interface_application_security_group_association" "vm" {
  for_each = local.instances

  network_interface_id          = azurerm_network_interface.vm[each.key].id
  application_security_group_id = each.value.asg_id
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = local.instances

  name                            = each.key
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.vm_size
  admin_username                  = "azureuser"
  admin_password                  = random_password.vm.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.vm[each.key].id]
  tags                            = merge(var.tags, { tier = each.value.tier })

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

resource "azurerm_bastion_host" "lab" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "bastion-lab04"
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
