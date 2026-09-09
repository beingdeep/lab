# Lab 05: Storage Account with No Public Surface

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Create a storage account that serves blobs to an application over a private
endpoint only. Public network access must be disabled, shared key authorisation
must be turned off, and the application must authenticate with a managed
identity. Confirm that the account is unreachable from the internet and that the
portal data browser still works from an authorised network.

---

## What You Will Learn

- **Storage has two front doors: the network and the credential.** Closing one
  does not close the other. A private endpoint does not stop someone with an
  account key; disabling keys does not stop someone on the public endpoint.
- **The account key is a permanent, unattributable superuser.** Anyone holding it
  is the storage account. It has no identity, no expiry and no audit trail worth
  the name. Turning it off is the single biggest improvement in this lab.
- **Control plane and data plane are different permission systems.** Being
  `Contributor` on the account does *not* let you read a blob. It does let you
  read the access keys - which is why leaving keys enabled undoes your data-plane
  RBAC.
- **Data-plane roles are separate roles.** `Storage Blob Data Reader` and
  `Storage Blob Data Contributor` are what actually grant blob access.
- **RBAC applies to you too.** With keys off, the portal's data browser only works
  if *your* account has a data role - and only from a network that can reach the
  account.
- **Disabling public access hides the endpoint, not the name.** The public
  hostname still resolves; it just stops answering.

---

## Reference Architecture

```
  vnet-lab05 10.50.0.0/16
  +---------------------------------------------------------------+
  |  snet-app 10.50.2.0/24                                        |
  |    [ vm-app ]  system-assigned managed identity                |
  |         |                                                     |
  |         |  Entra token -> Storage Blob Data Contributor        |
  |         v                                                     |
  |  snet-pe 10.50.1.0/24                                         |
  |    [ pe-blob ] --> storage account                            |
  |                     public network access .... Disabled       |
  |                     shared key authorisation .. Disabled      |
  |                     anonymous blob access ..... Disabled      |
  |                     default to Entra auth ..... Enabled       |
  |  AzureBastionSubnet 10.50.3.0/26                              |
  +---------------------------------------------------------------+

  privatelink.blob.core.windows.net  -> A: stgxxxx -> 10.50.1.4
```

---

## Build Instructions

### Step 1 - Resource group and virtual network

Create **`rg-lab05`**, and **`vnet-lab05`** with address space **`10.50.0.0/16`**:

| Subnet name | Address prefix |
| --- | --- |
| `snet-pe` | `10.50.1.0/24` |
| `snet-app` | `10.50.2.0/24` |
| `AzureBastionSubnet` | `10.50.3.0/26` |

### Step 2 - Create the private DNS zone first

Create **`privatelink.blob.core.windows.net`** and link it to `vnet-lab05` with
registration disabled.

> **Why first:** So the private endpoint you create in Step 4 registers its record
> automatically. Doing it afterwards means going back and attaching a zone group
> by hand.

### Step 3 - Create the storage account with everything locked down

Create a storage account named **`stglab05<unique>`** (globally unique, lowercase,
no dashes) with:

| Setting | Value |
| --- | --- |
| Public network access | **Disabled** |
| Allow shared key access | **Disabled** |
| Allow blob anonymous access | **Disabled** |
| Default to Entra authorisation | **Enabled** |
| Minimum TLS version | **1.2** |
| Network rules default action | **Deny** |

Then create a container named **`app-data`**.

> **Why disable shared key access:** The account key is a bearer credential that
> grants complete control, never expires, and identifies nobody in the audit log.
> While it is enabled, every data-plane role you assign is advisory - anyone who
> can read the keys bypasses all of it. This one setting is what turns your RBAC
> from decoration into enforcement.

> **Why "default to Entra authorisation" matters:** It changes what the portal and
> tooling reach for first. Without it, tools try the key, fail confusingly, and
> people conclude the lock-down is broken.

> **Why set the network default action to Deny as well as disabling public
> access:** They are separate settings and both appear in audits. Disabling public
> access is the stronger control; the deny default is what remains meaningful if
> someone re-enables public access later.

### Step 4 - Create the private endpoint

Create **`pe-blob`** in `snet-pe`, targeting the storage account, sub-resource
**`blob`**, with a DNS zone group pointing at
`privatelink.blob.core.windows.net`.

