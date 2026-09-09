# Lab 06: Key Vault with RBAC and Identity-Only Access

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Stand up a Key Vault using the RBAC data plane permission model rather than
access policies. Only a specific application's managed identity may read secrets,
and no human account may read them without an explicit, auditable role
assignment. Public access must be disabled. Prove that removing the role
assignment immediately breaks the application.

---

## What You Will Learn

- **Key Vault has two permission models and you must pick one.** The old *access
  policies* model is a list attached to the vault. The RBAC model uses normal
  Azure role assignments. RBAC is the one that shows up in access reviews, in
  policy, and in `az role assignment list`.
- **Access policies are invisible to the rest of Azure.** Nothing that audits
  "who can read this" will find them, because they are not role assignments.
- **Control plane and data plane are separate again.** `Contributor` on a vault
  cannot read a secret under RBAC - but it *can* change the vault back to access
  policies and grant itself one. Watch for that.
- **Role assignments are the audit trail.** Every grant has a principal, a scope,
  a role, and a timestamp. That is the property the requirement "explicit and
  auditable" is actually asking for.
- **Scope goes below the vault.** You can assign a role on one individual secret,
  not just the whole vault.
- **Removing a role takes effect quickly but not instantly.** Token caching means
  the app may keep working for a few minutes. That gap is worth measuring.

---

## Reference Architecture

```
  vnet-lab06 10.60.0.0/16
  +---------------------------------------------------------------+
  |  snet-app 10.60.2.0/24                                        |
  |    [ vm-app ] system-assigned identity                        |
  |         |     role: Key Vault Secrets User (vault scope)      |
  |         v                                                     |
  |  snet-pe 10.60.1.0/24                                         |
  |    [ pe-kv ] --> Key Vault                                    |
  |                    RBAC authorisation ...... Enabled          |
  |                    access policies .......... none            |
  |                    public network access .... Disabled        |
  |  AzureBastionSubnet 10.60.3.0/26                              |
  +---------------------------------------------------------------+

  privatelink.vaultcore.azure.net -> A: kv-lab06-xxxx -> 10.60.1.4
```

---

## Build Instructions

### Step 1 - Resource group and virtual network

Create **`rg-lab06`** and **`vnet-lab06`** with address space **`10.60.0.0/16`**:

| Subnet name | Address prefix |
| --- | --- |
| `snet-pe` | `10.60.1.0/24` |
| `snet-app` | `10.60.2.0/24` |
| `AzureBastionSubnet` | `10.60.3.0/26` |

### Step 2 - Create the private DNS zone

Create **`privatelink.vaultcore.azure.net`** and link it to `vnet-lab06`,
registration disabled.

> **Why that name:** Key Vault's public name is `vault.azure.net`, but its private
> link zone is `vaultcore.azure.net`. They are different words and the wrong one
> gives you a healthy zone that resolves nothing.

### Step 3 - Create the Key Vault

Create **`kv-lab06-<unique>`** with:

| Setting | Value |
| --- | --- |
| Permission model | **Azure RBAC** (not access policies) |
| Public network access | **Disabled** |
| Network ACL default action | **Deny** |
| Soft delete retention | 7 days |
| Purge protection | off for the lab, on in production |

Do not create any access policies.

> **Why RBAC rather than access policies:** An access policy is a list stored on
> the vault itself. It is not a role assignment, so it does not appear in access
> reviews, in `az role assignment list`, in Privileged Identity Management, or in
> most compliance tooling. Someone can hold full secret access for years and no
> report will ever mention them. RBAC makes every grant a first-class, auditable
> object.

> **Why purge protection is off here:** With it on, a deleted vault is retained
> and its name reserved for the retention period, so re-running this lab with the
> same name fails. Turn it on for anything real.

### Step 4 - Create the private endpoint

Create **`pe-kv`** in `snet-pe`, targeting the vault, sub-resource **`vault`**,
with a DNS zone group pointing at `privatelink.vaultcore.azure.net`.

### Step 5 - Deploy the application VM with a managed identity

Create **`vm-app`** in `snet-app`, no public IP, **system-assigned managed
identity**. Deploy Bastion so you can sign in.

### Step 6 - Grant exactly one role, to exactly one identity

