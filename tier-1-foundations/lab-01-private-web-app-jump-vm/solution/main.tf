###############################################################################
# Lab 01 - Fully Private Web App with a Locked-Down Jump VM
#
# Reference build. Read the numbered comments alongside the README build
# instructions - the section numbers match the steps.
###############################################################################

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix          = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result
  web_app_name    = "app-lab01-${local.suffix}"
  sql_server_name = "sql-lab01-${local.suffix}"
  database_name   = "appdb"

  # Subnet layout. Carved out of var.vnet_address_space (10.10.0.0/16).
  subnet_pe      = cidrsubnet(var.vnet_address_space, 8, 1) # 10.10.1.0/24
  subnet_jump    = cidrsubnet(var.vnet_address_space, 8, 2) # 10.10.2.0/24
  subnet_bastion = cidrsubnet(var.vnet_address_space, 10, 12) # 10.10.3.0/26
  subnet_appint  = cidrsubnet(var.vnet_address_space, 8, 4) # 10.10.4.0/24

  # Azure's platform DNS resolver and health probe address. Reachable from every
  # subnet regardless of route tables, but an NSG can still block it.
  azure_platform_dns = "168.63.129.16"

  # Defaults to whoever is running Terraform, so the SQL server always has a
  # usable Entra admin. Override in terraform.tfvars to hand it to someone else.
  entra_admin_object_id = var.entra_admin_object_id != "" ? var.entra_admin_object_id : data.azurerm_client_config.current.object_id
  entra_admin_login     = var.entra_admin_login != "" ? var.entra_admin_login : local.entra_admin_object_id
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
# Step 2 - Virtual network and four subnets
###############################################################################

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

resource "azurerm_subnet" "jump" {
  name                 = "snet-jump"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_jump]
}

# The name of this subnet is not a convention - Bastion looks for this literal
# string and will not deploy without it.
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_bastion]
}

# Delegation hands this subnet to App Service so it may inject the hidden network
# interface that regional VNet integration depends on. Nothing else can use it.
resource "azurerm_subnet" "appint" {
  name                 = "snet-appint"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_appint]

  delegation {
    name = "appservice-delegation"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

###############################################################################
# Step 3 - Private DNS zones, created and linked before any private endpoint
###############################################################################

resource "azurerm_private_dns_zone" "web" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

# The link is what makes the zone visible to clients in the network. Without it
# the zone exists and resolves nothing.
resource "azurerm_private_dns_zone_virtual_network_link" "web" {
  name                  = "link-${var.vnet_name}"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.web.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql" {
  name                  = "link-${var.vnet_name}"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = var.tags
}

###############################################################################
# Step 4 - Azure SQL, Entra-only, no public access
#
# Note there is no administrator_login or password here at all. Setting
# azuread_authentication_only means the provider will reject those arguments,
# which is exactly the guarantee the lab asks for.
###############################################################################

resource "azurerm_mssql_server" "sql" {
  name                          = local.sql_server_name
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = var.tags

  azuread_administrator {
    login_username              = local.entra_admin_login
    object_id                   = local.entra_admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }
}

resource "azurerm_mssql_database" "db" {
  name      = local.database_name
  server_id = azurerm_mssql_server.sql.id
  sku_name  = "Basic"
  tags      = var.tags
}

###############################################################################
# Step 5 - Private endpoint for SQL
###############################################################################

resource "azurerm_private_endpoint" "sql" {
  name                = "pe-sql"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "pe-sql-conn"
    private_connection_resource_id = azurerm_mssql_server.sql.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  # This block is what writes the A record. Omit it and the endpoint works at the
  # IP level while every client keeps resolving the public name.
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql.id]
  }
}

###############################################################################
# Step 6 - App Service plan and web app
# Step 7 - VNet integration with Route All
# Step 8 - Public network access disabled
# Step 9 - Managed identity and passwordless connection string
###############################################################################

resource "azurerm_service_plan" "plan" {
  name                = "plan-lab01"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  os_type             = "Linux"
  sku_name            = "P0v3"
  tags                = var.tags
}

