###############################################################################
# Lab 11 - Gated Infrastructure Deployment with Preview
#
# The infrastructure here is deliberately small. The lab is about the pipeline
# around it, which lives in pipelines/. What matters is that there is something
# real to plan against, and one variable that turns an ordinary update into a
# replacement so you have a destructive plan to review.
###############################################################################

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix               = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result
  storage_account_name = "stglab11${local.suffix}"
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "data" {
  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  account_tier             = "Standard"
  account_replication_type = "LRS"

  # This one argument is the whole exercise. account_kind cannot be changed in
  # place, so flipping it turns a harmless-looking configuration edit into
  # "destroy this account and everything in it, then build a new one".
  account_kind = var.simulate_destructive_change ? "BlobStorage" : "StorageV2"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "data" {
  name               = "app-data"
  storage_account_id = azurerm_storage_account.data.id
}
