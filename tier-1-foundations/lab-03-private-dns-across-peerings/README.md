# Lab 03: Private DNS Resolution Across Peered Networks

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Three peered virtual networks each contain private endpoints for different
services. Every workload in every network must resolve every private endpoint
correctly, using a single set of private DNS zones. No workload may fall back to
public resolution. Demonstrate what breaks when a virtual network link is missing.

---

## What You Will Learn

- **DNS and routing are different jobs.** Peering answers "can I get there". DNS
  answers "what address do I send to". This lab is entirely the second one.
- **A private DNS zone is a private address book.** It overrides the public answer
  for machines in your networks so they get the `10.x` private endpoint address.
  Same name, different answer depending on who asks - split-horizon DNS.
- **Two connections must exist, and neither is automatic.** The endpoint's *DNS
  zone group* writes the record into the zone. The zone's *virtual network link*
  makes the zone visible to a network. Miss either and you silently fall back to
  the public address.
- **Peering does not carry DNS.** Every network needs its own link to every zone.
  Three networks times three zones is **nine** links, not three.
- **This failure looks like success.** If the target still allows public access,
  the client just connects over the internet. No error, no alert. Check the
  resolved *address*, not whether resolution worked.
- **Zone names are fixed by Azure.** Key Vault's public name is `vault.azure.net`
  but its private zone is `vaultcore.azure.net`. That one catches everybody.

---

## Reference Architecture

```
  vnet-a 10.0.0.0/16          vnet-b 10.1.0.0/16          vnet-c 10.2.0.0/16
  +-------------------+       +-------------------+       +-------------------+
  | snet-workload     |       | snet-workload     |       | snet-workload     |
  |   [ vm-a ]        |       |   [ vm-b ]        |       |   [ vm-c ]        |
  | snet-pe           |       | snet-pe           |       | snet-pe           |
  |   [ pe-storage ]  |       |   [ pe-kv ]       |       |   [ pe-sql ]      |
  +-------------------+       +-------------------+       +-------------------+
          |     \                    /     |      \             /     |
          |      \___ peering ______/      |       \_ peering _/      |
          |            (full mesh, 3 peerings / 6 directional links)  |
          |                               |                          |
          +-------------------------------+--------------------------+
                                          |
                    All three VNets use Azure-provided DNS
                    (no custom DNS servers configured)
                                          |
                       rg-lab03-dns: one set of zones
             privatelink.blob.core.windows.net    -> A: stgxxxx -> 10.0.2.4
             privatelink.vaultcore.azure.net      -> A: kvxxxx  -> 10.1.2.4
             privatelink.database.windows.net     -> A: sqlxxxx -> 10.2.2.4

             Each zone linked to vnet-a, vnet-b AND vnet-c  = 9 links
```

---

## Build Instructions

Build this yourself first. The finished Terraform is in [`solution/`](solution/)
to compare against afterwards.

### Step 1 - Create two resource groups

Create **`rg-lab03`** for the networks, endpoints and services, and
**`rg-lab03-dns`** for the private DNS zones.

> **Why two:** DNS zones are shared infrastructure used by all three networks. If
> they live inside one application's resource group, deleting that application
> takes name resolution away from the other two. Separating shared platform state
> from application state is a habit worth building early.

### Step 2 - Create three virtual networks

| VNet name | Address space | Subnet | Prefix | Subnet | Prefix |
| --- | --- | --- | --- | --- | --- |
| `vnet-a` | `10.0.0.0/16` | `snet-workload` | `10.0.1.0/24` | `snet-pe` | `10.0.2.0/24` |
| `vnet-b` | `10.1.0.0/16` | `snet-workload` | `10.1.1.0/24` | `snet-pe` | `10.1.2.0/24` |
| `vnet-c` | `10.2.0.0/16` | `snet-workload` | `10.2.1.0/24` | `snet-pe` | `10.2.2.0/24` |

**Leave the DNS settings alone.** Every network must keep Azure-provided DNS.

> **Why separate workload and endpoint subnets:** Keeping private endpoints in
> their own subnet means you can apply different NSG rules to them later, and it
> makes the address plan readable at a glance.

> **Why you must not set a custom DNS server:** Private DNS zones only work
> through Azure's built-in resolver at `168.63.129.16`. The moment you point a
> network at your own DNS server instead, your private zones stop applying to
> those machines. If you ever do need custom DNS - and in a real hybrid setup you
> will - that server has to forward to `168.63.129.16` or nothing private
> resolves. That is Lab 15.

### Step 3 - Peer the three networks in a full mesh

Create **six** peerings - every network to every other network, both directions:

