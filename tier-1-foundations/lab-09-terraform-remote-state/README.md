# Lab 09: Terraform Remote State Done Properly

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Configure Terraform remote state in Azure Storage with state locking, versioning,
and soft delete. The pipeline identity must have the minimum permissions needed
to read and write state and nothing more. No storage account key may exist
anywhere in the configuration. Simulate two concurrent applies and show the lock
holding.

---

## What You Will Learn

- **State is the most dangerous file you own.** It records what exists, and it
  contains every value Terraform touched - including passwords and keys, in clear
  text. Treat it as a secret store, because it is one.
- **Locking prevents two applies from corrupting each other.** The Azure backend
  does it with a blob lease: the first apply takes the lease, the second waits.
  You configure nothing - but you must not break it.
- **Versioning is your undo button.** A corrupted or truncated state file is
  recoverable if every write kept the previous version. Without it, it is not.
- **Soft delete covers the case versioning does not** - somebody deleting the blob
  or the container outright.
- **Account keys and least privilege are incompatible.** A key is all-or-nothing
  and identifies nobody. Entra authentication plus one narrow role assignment is
  the difference between "the pipeline can write its state file" and "the pipeline
  can do anything to this storage account".
- **Scope the role to the container, not the account.** One pipeline, one
  container, one grant.

---

## Reference Architecture

```
  rg-lab09-tfstate
  +-----------------------------------------------------------+
  |  storage account  stgtfstate09xxxx                        |
  |    versioning ................ enabled                    |
  |    blob soft delete .......... 30 days                    |
  |    container soft delete ..... 30 days                    |
  |    shared key access ......... DISABLED                   |
  |    minimum TLS ............... 1.2, HTTPS only            |
  |                                                           |
  |    container: tfstate                                     |
  |       ^                                                   |
  |       |  Storage Blob Data Contributor                    |
  |       |  scoped to the CONTAINER, not the account         |
  |       |                                                   |
  |  [ id-tfstate-pipeline ]  user-assigned identity          |
  +-----------------------------------------------------------+

  backend "azurerm" { use_azuread_auth = true }   <- no key anywhere
```

---

## Build Instructions

### Step 1 - Create the state resource group

Create **`rg-lab09-tfstate`**.

> **Why its own resource group:** State outlives the things it describes. Putting
> it in the same group as the workload means one over-enthusiastic cleanup takes
> the record of what exists along with the things themselves.

### Step 2 - Create the storage account

Create **`stgtfstate09<unique>`** with:

| Setting | Value |
| --- | --- |
| Allow shared key access | **Disabled** |
| Minimum TLS version | **1.2** |
| HTTPS traffic only | **Enabled** |
| Blob versioning | **Enabled** |
| Blob soft delete | **30 days** |
| Container soft delete | **30 days** |
| Anonymous blob access | **Disabled** |

> **Why versioning matters more here than anywhere else:** Terraform overwrites
> the whole state file on every apply. If an apply is interrupted at the wrong
> moment, or somebody runs one from a stale checkout, the file you end up with can
> describe an estate that does not exist. With versioning, you restore the
> previous version. Without it, you rebuild state by hand, resource by resource.

> **Why both soft deletes:** Versioning protects the contents of a blob. It does
> nothing if somebody deletes the blob, and nothing at all if somebody deletes the
> container. Those are two separate settings.

### Step 3 - Create the container

Create a container named **`tfstate`**.

### Step 4 - Create the pipeline identity

Create a user-assigned managed identity named **`id-tfstate-pipeline`**.

> **Why a managed identity and not a service principal with a secret:** A secret
> has to be stored somewhere, rotated, and eventually leaked. A managed identity
> has no credential you can copy. Wiring it to a pipeline running outside Azure is
> Lab 10.

### Step 5 - Grant it exactly one role, at the container scope

Assign **`Storage Blob Data Contributor`** to `id-tfstate-pipeline`, scoped to
the **`tfstate` container** - not the storage account, not the resource group.

Assign nothing else.

> **Why this exact role:** Reading and writing the state blob needs read and write
> on blob data. Taking and releasing the lock needs the lease permissions, which
> that role also includes. `Storage Blob Data Reader` cannot write; `Storage Blob
> Data Owner` adds permissions to change other people's access. Contributor is the
> smallest role that does the job.

> **Why container scope:** An assignment at account scope covers every container
> that will ever exist there, including other teams' state files. The container is
> the natural boundary and it costs nothing extra to use it.