> **Why the sub-resource is `blob` and not the account:** One storage account
> exposes blob, file, table, queue and dfs separately. Each needs its own private
> endpoint and its own DNS zone. Picking `blob` gives you blob only - if the app
> later needs file shares, that is a second endpoint.

### Step 5 - Deploy the application VM with a managed identity

Create **`vm-app`** in `snet-app` with **no public IP** and a **system-assigned
managed identity**. Deploy Bastion in `AzureBastionSubnet`.

### Step 6 - Grant the identity a data-plane role

Assign **`Storage Blob Data Contributor`** to `vm-app`'s managed identity, scoped
to the storage account (or, better, to the `app-data` container).

Assign **`Storage Blob Data Reader`** to your own user account as well, so the
portal data browser works.

> **Why not `Contributor`:** `Contributor` is a control-plane role. It lets you
> change the account's settings and read its keys, but grants no blob access at
> all once keys are disabled. People assign it, see access denied, and assume RBAC
> is broken. Data access needs a `Storage Blob Data *` role.

> **Why scope it to the container:** Because you can. A role at account scope
> covers every container that will ever exist on it, including ones created next
> year by someone else.

### Step 7 - Prove it

From `vm-app` over Bastion:

- Resolve the blob endpoint - expect `10.50.1.x`
- List blobs using Entra authentication (`--auth-mode login`) - should succeed
- List blobs using a key - should fail, because there are no keys

From your laptop:

- Request `https://stglab05xxxx.blob.core.windows.net/` - should fail, not serve

In the portal:

- Open the account's data browser from a machine inside the VNet - it should work
  because your user has a data role
- Open it from outside - it should not

> **Why test both directions of failure:** "It is blocked" could mean the network
> is blocked, the credential is rejected, or the name did not resolve. Three
> different causes, three different fixes.

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `allow_shared_key_access = true` to see the hole: your data-plane RBAC is
still there, still correct, and completely bypassable by anyone who can read the
keys.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | The storage account has public network access set to `Disabled` |
| 2 | Shared key authorisation is disabled |
| 3 | Anonymous blob access is disabled and minimum TLS is 1.2 |
| 4 | The account defaults to Entra authorisation |
| 5 | The network rules default action is `Deny` |
| 6 | An approved private endpoint exists with sub-resource `blob` |
| 7 | `privatelink.blob.core.windows.net` exists, is linked to the VNet, and holds an A record resolving to a private address |
| 8 | The application identity holds a `Storage Blob Data` role scoped to the account or a container |
| 9 | No principal holds a key-reading role (`Owner`, `Contributor`, `Storage Account Contributor`) directly at the account scope |
| 10 | (Optional, with `-VmName`) The VM resolves the blob endpoint to the private address |
| 11 | (Optional, with `-PublicProbe`) The blob endpoint is not usable from the internet |

---

## Validation Script

[`validate.ps1`](validate.ps1) checks every criterion above. It is read-only.

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab05 -VnetName vnet-lab05 -StorageAccountName stglab05abc123
```

Add `-VmName vm-app` for the in-VNet resolution check, and `-PublicProbe` to test
the public endpoint from wherever you are running the script.

---

## Follow-Up Questions

No answers here on purpose.

1. With shared key access disabled, what happens to a SAS token that was issued
   yesterday and does not expire until next month? What about a user delegation
   SAS?
2. `Contributor` on the storage account grants no blob access, yet it is enough to
   undo this entire lab. Trace exactly how, and decide what role you would give an
   operations team instead.
3. Public network access is `Disabled`, and the network rules default action is
   `Deny`. One of those is redundant. Which, and under what change does the
   redundant one suddenly become the only thing protecting you?
4. Your private endpoint is for `blob`. What breaks the day the application starts
   using Azure Files or the Data Lake endpoint on the same account, and why does
   it fail with a name resolution error rather than a network error?
5. The portal data browser works from inside the VNet but not outside. Where is the
   request actually coming from when you click through the portal, and why does
   that location matter more than where your browser is?
6. Diagnostic logs for this account have to go somewhere. If that destination is
   another storage account, how do you keep from building the same public surface
   you just removed?
7. Someone needs to give an external partner read access to one container for two
   weeks, with keys disabled. What are your options, and which of them leaves an
   audit trail naming the actual person?

---

## Clean Up

```bash
az group delete -n rg-lab05 --yes --no-wait
```

---

[Back to the catalogue](../../README.md)
