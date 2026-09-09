###############################################################################
# Lab 07 - Application Gateway with WAF in Front of a Private App
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
  suffix         = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result
  web_app_name   = "app-lab07-${local.suffix}"
  key_vault_name = "kv-lab07-${local.suffix}"

  subnet_agw    = cidrsubnet(var.vnet_address_space, 8, 1) # 10.70.1.0/24
  subnet_pe     = cidrsubnet(var.vnet_address_space, 8, 2) # 10.70.2.0/24
  subnet_appint = cidrsubnet(var.vnet_address_space, 8, 3) # 10.70.3.0/24

  # Application Gateway config element names, referenced from several places.
  agw_frontend_ip   = "feip-public"
  agw_frontend_port = "feport-443"
  agw_ip_config     = "gw-ipconfig"
  agw_backend_pool  = "bepool-app"
  agw_http_settings = "behttp-https"
  agw_listener      = "listener-https"
  agw_probe         = "probe-app"
  agw_cert          = "agw-cert"
}

###############################################################################
# Step 1 - Resource group, virtual network, three subnets
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

# Application Gateway v2 takes this subnet for itself and rejects other resource
# types in it. A /24 is far more than needed, but resizing later means
# redeploying the gateway.
resource "azurerm_subnet" "agw" {
  name                 = "snet-agw"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_agw]
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [local.subnet_pe]
}

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
# Step 2 - Private DNS zone, linked to the gateway's own network
#
# The gateway addresses the backend by the app's hostname and resolves it with
# the DNS of the network it sits in. Without this link the gateway resolves the
# public address and reaches your "private" backend over the internet - which
# still works, so nothing looks wrong.
###############################################################################

resource "azurerm_private_dns_zone" "web" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "web" {
  name                  = "link-${var.vnet_name}"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.web.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = var.tags
}

###############################################################################
# Step 3 - App Service, private and closed
###############################################################################

resource "azurerm_service_plan" "plan" {
  name                = "plan-lab07"
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

  public_network_access_enabled = false
  virtual_network_subnet_id     = azurerm_subnet.appint.id

  site_config {
    vnet_route_all_enabled = true
    ftps_state             = "Disabled"
    minimum_tls_version    = "1.2"

    application_stack {
      dotnet_version = "8.0"
    }
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
# Step 4 - Certificate, vault and the identity that reads it
#
# This vault keeps public access enabled because Terraform has to write the
# certificate through the data plane. Locking a vault down properly is Lab 06.
###############################################################################

resource "azurerm_key_vault" "certs" {
  name                      = local.key_vault_name
  resource_group_name       = azurerm_resource_group.lab.name
  location                  = azurerm_resource_group.lab.location
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  sku_name                  = "standard"
  enable_rbac_authorization = true
  purge_protection_enabled  = false
  tags                      = var.tags
}

# A user-assigned identity exists before the gateway does, so the role can be
# granted first. A system-assigned one would not exist until the gateway is being
# created, which is exactly when it needs to fetch the certificate.
resource "azurerm_user_assigned_identity" "agw" {
  name                = "id-agw"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "agw_secrets" {
  scope                = azurerm_key_vault.certs.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agw.principal_id
}

resource "azurerm_role_assignment" "agw_certs" {
  scope                = azurerm_key_vault.certs.id
  role_definition_name = "Key Vault Certificate User"
  principal_id         = azurerm_user_assigned_identity.agw.principal_id
}

# Terraform needs this one to create the certificate below.
resource "azurerm_role_assignment" "tf_certs_officer" {
  scope                = azurerm_key_vault.certs.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Role assignments are eventually consistent. Without this pause the certificate
# creation below frequently fails with a permissions error on a fresh apply.
resource "time_sleep" "role_propagation" {
  depends_on      = [azurerm_role_assignment.tf_certs_officer]
  create_duration = var.role_propagation_delay
}

resource "azurerm_key_vault_certificate" "agw" {
  name         = local.agw_cert
  key_vault_id = azurerm_key_vault.certs.id
  depends_on   = [time_sleep.role_propagation]

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      key_usage = [
        "digitalSignature",
        "keyEncipherment",
      ]
      subject            = var.certificate_subject
      validity_in_months = 12

      subject_alternative_names {
        dns_names = ["lab07.local"]
      }
    }
  }
}

###############################################################################
# Step 5 - The WAF policy
#
# Detection logs an attack and serves the request anyway. Prevention blocks it.
# Detection exists so you can tune rules against real traffic; plenty of
# production gateways are still sitting in it years later.
###############################################################################

resource "azurerm_web_application_firewall_policy" "waf" {
  name                = "waf-lab07"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = var.waf_mode
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

###############################################################################
# Step 6 - The Application Gateway
#
# The backend is the app's HOSTNAME, not an IP. App Service routes by Host
# header; pointed at a bare address it returns a 404 from Azure's shared front
# end because it has no idea which of thousands of apps you meant. Preserving the
# hostname in both the backend settings and the probe is what makes it answer.
###############################################################################

resource "azurerm_public_ip" "agw" {
  name                = "pip-agw"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_application_gateway" "agw" {
  name                = "agw-lab07"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  firewall_policy_id  = azurerm_web_application_firewall_policy.waf.id
  tags                = var.tags

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agw.id]
  }

  gateway_ip_configuration {
    name      = local.agw_ip_config
    subnet_id = azurerm_subnet.agw.id
  }

  frontend_ip_configuration {
    name                 = local.agw_frontend_ip
    public_ip_address_id = azurerm_public_ip.agw.id
  }

  frontend_port {
    name = local.agw_frontend_port
    port = 443
  }

  # Referencing the vault rather than uploading a copy means renewal is picked up
  # automatically instead of needing a redeploy.
  ssl_certificate {
    name                = local.agw_cert
    key_vault_secret_id = azurerm_key_vault_certificate.agw.versionless_secret_id
  }

  # TLS terminates here, which is what lets the WAF read the request body.
  http_listener {
    name                           = local.agw_listener
    frontend_ip_configuration_name = local.agw_frontend_ip
    frontend_port_name             = local.agw_frontend_port
    protocol                       = "Https"
    ssl_certificate_name           = local.agw_cert
  }

  backend_address_pool {
    name  = local.agw_backend_pool
    fqdns = [azurerm_linux_web_app.app.default_hostname]
  }

  # Re-encrypted to the backend, so the second hop is not plaintext either.
  backend_http_settings {
    name                                = local.agw_http_settings
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 30
    pick_host_name_from_backend_address = true
    probe_name                          = local.agw_probe
  }

  probe {
    name                                      = local.agw_probe
    protocol                                  = "Https"
    path                                      = "/"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true

    match {
      status_code = ["200-399", "403"]
    }
  }

  request_routing_rule {
    name                       = "rule-https"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = local.agw_listener
    backend_address_pool_name  = local.agw_backend_pool
    backend_http_settings_name = local.agw_http_settings
  }

  depends_on = [
    azurerm_role_assignment.agw_secrets,
    azurerm_role_assignment.agw_certs,
    azurerm_private_endpoint.web,
  ]
}
