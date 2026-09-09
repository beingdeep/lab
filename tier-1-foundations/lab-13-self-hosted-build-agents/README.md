# Lab 13: Self-Hosted Build Agents Inside a Private Network

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Your build pipelines can no longer reach private resources because hosted agents
run outside your network. Deploy self-hosted agents inside the virtual network,
with autoscaling, no inbound ports, and no long-lived credentials on the agent
machines. Ensure agents can pull tooling from approved sources only.

---

## What You Will Learn

- **Build agents pull work, they do not receive it.** The agent opens an outbound
  connection to the service and holds it. That is why it needs no inbound port at
  all - and why anyone who tells you to open 443 inbound is wrong.
- **A scale set is the right shape for agents.** They are identical, disposable,
  and you want more of them at 9am than at 3am.
- **Egress needs a deliberate exit, not the default one.** Without a NAT gateway
  every instance does its own outbound translation with a small port budget, and
  a busy build fleet exhausts it.
- **"Approved sources only" means naming them.** Service tags let an NSG say
  "Azure DevOps" or "Azure Container Registry" rather than "the internet".
- **Credentials on a build agent are the softest target you own.** An agent runs
  arbitrary code from your repositories. Anything stored on it is readable by any
  pipeline.
- **A private registry is what closes the loop.** Agents that can reach any public
  registry can pull anything; a private endpoint means they can only pull what you
  published.

---

## Reference Architecture

```
  vnet-lab13 10.130.0.0/16
  +----------------------------------------------------------------+
  |  snet-agents 10.130.1.0/24                                     |
  |    [ vmss-agents ]  no public IPs, no inbound rules            |
  |       managed identity, autoscale 1..5                         |
  |         |                                                      |
  |         |  outbound only                                       |
  |         +--> [ nat-lab13 ] --> one predictable egress address  |
  |         |                                                      |
  |         +--> snet-pe 10.130.2.0/24                             |
  |                 [ pe-acr ] --> container registry              |
  |                                public access disabled          |
  +----------------------------------------------------------------+

  nsg-agents
    inbound   nothing allowed at all
    outbound  AzureDevOps, AzureActiveDirectory, AzureContainerRegistry,
              Storage ... then Deny Internet
```

---

## Build Instructions

### Step 1 - Resource group and virtual network

Create **`rg-lab13`** and **`vnet-lab13`** with address space **`10.130.0.0/16`**:

| Subnet name | Address prefix |
| --- | --- |
| `snet-agents` | `10.130.1.0/24` |
| `snet-pe` | `10.130.2.0/24` |

### Step 2 - Create the NAT gateway

Create a Standard public IP **`pip-nat`** and a NAT gateway **`nat-lab13`**,
associated with `snet-agents`.

> **Why a NAT gateway rather than the default outbound:** Without one, each
> instance performs its own outbound translation using a small, fixed allocation
> of source ports. A fleet of agents all pulling packages at once exhausts that
> and you get intermittent connection failures that look like network flakiness.
> A NAT gateway pools a much larger port budget across the whole subnet.

> **Why it also helps security:** All egress leaves from one known address, which
> is what you give a third party that needs to allow-list you.

### Step 3 - Create the container registry, private

Create a **Premium** container registry **`acrlab13<unique>`** with **public
network access disabled**, a private DNS zone **`privatelink.azurecr.io`** linked
to the VNet, and a private endpoint **`pe-acr`** in `snet-pe` with sub-resource
**`registry`**.

> **Why Premium:** Private endpoints are a Premium feature on ACR. Basic and
> Standard cannot have one at all.

> **Why this is part of an agent lab:** "Pull tooling from approved sources only"
> is a supply chain requirement. An agent that can reach Docker Hub can pull
> anything anyone typed into a Dockerfile. An agent that can only reach your
> registry can pull only what you chose to publish. Locking that down properly is
> Lab 21.

### Step 4 - Create the network security group

Create **`nsg-agents`**, associated with `snet-agents`, with:

| Priority | Direction | Action | Source | Destination | Ports |
| --- | --- | --- | --- | --- | --- |
| 100 | Outbound | Allow | any | `AzureActiveDirectory` | 443 |
| 110 | Outbound | Allow | any | `AzureDevOps` | 443 |
| 120 | Outbound | Allow | any | `AzureContainerRegistry` | 443 |
| 130 | Outbound | Allow | any | `Storage` | 443 |
| 140 | Outbound | Allow | any | `VirtualNetwork` | any |
| 4000 | Outbound | Deny | any | `Internet` | any |

Add **no inbound Allow rules at all**.

> **Why no inbound rules:** The agent connects out to the build service and keeps
> that connection open, waiting for work. Nothing ever connects *to* it. If you
> find yourself opening an inbound port, something is wrong with your
> understanding of the model, not with the firewall.

> **Why service tags rather than addresses:** Microsoft publishes and updates the
> address ranges behind each tag. Writing `AzureDevOps` means your rule keeps
> working when those ranges change, which they do, without notice.

