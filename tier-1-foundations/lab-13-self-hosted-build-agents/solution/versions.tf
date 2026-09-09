terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}

  # Leave null to use the ARM_SUBSCRIPTION_ID environment variable:
  #   export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  subscription_id = var.subscription_id
}
