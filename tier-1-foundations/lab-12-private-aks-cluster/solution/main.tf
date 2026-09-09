###############################################################################
# Lab 12 - Private AKS Cluster
#
# Reference build. Section numbers match the steps in the README.
###############################################################################

data "azurerm_client_config" "current" {}

locals {
  subnet_aks     = cidrsubnet(var.vnet_address_space, 4, 0)   # 10.120.0.0/20
  subnet_jump    = cidrsubnet(var.vnet_address_space, 8, 16)  # 10.120.16.0/24
  subnet_bastion = cidrsubnet(var.vnet_address_space, 10, 68) # 10.120.17.0/26

  # Deliberately wrong when overlapping_pod_cidr is set, so you can see the error.
  effective_pod_cidr = var.overlapping_pod_cidr ? var.vnet_address_space : var.pod_cidr
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

# A /20 is far more than overlay needs - one VNet address per node - but you
# cannot resize a subnet that has resources in it, and internal load balancers,
# future node pools and Azure's reserved addresses all live here too. Subnets are
# free; rebuilding a cluster is not.
resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_aks]
}

resource "azurerm_subnet" "jump" {
  name                 = "snet-jump"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_jump]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_bastion]
}

###############################################################################
# Step 2 - The cluster
###############################################################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # The API server moves to a private endpoint in your VNet, and its name is
  # published in a private DNS zone. Anything that used to reach the cluster from
  # outside - your laptop, a hosted CI runner, a monitoring SaaS - now cannot.
  private_cluster_enabled             = true
  private_dns_zone_id                 = "System"
  private_cluster_public_fqdn_enabled = false

  # AKS ships a certificate-based cluster-admin credential that bypasses Entra
  # entirely, cannot be revoked individually, and leaves no sign-in log. Turning
  # local accounts off is what makes the role assignments below meaningful.
  local_account_disabled = true
  role_based_access_control_enabled = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  default_node_pool {
    name           = "system"
    node_count     = var.node_count
    vm_size        = var.node_size
    vnet_subnet_id = azurerm_subnet.aks.id

    # Nodes get no public address of their own.
    node_public_ip_enabled = false

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"

    # Overlay: pods get addresses from pod_cidr rather than from the VNet subnet.
    # A node with 30 pods consumes 1 VNet address instead of 31.
    network_plugin_mode = "overlay"

    pod_cidr       = local.effective_pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    # The cluster still egresses through a load balancer with a public IP. Nodes
    # have no public IP, which is what the requirement asks for - but "no public
    # IP anywhere" is a different requirement, and it is Lab 37.
    outbound_type     = "loadBalancer"
    load_balancer_sku = "standard"
  }
}

###############################################################################
# Step 3 - Jump host
###############################################################################

resource "random_password" "vm" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

resource "azurerm_network_interface" "jump" {
  name                = "nic-vm-jump"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.jump.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jump" {
  name                            = "vm-jump"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.jump_vm_size
  admin_username                  = "azureuser"
  admin_password                  = random_password.vm.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.jump.id]
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

# Cluster User gets a kubeconfig for the Entra-integrated endpoint; what you can
# then do inside the cluster is decided by Kubernetes RBAC. Cluster ADMIN hands
# out the local admin credential and bypasses all of that - which is why nothing
# here is granted it.
resource "azurerm_role_assignment" "jump_cluster_user" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_linux_virtual_machine.jump.identity[0].principal_id
}

# So the jump host can actually do something once it has a kubeconfig. Scoped to
# this cluster only.
resource "azurerm_role_assignment" "jump_rbac_reader" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  principal_id         = azurerm_linux_virtual_machine.jump.identity[0].principal_id
}

###############################################################################
# Bastion
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
  name                = "bastion-lab12"
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
