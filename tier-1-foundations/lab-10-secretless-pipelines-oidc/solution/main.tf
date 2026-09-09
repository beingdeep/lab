###############################################################################
# Lab 10 - Secretless Pipelines with Workload Identity Federation
#
# Reference build. Section numbers match the steps in the README.
#
# There is no client secret in this configuration, and no resource here is
# capable of holding one.
###############################################################################

data "azurerm_client_config" "current" {}

locals {
  github_issuer   = "https://token.actions.githubusercontent.com"
  github_audience = "api://AzureADTokenExchange"

  # Entra compares subjects as literal strings. There is no pattern matching, so
  # this is an exact statement about which run may authenticate.
  branch_subject      = "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}"
  environment_subject = "repo:${var.github_owner}/${var.github_repo}:environment:${var.github_environment}"

  # The broken version. Not a wildcard - Entra has none - but a repository-wide
  # credential, which is how people accidentally let every branch deploy.
  wildcard_subject = "repo:${var.github_owner}/${var.github_repo}:pull_request"
}

###############################################################################
# Step 1 - The only scope this pipeline may touch
###############################################################################

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

###############################################################################
# Step 2 - The identity
###############################################################################

resource "azurerm_user_assigned_identity" "deploy" {
  name                = var.identity_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

###############################################################################
# Step 3 - Federated credential for one branch
#
# A run from any other branch presents a different subject, matches no
# credential, and fails before it ever reaches Azure Resource Manager.
###############################################################################

resource "azurerm_federated_identity_credential" "branch" {
  name                = "github-main-branch"
  resource_group_name = azurerm_resource_group.lab.name
  parent_id           = azurerm_user_assigned_identity.deploy.id
  audience            = [local.github_audience]
  issuer              = local.github_issuer
  subject             = local.branch_subject
}

###############################################################################
# Step 4 - Federated credential for one environment
#
# The branch credential says "this code". The environment credential says "this
# deployment gate" - GitHub only issues an environment-scoped token after any
# required reviewers have approved.
###############################################################################

resource "azurerm_federated_identity_credential" "environment" {
  name                = "github-environment-prod"
  resource_group_name = azurerm_resource_group.lab.name
  parent_id           = azurerm_user_assigned_identity.deploy.id
  audience            = [local.github_audience]
  issuer              = local.github_issuer
  subject             = local.environment_subject
}

# Deliberately broken, off by default. Turning this on lets pull request runs
# authenticate, which includes pull requests opened by people who cannot merge.
resource "azurerm_federated_identity_credential" "wildcard" {
  count               = var.use_wildcard_subject ? 1 : 0
  name                = "github-any-pull-request-DANGEROUS"
  resource_group_name = azurerm_resource_group.lab.name
  parent_id           = azurerm_user_assigned_identity.deploy.id
  audience            = [local.github_audience]
  issuer              = local.github_issuer
  subject             = local.wildcard_subject
}

###############################################################################
# Step 5 - One role, at one resource group
#
# Federation controls who can get a token. RBAC controls what that token can do.
# A perfectly restricted subject with Owner on the subscription is a pipeline
# that can delete production the moment someone merges.
###############################################################################

resource "azurerm_role_assignment" "deploy" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = var.role_definition_name
  principal_id         = azurerm_user_assigned_identity.deploy.principal_id
}
