# Lab 14: Diagnostics Enforced by Policy

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Every resource in a subscription must send diagnostic logs to a central Log
Analytics workspace, including resources that do not exist yet. Enforce this with
Azure Policy using a deployIfNotExists effect and a remediation task for existing
resources. Show a newly created resource being configured automatically within
minutes.

---

## What You Will Learn

- **Azure Policy can deploy, not just deny.** `deployIfNotExists` watches for
  resources that are missing something and creates it for them.
- **A policy with that effect needs an identity of its own.** It is going to write
  resources on your behalf, so the assignment gets a managed identity and you have
  to grant it roles.
- **Policy only fires on create and update.** Everything that already existed when
  you assigned it stays non-compliant until you run a *remediation task*.
- **The `existenceCondition` is what makes it idempotent.** It describes what
  "already correct" looks like, so the policy does not redeploy over a setting
  somebody deliberately changed.
- **Compliance evaluation is slow; the deployment is not.** A new resource gets
  its diagnostic setting within minutes, but the compliance dashboard can take up
  to half an hour to admit it.
- **Logs you did not configure before an incident do not exist after it.** This is
  the whole reason to enforce it centrally rather than asking teams nicely.

---

## Reference Architecture

```
  subscription
  +----------------------------------------------------------------+
  |  policy definition: deploy-nsg-diagnostics                     |
  |     if     type == Microsoft.Network/networkSecurityGroups     |
  |     then   deployIfNotExists                                   |
  |              existenceCondition: a diagnostic setting          |
  |                pointing at THIS workspace                      |
  |              deployment: create one if absent                  |
  |                                                                |
  |  assignment at subscription scope                              |
  |     identity: system-assigned                                  |
  |     roles:   Monitoring Contributor, Log Analytics Contributor |
  |     parameter: workspace = law-lab14                           |
  |                                                                |
  |  remediation task -> fixes everything that already existed     |
  +----------------------------------------------------------------+
                              |
                              v
                    law-lab14 (Log Analytics)
```

---

## Build Instructions

You need permission to create policy definitions and role assignments at
subscription scope. `Owner` or `Contributor` plus `User Access Administrator`
will do.

### Step 1 - Create the resource group and workspace

Create **`rg-lab14`** and a Log Analytics workspace **`law-lab14-<unique>`** with
30 days retention.

> **Why one central workspace:** So that when you are asked "what happened on the
> night of the 12th", there is one place to look. Per-team workspaces feel tidier
> and are far worse during an incident.

### Step 2 - Write the policy definition

Create a policy definition named **`deploy-nsg-diagnostics`** with:

- **Mode**: `Indexed`
- **Effect**: `deployIfNotExists`
- **Condition**: resource type is `Microsoft.Network/networkSecurityGroups`
- **Existence condition**: a diagnostic setting exists whose workspace is the one
  passed as a parameter, with logs enabled
- **Deployment**: create that diagnostic setting
- **Parameters**: the workspace resource ID, and the effect

> **Why network security groups:** They are cheap, quick to create, and every
> subscription has them - so the demonstration is fast. The pattern is identical
> for any resource type; only the `logs` categories change.

> **Why the existence condition matters so much:** Without a precise one, the
> policy either thinks everything is compliant (and never deploys) or thinks
> nothing is (and redeploys constantly, overwriting settings people changed on
> purpose). This is where most `deployIfNotExists` policies go wrong.

> **Why `Indexed` mode:** It tells Policy to only evaluate resource types that
> support tags and locations, which skips subscription-level and extension
> resources that would otherwise produce noise.

### Step 3 - Assign it at subscription scope

Create an assignment named **`enforce-nsg-diagnostics`** at **subscription
scope**, with:

- A **system-assigned managed identity**
- A **location** (required whenever there is an identity)
- The workspace parameter set to your workspace

> **Why subscription scope and not the resource group:** The requirement says
> every resource in the subscription, including ones that do not exist yet -
> including in resource groups nobody has created yet. Assign at the scope you
> want to govern, not the scope you happen to be working in.

> **Why the assignment needs a location:** The managed identity is a regional
> object. It is easy to miss, and the assignment fails with an unhelpful error.

### Step 4 - Grant the policy identity the roles it needs

Assign to the assignment's managed identity, at subscription scope:

- **`Monitoring Contributor`** - to create diagnostic settings
- **`Log Analytics Contributor`** - to write to the workspace

> **Why this is a separate step:** The policy identity starts with no permissions
> at all. A `deployIfNotExists` policy with no roles evaluates happily, reports
> resources as non-compliant, and silently fails every deployment. The symptom is
> "policy does nothing", and the cause is always this.