Assign **`Key Vault Secrets User`** to `vm-app`'s managed identity, scoped to the
vault.

Assign nothing to yourself.

> **Why `Key Vault Secrets User` and not `Key Vault Administrator`:** Secrets User
> can read secret values and nothing else. Administrator can read, write, delete
> and manage access. The application only ever reads, so that is all it gets.

> **Why you do not grant yourself access:** The requirement is that no human can
> read secrets without an explicit, auditable grant. Creating one for yourself
> "just to test" and leaving it there is exactly the thing being tested. If you
> need to read a secret later, assign the role deliberately, use it, and remove
> it - and notice how visible that is compared to an access policy.

### Step 7 - Create a secret, from inside the network

Because public access is off, you cannot write a secret from your laptop. Sign in
to `vm-app` over Bastion and create one there - for example a secret named
`app-connection-string`.

The VM's identity has `Key Vault Secrets User`, which is read-only, so grant
yourself `Key Vault Secrets Officer` temporarily from inside, create the secret,
and remove the role again. Notice how each of those three actions is a separate,
timestamped, attributable event.

> **Why this friction is the point:** A vault you can casually write to from
> anywhere is a vault anyone can casually write to from anywhere.

### Step 8 - Prove the role assignment is what is holding it up

From `vm-app`, read the secret using the managed identity - it should work.

Now delete the role assignment and read it again. It should fail with a
forbidden error.

Measure how long the change takes to bite. It will not be instant, because the
identity is holding a cached token.

> **Why measure it:** "Revoked access" and "revoked access, effective in up to N
> minutes" are different security properties. If you are ever asked how fast you
> can cut off a compromised workload, the honest answer includes that number.

Put the role assignment back and confirm it recovers.

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `grant_app_identity = false` and re-apply to remove the role assignment
without touching anything else - that is Step 8 without any manual portal work.

Terraform deliberately does not create the secret: with public access disabled it
cannot reach the data plane, and pretending otherwise would mean weakening the
vault to build it.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | The vault uses the Azure RBAC permission model |
| 2 | The vault has no legacy access policies |
| 3 | Public network access is `Disabled` and the network ACL default action is `Deny` |
| 4 | An approved private endpoint exists with sub-resource `vault` |
| 5 | `privatelink.vaultcore.azure.net` exists, is linked to the VNet, and resolves the vault privately |
| 6 | A secret-reading role is assigned to a managed identity at the vault scope |
| 7 | No user principal holds a secret-reading role at the vault scope |
| 8 | No principal holds `Key Vault Administrator` at the vault scope |
| 9 | Soft delete is enabled with at least 7 days retention |
| 10 | (Optional, with `-VmName`) The VM resolves the vault hostname to the private address |
| 11 | (Optional, with `-PublicProbe`) The vault endpoint is not usable from the internet |

---

## Validation Script

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab06 -VnetName vnet-lab06 -KeyVaultName kv-lab06-abc123
```

Add `-VmName vm-app` and `-PublicProbe` for the two optional checks.

---

## Follow-Up Questions

No answers here on purpose.

1. `Contributor` on the vault cannot read a secret under RBAC. Describe the exact
   sequence of steps a Contributor could take to read one anyway, and what you
   would put in place to detect it.
2. Access policies are invisible to access reviews. What else in Azure grants
   access without producing a role assignment, and how would you find those?
3. You removed the role assignment and the application kept working for a while.
   What exactly was still valid, where was it cached, and what is the maximum
   window?
4. Roles can be scoped to an individual secret. Why is that rarely done in
   practice, and what would you need in place before it became practical?
5. The vault has soft delete on. Who can purge a soft-deleted vault, and what does
   that mean for an attacker who has Contributor on the resource group?
6. Your application reads the secret at startup. What is your plan for the moment
   the secret is rotated - and does that plan need a role you have not assigned?
7. The private endpoint means the vault is unreachable from your CI pipeline. How
   should a deployment pipeline get secrets into an application here, and which of
   the obvious answers quietly recreates the problem you just solved?

---

## Clean Up

```bash
az group delete -n rg-lab06 --yes --no-wait
```

---

[Back to the catalogue](../../README.md)
