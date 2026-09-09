###############################################################################
# Lab 14 - Diagnostics Enforced by Policy
#
# Reference build. Section numbers match the steps in the README.
###############################################################################

data "azurerm_subscription" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix         = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result
  workspace_name = "law-lab14-${local.suffix}"
}

###############################################################################
# Step 1 - Resource group and central workspace
#
# One workspace, so that when someone asks what happened on the night of the
# 12th there is one place to look. Per-team workspaces feel tidier and are much
# worse during an incident.
###############################################################################

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = local.workspace_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

###############################################################################
# Step 2 - The policy definition
#
# The existenceCondition is the part that decides whether this policy is useful
# or a menace. Too narrow and it thinks everything is compliant and never
# deploys; too broad and it redeploys constantly over settings people changed on
# purpose.
###############################################################################

resource "azurerm_policy_definition" "nsg_diagnostics" {
  name         = var.policy_definition_name
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Deploy diagnostic settings for network security groups"

  description = <<-EOT
    Deploys a diagnostic setting sending network security group logs to a central
    Log Analytics workspace, on any NSG that does not already have one pointing at
    that workspace.
  EOT

  metadata = jsonencode({
    category = "Monitoring"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    logAnalytics = {
      type = "String"
      metadata = {
        displayName = "Log Analytics workspace"
        description = "Resource ID of the workspace to send logs to."
        strongType  = "omsWorkspace"
      }
    }
    effect = {
      type          = "String"
      allowedValues = ["DeployIfNotExists", "AuditIfNotExists", "Disabled"]
      defaultValue  = "DeployIfNotExists"
      metadata = {
        displayName = "Effect"
      }
    }
    profileName = {
      type         = "String"
      defaultValue = "diag-to-central-law"
      metadata = {
        displayName = "Diagnostic setting name"
      }
    }
  })

  policy_rule = jsonencode({
    if = {
      field  = "type"
      equals = "Microsoft.Network/networkSecurityGroups"
    }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type = "Microsoft.Insights/diagnosticSettings"
        name = "[parameters('profileName')]"

        # "Already correct" means: a diagnostic setting exists, its logs are
        # enabled, and it points at THIS workspace. Checking only that some
        # setting exists would let a resource logging somewhere else pass.
        existenceCondition = {
          allOf = [
            {
              field  = "Microsoft.Insights/diagnosticSettings/logs.enabled"
              equals = "true"
            },
            {
              field  = "Microsoft.Insights/diagnosticSettings/workspaceId"
              equals = "[parameters('logAnalytics')]"
            }
          ]
        }

        # The policy identity starts with no permissions at all. These are the
        # roles the deployment below actually needs - a deployIfNotExists policy
        # with no roles evaluates happily, reports non-compliance, and silently
        # fails every deployment.
        roleDefinitionIds = [
          "/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa", # Monitoring Contributor
          "/providers/Microsoft.Authorization/roleDefinitions/92aaf0da-9dab-42b6-94a3-d43ce8d16293"  # Log Analytics Contributor
        ]

        deployment = {
          properties = {
            mode = "incremental"
            parameters = {
              resourceName = { value = "[field('name')]" }
              location     = { value = "[field('location')]" }
              logAnalytics = { value = "[parameters('logAnalytics')]" }
              profileName  = { value = "[parameters('profileName')]" }
            }
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters = {
                resourceName = { type = "string" }
                location     = { type = "string" }
                logAnalytics = { type = "string" }
                profileName  = { type = "string" }
              }
              resources = [
                {
                  type       = "Microsoft.Network/networkSecurityGroups/providers/diagnosticSettings"
                  apiVersion = "2021-05-01-preview"
                  name       = "[concat(parameters('resourceName'), '/Microsoft.Insights/', parameters('profileName'))]"
                  location   = "[parameters('location')]"
                  properties = {
                    workspaceId = "[parameters('logAnalytics')]"
                    logs = [
                      {
                        category = "NetworkSecurityGroupEvent"
                        enabled  = true
                      },
                      {
                        category = "NetworkSecurityGroupRuleCounter"
                        enabled  = true
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
  })
}

###############################################################################
# Step 3 - Assignment at subscription scope
#
# Subscription scope, because the requirement is every resource in the
# subscription including ones in resource groups nobody has created yet.
#
# The location is required whenever the assignment has an identity - the managed
# identity is a regional object, and omitting it produces an unhelpful error.
###############################################################################

resource "azurerm_subscription_policy_assignment" "nsg_diagnostics" {
  name                 = var.assignment_name
  display_name         = "Enforce network security group diagnostics"
  policy_definition_id = azurerm_policy_definition.nsg_diagnostics.id
  subscription_id      = data.azurerm_subscription.current.id
  location             = var.location
  enforce              = var.assignment_enforcement == "Default"

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    logAnalytics = {
      value = azurerm_log_analytics_workspace.law.id
    }
  })
}

###############################################################################
# Step 4 - Roles for the policy identity
#
# Exactly the two the deployment template touches. A policy identity with
# subscription Contributor is a standing, unattended, fully privileged principal.
###############################################################################

resource "azurerm_role_assignment" "policy_monitoring" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Monitoring Contributor"
  principal_id         = azurerm_subscription_policy_assignment.nsg_diagnostics.identity[0].principal_id
}

resource "azurerm_role_assignment" "policy_law" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_subscription_policy_assignment.nsg_diagnostics.identity[0].principal_id
}

# Role assignments are eventually consistent. A remediation task started too
# early fails every deployment, and the failure message does not mention roles.
resource "time_sleep" "role_propagation" {
  depends_on = [
    azurerm_role_assignment.policy_monitoring,
    azurerm_role_assignment.policy_law,
  ]
  create_duration = var.role_propagation_delay
}

###############################################################################
# Step 5 - Remediation task
#
# Policy evaluates on create and update. Everything that existed before the
# assignment is non-compliant and will stay that way forever - it is never going
# to be "created" again. This is what walks the existing estate.
###############################################################################

resource "azurerm_subscription_policy_remediation" "nsg_diagnostics" {
  name                    = "remediate-nsg-diagnostics"
  subscription_id         = data.azurerm_subscription.current.id
  policy_assignment_id    = azurerm_subscription_policy_assignment.nsg_diagnostics.id
  resource_discovery_mode = "ReEvaluateCompliance"

  depends_on = [time_sleep.role_propagation]
}

###############################################################################
# Step 6 - Something for the policy to catch
#
# Created after the assignment exists, so it is a genuine "new resource" test
# rather than something the remediation task picked up.
###############################################################################

resource "azurerm_network_security_group" "test" {
  count               = var.create_test_nsg ? 1 : 0
  name                = "nsg-policy-test"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  depends_on = [time_sleep.role_propagation]
}
