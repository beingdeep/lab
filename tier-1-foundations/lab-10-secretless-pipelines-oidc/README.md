# Lab 10: Secretless Pipelines with Workload Identity Federation

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Configure an Azure DevOps or GitHub Actions pipeline that deploys to Azure with
no stored client secret and no service principal password. Use workload identity
federation with a subject restricted to a single branch and environment. Prove
that a pipeline run from a different branch fails authentication. Document the
trust chain end to end.

---

## What You Will Learn

- **A stored secret is a copy of your identity sitting in someone else's system.**
  Anyone who can read your CI variables can deploy as you, from anywhere, until
  the secret expires.
- **Federation replaces the secret with a proof.** GitHub signs a short-lived
  token describing the run: which repository, which branch, which environment.
  Entra trusts that signature and swaps the token for an Azure one.
- **The subject is the security boundary.** It is a string like
  `repo:acme/infra:ref:refs/heads/main`. Entra checks it exactly. Get it wrong,
  or make it broad, and any branch in that repository can deploy to production.
- **The token lasts minutes, not months.** There is nothing to rotate, nothing to
  leak, nothing to find in a git history five years later.
- **Trust is directional and specific.** You are not trusting GitHub. You are
  trusting one repository, one branch, for one identity, at one scope.
- **Scope the role assignment too.** Federation controls *who* can get a token.
  RBAC controls *what they can do* once they have one.

---

## The Trust Chain

Worth writing out, because the problem asks you to document it.

```
 1. A workflow runs in GitHub on branch main.
 2. GitHub mints a JSON Web Token describing that run:
        iss  https://token.actions.githubusercontent.com
        sub  repo:<owner>/<repo>:ref:refs/heads/main
        aud  api://AzureADTokenExchange
    It is signed by GitHub and lasts minutes.
 3. The workflow sends that token to Entra, along with the client ID of the
    identity it wants to become.
 4. Entra looks up the federated credentials on that identity and looks for one
    where issuer, subject and audience ALL match exactly.
 5. Entra verifies GitHub's signature using GitHub's published public keys.
 6. Entra issues an Azure access token for the identity.
 7. Azure Resource Manager authorises the request using that identity's role
    assignments.
```

Nothing in that chain is a stored credential. The two places you can get it wrong
are step 4, if the subject is too broad, and step 7, if the role is too wide.

---

## Build Instructions

You need a GitHub repository you control. Azure DevOps works the same way, with a
different issuer and subject format.

### Step 1 - Create the resource group

Create **`rg-lab10`**. This is what the pipeline will be allowed to deploy into,
and nothing else.

### Step 2 - Create a user-assigned managed identity

Create **`id-deploy-lab10`**.

> **Why a managed identity rather than an app registration:** A managed identity
> has no secret and no way to add one. An app registration can hold client
> secrets, so somebody can always undo your work by adding one "just for now".
> Choosing an object that cannot hold a password removes the temptation entirely.

### Step 3 - Add a federated credential for the main branch

On the identity, add a federated credential named **`github-main-branch`**:

| Field | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject | `repo:<owner>/<repo>:ref:refs/heads/main` |
| Audience | `api://AzureADTokenExchange` |

> **Why the subject is written exactly like that:** GitHub decides the format, and
> Entra compares it as a literal string. `ref:refs/heads/main` means the branch
> `main` in that one repository. There is no pattern matching and no wildcard - a
> run from `feature/x` produces a different subject, finds no matching credential,
> and fails at step 4 of the trust chain.

> **Why the audience matters:** It stops a token that GitHub minted for some other
> service being replayed at Entra.

### Step 4 - Add a second federated credential for the environment

Add **`github-environment-prod`**:

| Field | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject | `repo:<owner>/<repo>:environment:production` |
| Audience | `api://AzureADTokenExchange` |

Then create an environment called `production` in the repository, with required
reviewers.

> **Why both:** The branch credential says "this code". The environment credential
> says "this deployment gate". An environment in GitHub can require human approval
> before the job runs, and the job only receives an environment-scoped token after
> that approval. Combining the two means production deployments need approved code
> *and* an approved deployment.

### Step 5 - Grant the identity a role, scoped tightly

Assign **`Contributor`** to the identity, scoped to **`rg-lab10`** only.