`vnet-a` to `vnet-b`, `vnet-b` to `vnet-a`, `vnet-a` to `vnet-c`,
`vnet-c` to `vnet-a`, `vnet-b` to `vnet-c`, `vnet-c` to `vnet-b`.

> **Why a full mesh here:** This lab is about DNS, not routing, so give every
> network direct IP connectivity to every other one. That removes routing as a
> possible cause when something does not work, leaving DNS as the only variable.

> **Why six and not three:** A peering is one-directional. Each connection is two
> separate objects, and both must exist before the link reports `Connected`.

### Step 4 - Create the three private DNS zones

In **`rg-lab03-dns`**, create three zones with exactly these names:

- **`privatelink.blob.core.windows.net`** (for blob storage)
- **`privatelink.vaultcore.azure.net`** (for Key Vault)
- **`privatelink.database.windows.net`** (for Azure SQL)

> **Why these names:** They are not chosen by you. Each Azure service publishes
> one specific private link zone name and the private endpoint integration only
> works with that name. Note the Key Vault one especially - the public name is
> `vault.azure.net` but the private zone is `vaultcore.azure.net`. It catches
> everyone once.

### Step 5 - Link every zone to every network

Create **nine** virtual network links - each of the three zones linked to each of
the three networks. Name them consistently, for example `link-vnet-a`,
`link-vnet-b`, `link-vnet-c` within each zone.

Set **registration to disabled** on every one.

> **Why nine:** This is the arithmetic people get wrong. A link makes one zone
> visible to one network. Three zones seen by three networks is three times three.
> Peering does not shortcut it - if `vnet-c` is not linked to the blob zone, then
> machines in `vnet-c` do not get private answers for blob storage, no matter how
> well peered they are.

> **Why registration disabled:** Registration means "automatically create a DNS
> record for every VM in this network". You do not want that here, and a zone can
> only have one registration link - leaving it enabled makes the second and third
> links fail.

### Step 6 - Create the three services, each with public access turned off

| Service | Name | Extra configuration |
| --- | --- | --- |
| Storage account | `stglab03<unique>` | public network access disabled, blob public access disabled |
| Key Vault | `kv-lab03-<unique>` | RBAC authorization enabled, public network access disabled |
| SQL logical server | `sql-lab03-<unique>` | public network access disabled |

All three names have to be globally unique because they form public DNS names.

> **Why disable public access:** It makes the failure in Step 10 visible. With
> public access left on, a machine that resolves the public address still connects
> successfully and you learn nothing. With it off, the wrong answer produces an
> immediate, obvious error - which is the whole point of the exercise.

### Step 7 - Create one private endpoint per network, each with a DNS zone group

| Endpoint name | In network | In subnet | Targets | Sub-resource | DNS zone |
| --- | --- | --- | --- | --- | --- |
| `pe-storage` | `vnet-a` | `snet-pe` | the storage account | `blob` | `privatelink.blob.core.windows.net` |
| `pe-kv` | `vnet-b` | `snet-pe` | the Key Vault | `vault` | `privatelink.vaultcore.azure.net` |
| `pe-sql` | `vnet-c` | `snet-pe` | the SQL server | `sqlServer` | `privatelink.database.windows.net` |

Each one **must** have a private DNS zone group attached.

> **Why deliberately spread across three networks:** So that no network can resolve
> everything by accident. Each network hosts one endpoint and must rely on the
> zone links to resolve the other two. If the links are wrong, exactly two of the
> three lookups break on each machine - and that pattern tells you immediately
> that DNS, not routing, is at fault.

> **Why the zone group is the critical piece:** It is the only thing that writes
> the A record. Skip it and you have a private endpoint with a working private IP
> that nothing on earth resolves to.

### Step 8 - Deploy one VM per network

Create **`vm-a`**, **`vm-b`** and **`vm-c`** in the `snet-workload` subnet of their
respective networks, with **no public IP**. Add Bastion in one network if you want
interactive access, or just use the run-command feature to execute lookups
remotely.

### Step 9 - Prove every machine resolves every endpoint privately

From each of the three VMs, look up all three service names. Nine lookups in
total. Every single answer must be a `10.x` address.

A correct answer looks like a CNAME to the `privatelink` name followed by a
private A record:

```
stglab0312345.blob.core.windows.net
        canonical name = stglab0312345.privatelink.blob.core.windows.net.
Name:   stglab0312345.privatelink.blob.core.windows.net
Address: 10.0.2.4
```

If you get a public address - typically starting `20.` or `52.` - that machine's
network is not linked to that zone.

### Step 10 - Break it deliberately and watch what happens

