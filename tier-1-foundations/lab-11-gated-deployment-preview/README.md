# Lab 11: Gated Infrastructure Deployment with Preview

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Build a Bicep or Terraform pipeline where every change to production runs a plan
or what-if step, publishes the result as a reviewable artefact, and blocks on
manual approval before applying. The approval must be impossible to bypass by the
person who authored the change. Include a deliberate destructive change and show
it being caught at review.

---

## What You Will Learn

- **A plan is a prediction, and predictions go stale.** If you plan, wait for an
  approval, and then plan again at apply time, the reviewer approved something
  different from what runs. Save the plan file and apply *that*.
- **The artefact is the evidence.** "We reviewed it" is an assertion. A stored
  plan output attached to a run is a record you can produce a year later.
- **Approval gates belong to the platform, not the pipeline.** A step that says
  "wait for approval" can be edited by whoever writes the pipeline. A deployment
  environment with protection rules cannot.
- **Self-approval defeats the whole control.** Two-person review means two people.
  Most platforms have a specific setting for this and it is off by default.
- **Destructive changes hide in the middle of long plans.** `1 to destroy` is one
  line in four hundred. Surfacing it deliberately is part of the design.
- **Least privilege applies to pipelines too.** The job that plans needs read
  access. Only the job that applies needs write.

---

## Reference Flow

```
  pull request / push to main
        |
        v
  +----------------------+
  | job: plan            |   read-only credentials
  |  terraform plan -out |
  |  terraform show      |   human readable summary
  |  upload artefact     |   tfplan + the summary text
  +----------------------+
        |
        v
  +----------------------+
  | environment: production
  |   required reviewers |   platform-enforced, not pipeline-enforced
  |   prevent self review|   the author cannot approve their own change
  +----------------------+
        |  approved
        v
  +----------------------+
  | job: apply           |   write credentials
  |  download artefact   |
  |  terraform apply tfplan   <- the exact plan that was reviewed
  +----------------------+
```

---

## Build Instructions

This lab is mostly pipeline configuration. You need a GitHub repository, and the
federated identity from [Lab 10](../lab-10-secretless-pipelines-oidc/).

### Step 1 - Create the target resource group and something to change

Create **`rg-lab11`** with a storage account in it, deployed by Terraform. This is
what the pipeline will manage.

> **Why deploy something first:** A plan against an empty configuration shows
> everything as new, which is the easy case. You want a plan that modifies and
> destroys existing things, because that is where review matters.

### Step 2 - Split the pipeline into a plan job and an apply job

Two separate jobs. The apply job must declare a dependency on the plan job.

> **Why two jobs and not two steps:** Steps in one job run without interruption.
> Jobs can have an approval gate between them, and can run with different
> credentials.

### Step 3 - Save the plan to a file and publish it as an artefact

In the plan job:

- `terraform plan -out=tfplan`
- `terraform show -no-color tfplan > plan.txt`
- Upload **both** as a build artefact

> **Why save the binary plan and the text:** The binary `tfplan` is what you apply
> later - it pins the exact set of changes. The text version is what a human
> reads. Publishing only the text means you have a review record but still re-plan
> at apply time; publishing only the binary means nobody can review it.

> **Why this matters more than it sounds:** Between plan and approval, someone can
> merge another change, or a resource can drift, or a provider version can move.
> Applying a saved plan means Terraform refuses if the world no longer matches
> what was reviewed.

### Step 4 - Put a deployment environment between the jobs

Create a GitHub environment named **`production`** and set the apply job's
`environment: production`.

On the environment, configure:

| Protection rule | Value |
| --- | --- |
| Required reviewers | at least one person or team |
| Prevent self-review | **enabled** |

> **Why the environment and not an `if:` condition:** Protection rules live on the
> repository settings, not in the workflow file. Someone changing the workflow in
> a pull request cannot remove them. A gate written inside the file can be edited
> by the same commit it is supposed to be gating.