resource "azurerm_linux_web_app" "app" {
  name                = local.web_app_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_service_plan.plan.location
  service_plan_id     = azurerm_service_plan.plan.id
  tags                = var.tags

  # Step 8 - close the public door.
  public_network_access_enabled = false

  # Step 7 - regional VNet integration into the delegated subnet.
  virtual_network_subnet_id = azurerm_subnet.appint.id

  # Step 9 - an identity Azure vouches for, so no secret has to exist.
  identity {
    type = "SystemAssigned"
  }

  site_config {
    # Without this only RFC 1918 destinations traverse the VNet; everything else
    # still leaves through App Service's own shared outbound path.
    vnet_route_all_enabled = true
    ftps_state             = "Disabled"
    minimum_tls_version    = "1.2"

    application_stack {
      dotnet_version = "8.0"
    }
  }

  # Step 9 - no username, no password, no secret of any kind. The driver fetches
  # a token from the managed identity endpoint at runtime.
  connection_string {
    name  = "AppDb"
    type  = "SQLAzure"
    value = "Server=tcp:${azurerm_mssql_server.sql.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.db.name};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;"
  }
}

resource "azurerm_private_endpoint" "web" {
  name                = "pe-web"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "pe-web-conn"
    private_connection_resource_id = azurerm_linux_web_app.app.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.web.id]
  }
}

###############################################################################
# Step 10 - Jump VM with no public IP, plus Bastion to reach it
###############################################################################

resource "random_password" "vm" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

resource "azurerm_network_interface" "jump" {
  name                = "nic-${var.jump_vm_name}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.jump.id
    private_ip_address_allocation = "Dynamic"
    # Deliberately no public_ip_address_id. Creating one and removing it later
    # still leaves the VM exposed for the window in between.
  }
}

resource "azurerm_linux_virtual_machine" "jump" {
  name                            = var.jump_vm_name
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.jump_vm_size
  admin_username                  = "azureuser"
  admin_password                  = random_password.vm.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.jump.id]
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

resource "azurerm_bastion_host" "bastion" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "bastion-lab01"
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

###############################################################################
# Step 11 - Remove the jump subnet's route to the internet
###############################################################################

resource "azurerm_route_table" "jump" {
  name                = "rt-jump"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  # Overrides the invisible default route every subnet gets. Next hop "None"
  # means discard. More specific system routes for the VNet itself survive, so
  # the private endpoints stay reachable.
  route {
    name           = "no-internet"
    address_prefix = "0.0.0.0/0"
    next_hop_type  = "None"
  }
}

resource "azurerm_subnet_route_table_association" "jump" {
  subnet_id      = azurerm_subnet.jump.id
  route_table_id = azurerm_route_table.jump.id
}

###############################################################################
# Step 12 - NSG allowing the jump VM to reach the app and nothing else
#
# Rules are evaluated lowest priority first and the first match wins. The deny
# at 4000 sits above Azure's built-in AllowInternetOutBound at 65001.
###############################################################################

resource "azurerm_network_security_group" "jump" {
  name                = "nsg-jump"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_network_security_rule" "allow_bastion_in" {
  name                        = "allow-bastion-in"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = local.subnet_bastion
  source_port_range           = "*"
  destination_address_prefix  = "*"
  destination_port_ranges     = ["22", "3389"]
}

resource "azurerm_network_security_rule" "allow_app_out" {
  name                        = "allow-app-out"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = azurerm_private_endpoint.web.private_service_connection[0].private_ip_address
  destination_port_range      = "443"
}

# Without this the VM cannot resolve any name, including the private endpoint's,
# and the private DNS zones look broken when they are fine.
resource "azurerm_network_security_rule" "allow_dns_out" {
  name                        = "allow-dns-out"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = local.azure_platform_dns
  destination_port_range      = "53"
}

resource "azurerm_network_security_rule" "deny_internet_out" {
  name                        = "deny-internet-out"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = "Internet"
  destination_port_range      = "*"
}

resource "azurerm_subnet_network_security_group_association" "jump" {
  subnet_id                 = azurerm_subnet.jump.id
  network_security_group_id = azurerm_network_security_group.jump.id
}