Delete **one** link: `vnet-c`'s link to `privatelink.blob.core.windows.net`.

Now repeat the storage lookup from all three VMs.

`vm-a` and `vm-b` still get the private address. `vm-c` now gets the **public**
address. Three things are worth noticing, and they are the real lesson:

- **Connectivity is completely unaffected.** `vnet-c` is still peered to `vnet-a`
  and can still reach `10.0.2.4` perfectly well. The road is fine. Only the
  address book is wrong.
- **Nothing reports an error anywhere.** The zone is healthy. The endpoint is
  healthy. The peering is healthy. No alert fires, no deployment fails, no policy
  is violated.
- **How bad it looks depends entirely on the target's public access setting.**
  Because you disabled public access in Step 6, `vm-c` now gets a connection
  error and you find it in seconds. Had you left public access on, `vm-c` would
  have connected happily over the internet and you would have found out months
  later.

Then put the link back and confirm resolution recovers, without touching the
private endpoint at all.

> **How this is prevented in production:** an Azure Policy with a
> `deployIfNotExists` effect that attaches the correct DNS zone group to every
> private endpoint automatically, plus a `Deny` policy on virtual networks
> configured with unapproved custom DNS servers. That is Lab 14 and Lab 22.

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform plan
terraform apply
```

To reproduce Step 10 without editing anything by hand, set
`break_vnet_c_blob_link = true` in `terraform.tfvars` and apply again. Set it back
to `false` to repair it.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | All three virtual networks exist |
| 2 | The three VNets are peered in a full mesh, and every peering is `Connected` |
| 3 | Every VNet uses Azure-provided DNS - no custom DNS servers configured |
| 4 | All three private DNS zones exist, with the exact private link zone names |
| 5 | Each zone is linked to all three VNets - nine links in total |
| 6 | Every VNet link has registration disabled |
| 7 | Every private endpoint has a DNS zone group attached |
| 8 | Every private endpoint connection is in the `Approved` state |
| 9 | Each zone holds an A record whose address matches its private endpoint's NIC address |
| 10 | Every A record resolves to a private (RFC 1918) address |
| 11 | (Optional, with `-LiveDnsTest`) Every VM resolves all three service names to private addresses |

---

## Validation Script

[`validate.ps1`](validate.ps1) checks every criterion above. Criteria 1 to 10 are
read-only. Criterion 11 runs a name lookup inside your VMs via
`az vm run-command invoke` - it changes nothing, but it does need the VMs running
and takes a minute or two.

```bash
pwsh ./validate.ps1
```

It prompts for the resource groups and the three VNet names, and discovers the
private endpoints and zones itself. To run the live lookups as well:

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab03 -DnsResourceGroup rg-lab03-dns `
  -VnetNames vnet-a,vnet-b,vnet-c `
  -LiveDnsTest -VmNames vm-a,vm-b,vm-c
```

After breaking a link in Step 10, re-run it - criterion 5 fails and names the
exact missing link.

---

## Follow-Up Questions

No answers here on purpose. Each one is a real thing you will be asked eventually.

1. When you deleted vnet-c's blob zone link, `vm-c` started resolving the public
   address - but vnet-c is still peered to vnet-a and can still reach `10.0.2.4`
   perfectly well. So what exactly is the client doing wrong, and at which layer?
2. Nothing in Azure reported an error while that link was missing. What signal
   could you have collected that would have caught it, and where would it have to
   come from?
3. The private endpoint writes its record into the zone once, at creation time,
   rather than the zone querying the endpoint on demand. Why build it that way,
   and what happens to that record if the endpoint's private IP ever changes?
4. A zone accepts only one registration-enabled link. Why would that restriction
   exist, and what would break if two networks both auto-registered their VMs into
   the same zone?
5. If you pointed all three VNets at your own DNS server instead of Azure's
   resolver, what would you have to configure on that server for private endpoints
   to keep working - and why can you not simply give it a copy of the zone?
6. The storage account's public name resolves to a CNAME chain ending in
   `privatelink.blob.core.windows.net`. Who created that CNAME, and why does that
   design mean you never have to change your application's connection string?
7. All three endpoints here are in the same subscription. If `vnet-c` belonged to
   a different team in a different subscription, who would own the zone, who would
   own the link, and where would that hand-off go wrong first?

---

## Clean Up

```bash
az group delete -n rg-lab03 --yes --no-wait
az group delete -n rg-lab03-dns --yes --no-wait
```

Or `terraform destroy`. Delete the application group first if you are doing it by
hand - a private DNS zone cannot be deleted while virtual network links still
reference it.

---

[Back to the catalogue](../../README.md)