Do not assign at subscription scope. Do not assign `Owner`.

> **Why not subscription scope:** Federation controls who can get a token. RBAC
> controls what that token can do. A perfectly restricted subject with Owner on the
> subscription is a pipeline that can delete your production estate the moment
> someone merges to main.

> **Why not `Owner`:** `Owner` includes the ability to create role assignments,
> which means the pipeline can grant itself, or anything else, any permission it
> likes. That is not a deployment pipeline, that is an administrator.

### Step 6 - Write the workflow

Your workflow needs three things and must not contain a fourth:

- `permissions: id-token: write` at the job or workflow level - without it GitHub
  will not mint a token at all
- The identity's **client ID**, your **tenant ID** and **subscription ID** as
  plain configuration - none of these are secrets
- `azure/login@v2` with those three values and no `client-secret`
- **No** `creds:` JSON blob and no `AZURE_CREDENTIALS` secret

A working example is in [`solution/pipelines/deploy.yml`](solution/pipelines/deploy.yml).

> **Why the client ID is not a secret:** It is an identifier, like a username.
> Knowing it gets you nothing without a token from a run that GitHub actually
> performed in your repository, on the right branch.

### Step 7 - Prove a different branch fails

Create a branch, push the same workflow, and run it.

It will fail at the login step with an error saying no matching federated identity
record was found for the presented assertion. Read that message carefully - it
usually prints the subject it presented, which is the fastest way to debug a
subject mismatch.

> **Why this is the whole test:** Anyone can make a pipeline that deploys. The
> point of this lab is the pipeline that *refuses* to deploy from the wrong place.

### Step 8 - Document the chain

Write out the seven steps above for your own configuration, with your real
repository name and identity. Then answer: what is the smallest change anyone
could make that would silently widen this?

---

## Terraform Solution

The full reference build is in [`solution/`](solution/). You must set your
repository:

```bash
cd solution
cp terraform.tfvars.example terraform.tfvars
# edit github_owner and github_repo
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `use_wildcard_subject = true` to build the broken version - a subject that
matches any branch - and watch the "wrong branch fails" test stop failing. That
is the mistake this lab exists to prevent.

The workflow file is in `solution/pipelines/deploy.yml`. Copy it into
`.github/workflows/` in your repository.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | A user-assigned managed identity exists for the pipeline |
| 2 | At least one federated identity credential is configured on it |
| 3 | Every federated credential uses a recognised OIDC issuer |
| 4 | Every federated credential audience is `api://AzureADTokenExchange` |
| 5 | No federated credential subject contains a wildcard - each names a specific branch or environment |
| 6 | A federated credential exists for a specific branch, and one for a specific environment |
| 7 | The identity's role assignments are scoped no wider than a resource group |
| 8 | The identity holds neither `Owner` nor `User Access Administrator` |
| 9 | Workflow files request an OIDC token and contain no client secret |

---

## Validation Script

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab10 -IdentityName id-deploy-lab10
```

Criterion 9 scans workflow files. By default it scans the lab folder; point it at
your repository with `-ScanPath ../../../my-repo/.github`.

---

## Follow-Up Questions

No answers here on purpose.

1. The client ID, tenant ID and subscription ID are all public in your workflow
   file. Convince yourself that is safe - what exactly stops someone else using
   them?
2. Your subject is `repo:owner/repo:ref:refs/heads/main`. What happens if somebody
   forks the repository, or renames it, or transfers it to another organisation?
3. GitHub signs the token. Where does Entra get the public key to verify it, how
   often does it refresh them, and what happens during a key rotation?
4. A pull request from a fork runs with a different subject again. Look up what it
   is, and decide whether your configuration is safe from a malicious pull request.
5. You granted `Contributor` on one resource group. What can a compromised
   workflow still do to resources *outside* that group, given that many Azure
   resources reference each other across scopes?
6. The environment credential requires an approval. Who can approve, and can the
   person who wrote the code approve their own deployment? How would you prove
   that to an auditor?
7. If this identity were compromised, what is your revocation procedure, and how
   long between deciding to revoke and the pipeline actually losing access?

---

## Clean Up

```bash
az group delete -n rg-lab10 --yes --no-wait
```

Also remove the workflow from your repository, and the `production` environment if
you created one.

---

[Back to the catalogue](../../README.md)