> **Why not `Contributor`:** These two roles are exactly what the deployment
> template touches. A policy identity with subscription `Contributor` is a
> standing, unattended, fully privileged principal.

### Step 5 - Create a remediation task

Create a remediation task for the assignment.

> **Why it is needed at all:** Policy evaluates on create and update. Everything
> that existed before you assigned the policy is non-compliant and will stay that
> way indefinitely - it is never going to be "created" again. The remediation task
> is what walks the existing estate and applies the deployment retroactively.

### Step 6 - Prove it on something new

Create a new network security group in any resource group in the subscription.
Wait a few minutes, then look at its diagnostic settings.

One should be there, pointing at your workspace, that you did not create.

> **Why "wait a few minutes" and not "wait for the compliance dashboard":** The
> deployment happens quickly. The compliance *state* is recalculated on a much
> slower cycle - up to 30 minutes, sometimes longer. Judging whether this works by
> watching the dashboard will convince you it is broken.

### Step 7 - Prove the existence condition holds

Change something harmless on the diagnostic setting the policy created - the
name, or add a category. Wait, and confirm the policy does not fight you.

Then delete the diagnostic setting entirely, and confirm it comes back.

> **Why test both:** The first proves your existence condition is not too narrow.
> The second proves it is not too broad. A policy that passes only one of those is
> a policy that will either flap or do nothing, and you will not find out which
> until it matters.

---

## Terraform Solution

The full reference build is in [`solution/`](solution/), including the policy
rule JSON.

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

It also creates a test network security group **after** the assignment exists, so
you have something for Step 6 to have caught.

Set `assignment_enforcement = "DoNotEnforce"` to run the policy in audit-only
mode - it reports compliance and deploys nothing, which is how you would
introduce this to an estate you do not own.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | A Log Analytics workspace exists |
| 2 | A custom policy definition exists with the `deployIfNotExists` effect |
| 3 | The definition has an existence condition, so it is idempotent |
| 4 | The policy is assigned at subscription scope |
| 5 | The assignment has a managed identity |
| 6 | The identity holds `Monitoring Contributor` and `Log Analytics Contributor` at the assignment scope |
| 7 | The identity does not hold `Owner` or `Contributor` at subscription scope |
| 8 | The assignment's workspace parameter points at the workspace |
| 9 | Enforcement mode is `Default`, not `DoNotEnforce` |
| 10 | A remediation task exists for the assignment |
| 11 | (Optional, with `-TestResourceGroup`) Every network security group in that group has a diagnostic setting pointing at the workspace |

---

## Validation Script

```bash
pwsh ./validate.ps1 -WorkspaceResourceGroup rg-lab14 `
  -WorkspaceName law-lab14-abc123 -AssignmentName enforce-nsg-diagnostics
```

Add `-TestResourceGroup rg-lab14` to check that the policy actually did its job on
the resources in that group.

---

## Follow-Up Questions

No answers here on purpose.

1. The policy identity can create diagnostic settings anywhere in the
   subscription, unattended, forever. What could someone do with that identity if
   they could modify the policy definition, and who can do that?
2. Your existence condition checks the workspace. What happens to a resource whose
   team deliberately sends logs to *their* workspace as well as yours - does the
   policy leave it alone, or fight it?
3. `deployIfNotExists` runs on create and update. A resource created while the
   policy was briefly disabled is never updated again. How would you ever find it?
4. Log Analytics charges by ingested gigabyte. Estimate what "every resource in the
   subscription" costs for a mid-sized estate, and name three resource types you
   would exclude first.
5. This policy targets one resource type. Turning it into an initiative covering
   forty types means forty existence conditions. What would you do differently at
   that scale, and what does Microsoft already provide?
6. The remediation task fixed existing resources. What happens if it fails partway
   through - is it resumable, and how do you tell which resources it reached?
7. Someone deletes the workspace. What does the policy do on the next evaluation,
   what happens to resources whose diagnostic settings point at it, and how quickly
   would anyone notice?

---

## Clean Up

Order matters here - the assignment and definition live at subscription scope, so
deleting the resource group leaves them behind:

```bash
az policy remediation delete -n remediate-nsg-diagnostics
az policy assignment delete -n enforce-nsg-diagnostics
az policy definition delete -n deploy-nsg-diagnostics
az group delete -n rg-lab14 --yes --no-wait
```

Or `terraform destroy`, which handles the ordering for you.

---

[Back to the catalogue](../../README.md)
