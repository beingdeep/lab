###############################################################################
# Lab 09 - Terraform Remote State Done Properly
#
# This configuration bootstraps with LOCAL state, which is correct: something has
# to create the state store before there is a state store to use. In a real
# estate you run this once and then never touch it again.
#
# Notice there is no storage account key anywhere in this file, and no
# azurerm_storage_account_blob_container_sas data source. That is the point.
###############################################################################

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix               = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result
  storage_account_name = "stgtfstate09${local.suffix}"
}

resource "azurerm_resource_group" "state" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

###############################################################################
# Step 2 - The storage account
#
# shared_access_key_enabled = false is what makes the narrow role assignment
# below meaningful. A key is all-or-nothing and identifies nobody, so while one
# exists, least privilege on this account is decoration.
###############################################################################

resource "azurerm_storage_account" "state" {
  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location
  tags                = var.tags

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  shared_access_key_enabled       = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true

  blob_properties {
    # Terraform overwrites the whole state file on every apply. Versioning is
    # what lets you go back when an interrupted apply leaves you with a file that
    # describes an estate which does not exist.
    versioning_enabled = true

    # Versioning protects the contents of a blob. It does nothing if somebody
    # deletes the blob, and nothing at all if somebody deletes the container.
    # Two separate settings, both needed.
    delete_retention_policy {
      days = var.retention_days
    }

    container_delete_retention_policy {
      days = var.retention_days
    }
  }
}

# Created through Resource Manager rather than the storage data plane, so it
# works with shared keys disabled.
resource "azurerm_storage_container" "state" {
  name               = var.container_name
  storage_account_id = azurerm_storage_account.state.id
}

###############################################################################
# Step 4 - The pipeline identity
#
# A managed identity has no credential anyone can copy. Wiring it up to a
# pipeline that runs outside Azure is Lab 10.
###############################################################################

resource "azurerm_user_assigned_identity" "pipeline" {
  name                = var.identity_name
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location
  tags                = var.tags
}

###############################################################################
# Step 5 - Exactly one role, at the container scope
#
# Storage Blob Data Contributor is the smallest role that can read the state
# blob, write it back, and take and release the lease that provides locking.
# Reader cannot write; Owner adds the ability to change other people's access.
###############################################################################

resource "azurerm_role_assignment" "pipeline_state" {
  scope                = var.scope_role_to_container ? azurerm_storage_container.state.id : azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.pipeline.principal_id
}