> **Why not `Contributor` on the resource group:** That role cannot read a blob,
> but it can read the account keys - and with keys enabled it would sidestep all of
> this. Keys are disabled here, which is what makes the narrow grant meaningful.

### Step 6 - Point Terraform at it, with no key

Your backend block should look like this - note what is *not* in it:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-lab09-tfstate"
    storage_account_name = "stgtfstate09xxxx"
    container_name       = "tfstate"
    key                  = "workload.tfstate"
    use_azuread_auth     = true
  }
}
```

No `access_key`. No `sas_token`. No connection string. No `ARM_ACCESS_KEY`
environment variable.

> **Why `use_azuread_auth = true` is the whole point:** It tells the backend to
> authenticate with whatever Entra identity is running Terraform - your `az login`
> locally, the managed identity in a pipeline. That is what makes the role
> assignment in Step 5 the thing controlling access, rather than decoration around
> a key that grants everything anyway.

> **Note on the `key` argument:** confusingly, `key` here means the *name of the
> blob*, not a credential. It is the file name your state is stored under.

### Step 7 - Show the lock holding

Start an apply that takes a while - one that creates something slow, or add a
deliberate delay. While it is running, start a second apply from another terminal
against the same state.

The second one will report that state is locked, name the lock ID, the operation,
who holds it and when it was acquired, and then wait.

> **Why this works with no configuration:** The backend takes a lease on the state
> blob before writing. A lease is exclusive - Azure Storage will not grant a second
> one. The second Terraform sees the conflict and backs off. You never configured
> locking, but you can certainly break it: a role without lease permissions, or a
> tool that writes the blob directly, and two applies will happily interleave.

Then try `terraform force-unlock`, understand what it does, and decide when you
would ever use it.

### Step 8 - Prove versioning saved you

Overwrite the state blob with rubbish. Then list its versions and restore the
previous one. Confirm `terraform plan` is clean again.

> **Why do this deliberately once:** So that the first time it happens for real,
> at speed, under pressure, it is a procedure you have already run rather than one
> you are reading about.

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

This one bootstraps with **local state**, which is correct: something has to
create the state store before there is a state store to use. In a real estate you
create this once, by hand or from a bootstrap pipeline, and never touch it again.

Terraform prints the exact backend block to paste into your next project.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | Blob versioning is enabled on the storage account |
| 2 | Blob soft delete is enabled with at least 7 days retention |
| 3 | Container soft delete is enabled with at least 7 days retention |
| 4 | Shared key access is disabled |
| 5 | HTTPS-only traffic is enforced and minimum TLS is 1.2 |
| 6 | The state container exists |
| 7 | The pipeline identity holds `Storage Blob Data Contributor` scoped to the container |
| 8 | The pipeline identity holds no role at account, resource group or subscription scope that can read keys |
| 9 | No account key, SAS token or connection string appears in any `.tf`, `.tfvars`, `.yml` or `.yaml` file under the scanned path |

---

## Validation Script

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab09-tfstate `
  -StorageAccountName stgtfstate09abc123 -IdentityName id-tfstate-pipeline
```

Criterion 9 scans files. By default it scans the lab folder; point it at your own
repository with `-ScanPath ../../my-infra`.

---

## Follow-Up Questions

No answers here on purpose.

1. State contains every value Terraform touched, in clear text, including
   passwords. Given that, what is the real difference between "who can read this
   container" and "who can read every secret in the estate"?
2. Locking uses a blob lease. What happens to that lease if the machine running
   Terraform loses power mid-apply, and how long before somebody else can proceed?
3. `terraform force-unlock` exists. Describe a situation where using it is correct,
   and one where it destroys a day of work.
4. Your pipeline identity can write the state blob. Can it read *other* state
   files in the same account? Prove your answer from the role assignment rather
   than assuming.
5. Shared key access is disabled, so the backend uses Entra. What breaks if the
   pipeline runs in a different tenant, or from a machine with no Azure identity at
   all?
6. This storage account is reachable from the internet. What would it take to put
   it behind a private endpoint, and what would that do to a hosted CI runner?
7. Somebody asks you to store state for forty teams. Do they share one account,
   one container each, or one account each - and what specifically drives that
   decision?

---

## Clean Up

```bash
az group delete -n rg-lab09-tfstate --yes --no-wait
```

Note that soft delete and versioning mean deleted blobs are retained and billed
for the retention period, and the account name stays reserved.

---

[Back to the catalogue](../../README.md)