> **Why "prevent self-review" is the specific requirement:** Without it, the person
> who wrote the change clicks approve on their own change and the control has
> achieved nothing except a delay. It is a single checkbox and it is off by
> default.

### Step 5 - Apply the saved plan

In the apply job:

- Download the artefact
- `terraform apply tfplan` - with no `-auto-approve` needed, because a saved plan
  is already approved by definition, and no re-planning

> **Why not `terraform apply` with no arguments:** That plans again and applies
> whatever it finds. The approval then refers to a plan nobody ran.

### Step 6 - Give the two jobs different permissions

The plan job should authenticate as an identity with **Reader** on the target
scope. The apply job uses the **Contributor** identity from Lab 10.

> **Why:** A plan needs to read current state to compute a diff. It never needs to
> write. Running plan with write credentials means every pull request from anyone
> who can open one is executing with production write access.

### Step 7 - Make a destructive change and watch it get caught

Change something that forces a replacement rather than an update - changing a
storage account's kind will do it.

Run the pipeline. The plan output should say `1 to destroy`. Read the artefact,
find that line, and reject the deployment.

Then improve it: add a step that fails the plan job automatically if the plan
contains destructions, unless the run carries an explicit override.

> **Why automate it:** `1 to add, 0 to change, 1 to destroy` is one line among
> hundreds. Reviewers approve long plans at 5pm on Fridays. If the destruction
> count is a machine-checkable number, check it with a machine.

### Step 8 - Prove the author cannot self-approve

Have someone open a pull request and try to approve their own deployment. The
approve button should be unavailable to them.

---

## Terraform Solution

The reference build is in [`solution/`](solution/) and the pipelines are in
[`solution/pipelines/`](solution/pipelines/):

- `deploy.yml` - GitHub Actions, plan and apply split with an environment gate
- `azure-pipelines.yml` - the Azure DevOps equivalent, using a manual validation
  gate in a deployment job

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `simulate_destructive_change = true` and run `terraform plan` to produce the
plan from Step 7 - it forces the storage account to be replaced, so the plan says
`1 to destroy`.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | The target resource group exists, with something in it to plan against |
| 2 | A workflow defines a plan job that runs before any apply |
| 3 | The plan is written to a file and published as an artefact |
| 4 | The apply job downloads that artefact and applies the saved plan, rather than re-planning |
| 5 | The apply job is bound to a deployment environment |
| 6 | No job runs an apply outside that environment binding |
| 7 | (Optional, needs `gh`) The environment has required reviewers |
| 8 | (Optional, needs `gh`) The environment prevents self-review |

---

## Validation Script

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab11
```

Criteria 2 to 6 scan workflow files - by default under this lab folder, or point
at your repository with `-ScanPath ../../../my-repo`. Criteria 7 and 8 use the
GitHub CLI; supply `-GitHubRepo owner/repo` and be signed in with `gh auth login`.

---

## Follow-Up Questions

No answers here on purpose.

1. You applied a saved plan. What does Terraform do if the real world changed
   between the plan and the apply, and is that behaviour what you want at 2am
   during an incident?
2. The plan job runs on every pull request, including from people who only have
   read access to the repository. What is in a plan output that you might not want
   published to a pull request comment?
3. "Prevent self-review" stops the author approving. What stops two colleagues
   approving each other's changes all day, and is that a technical problem or a
   different kind of problem?
4. Your automated check fails the plan when it contains destructions. How do you
   ever deploy a legitimate deletion, and how do you stop that escape hatch
   becoming the normal path?
5. The plan job uses Reader credentials. Name something a plan cannot compute
   correctly with only read access, and what you would do about it.
6. Someone edits the workflow file in the same pull request as an infrastructure
   change. Which of your controls still apply to that run, and which do not?
7. An emergency change needs to go out in ten minutes and the approver is asleep.
   Design the break-glass path, and say how you would know afterwards that it had
   been used.

---

## Clean Up

```bash
az group delete -n rg-lab11 --yes --no-wait
```

---

[Back to the catalogue](../../README.md)