> **Why `Storage` is on the list:** Build artefacts, caches and logs go to storage
> endpoints. Leave it out and your builds fail in ways that look nothing like a
> network problem.

### Step 5 - Deploy the scale set

Create **`vmss-agents`** in `snet-agents` with:

| Setting | Value |
| --- | --- |
| Public IP per instance | **none** |
| Password authentication | **disabled** |
| Identity | system-assigned managed identity |
| Instances | 1 to start |

> **Why no password:** A build agent executes code from your repositories. Any
> credential on the machine is readable by any pipeline that runs on it. The
> managed identity is not stored on disk - it is issued by the platform, scoped,
> and short-lived.

> **Why this matters more here than on an ordinary VM:** A normal VM runs your
> code. A build agent runs everybody's code, including whatever arrived in a pull
> request this morning.

### Step 6 - Grant the identity access to the registry

Assign **`AcrPull`** to the scale set's managed identity, scoped to the registry.

Nothing else.

> **Why `AcrPull` and not `Contributor`:** Agents pull images. They do not need to
> push, delete tags, or change the registry's configuration. If your build also
> publishes images, that is a *different* identity used by a *different* pipeline
> stage.

### Step 7 - Add autoscaling

Create an autoscale setting on the scale set: minimum 1, maximum 5, scaling out
on average CPU above 70% and in below 30%.

> **Why scale to 1 and not 0:** A pool with no agents leaves the first build of
> the morning waiting for a machine to boot and register. Whether that is
> acceptable is a real trade-off, and worth deciding deliberately rather than by
> default.

### Step 8 - Register the agents without a stored secret

For Azure DevOps, the modern answer is a **managed identity** granted permission
on the agent pool, so the agent authenticates with a platform-issued token rather
than a personal access token baked into an image or a custom script extension.

Configure that, and then check the machine: there should be no PAT in
`/etc/`, in the agent's `.credentials` file, or in the scale set's custom data.

> **Why this is the hard part:** Every quick-start guide tells you to paste a PAT.
> It works immediately, it expires in a year, it is stored in cleartext on every
> agent, and it usually has far more scope than the agent needs.

### Step 9 - Prove it

- From an agent, pull an image from your registry - should **succeed**
- From an agent, pull an image from Docker Hub - should **fail**
- From an agent, reach any other website - should **fail**
- From outside, try to reach an agent on any port - there should be nothing to
  reach, and no rule permitting it

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `allow_all_egress = true` to remove the outbound restrictions and watch the
agents reach anything at all - which is the state most self-hosted agent fleets
are actually in.

The Terraform does not register the agents with a build service, because that
requires an organisation and a pool. Step 8 stays manual, and deliberately so:
the interesting part is what you do *instead* of pasting a token.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | A scale set exists in the agent subnet with no public IP configuration |
| 2 | The scale set has a managed identity |
| 3 | Password authentication is disabled on the scale set |
| 4 | The agent subnet NSG has no inbound Allow rule from `Internet` or any source |
| 5 | The NSG denies outbound to `Internet` at a priority below 65000 |
| 6 | Every outbound Allow rule names a service tag or the virtual network, never `*` |
| 7 | An autoscale setting targets the scale set, with a maximum above the minimum |
| 8 | The agent subnet egresses through a NAT gateway |
| 9 | The container registry has public network access disabled and an approved private endpoint |
| 10 | `privatelink.azurecr.io` is linked to the VNet and resolves the registry privately |
| 11 | The scale set identity holds `AcrPull` on the registry and no wider role |

---

## Validation Script

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab13 -VnetName vnet-lab13 `
  -ScaleSetName vmss-agents -RegistryName acrlab13abc123
```

---

## Follow-Up Questions

No answers here on purpose.

1. The agent holds a long-poll connection outbound to the build service. What
   does that mean for an NSG that only allows outbound to `AzureDevOps` - which
   direction is the "response" travelling, and why is no inbound rule needed?
2. Service tags update without notice. What happens to a running build at the
   exact moment Microsoft adds a new range to `AzureDevOps`, and what would tell
   you if a tag stopped covering something you rely on?
3. Your agents can reach `Storage` - the whole service tag, every storage account
   in Azure. Is that acceptable for a machine that runs untrusted pull request
   code, and what would you do instead?
4. Autoscale minimum is 1. Work out the cost of minimum 0 versus the delay on the
   first build of the day, and decide which you would defend.
5. The managed identity has `AcrPull`. A pipeline running on the agent can request
   a token for that identity. What else can it reach with it, and how would you
   find out?
6. An agent runs code from any pull request. What stops one pipeline from reading
   another pipeline's working directory, secrets or artefacts on the same machine?
7. You removed the PAT. Where does trust now come from, and what is the failure
   mode when that trust source is unavailable at 8am on a release day?

---

## Clean Up

```bash
az group delete -n rg-lab13 --yes --no-wait
```

A Premium container registry and a NAT gateway both bill by the hour.

---

[Back to the catalogue](../../README.md)
