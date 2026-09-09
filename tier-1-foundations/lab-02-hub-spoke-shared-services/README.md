# Lab 02: Hub and Spoke with a Shared Services Spoke

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Build a hub virtual network with two spokes, one for application workloads and
one for shared services. Spokes must reach shared services and the hub, but must
never reach each other directly. Prove the isolation with a connectivity test in
both directions. Document why peering alone does not give you transitive routing.

---

## What You Will Learn

- **Hub and spoke** means one small central network for shared things (firewall,
  gateways, DNS) and one network per workload. It keeps blast radius small.
- **Peering joins exactly two networks.** A peered to B and B peered to C does
  *not* let A reach C. Peering is non-transitive - it shares only the peer's own
  address range, nothing beyond it.
- **Routing decides where a packet goes.** If a destination is not in a subnet's
  effective routes, the packet follows the default route to the internet and
  dies. Route tables (UDRs) are how you add entries.
- **A route on its own is not enough.** Something in the hub has to receive the
  packet and forward it - a firewall or an appliance. Three things must all be
  true: the route, the device, and `allowForwardedTraffic` on the peering.
- **Return traffic needs the same path.** Route one direction through the firewall
  and it sees half a conversation and drops it. That is asymmetric routing.
- **Firewalls deny by default.** The isolation here comes from the rule you do
  *not* write.

---

## Why Peering Alone Gives You Nothing Transitive

Worth writing out properly, because the lab asks you to document it.

When you peer the hub to the app spoke, Azure adds routes for the hub's address
range into the app spoke's effective route table, with next hop `VNetPeering`, and
does the mirror image on the hub side. That is the whole feature. It injects the
**peer's own prefixes**, not the prefixes of everything that peer happens to be
connected to.

So the app spoke learns `10.0.0.0/16` (the hub) and nothing else. It never learns
`10.2.0.0/16` (the shared spoke), because that range does not belong to the hub. A
packet addressed to `10.2.1.4` matches no specific route, falls through to the
default `0.0.0.0/0` route, heads for the internet, and is dropped.

To fix it you need all three of these:

| Mechanism | What happens without it |
| --- | --- |
| A route table sending the other spoke's range to the firewall | The packet follows the default route to the internet and dies |
| A firewall or appliance in the hub | Nothing picks the packet up and forwards it onward |
| `allowForwardedTraffic` on the peering | The destination spoke drops the packet, because its source address is not the hub's own range |

That third one is the subtle one. By default a peering only accepts traffic that
*originated* in the peer network. Traffic that the peer is merely passing along on
someone else's behalf is rejected unless you have explicitly allowed forwarded
traffic.

---

## Reference Architecture

```
  vnet-hub 10.0.0.0/16
  +-------------------------------------------------+
  |  AzureFirewallSubnet 10.0.1.0/26                 |
  |    [ afw-hub ]  private IP 10.0.1.4              |
  |  AzureBastionSubnet 10.0.2.0/26                  |
  +-------------------------------------------------+
        ^                              ^
        | peering                      | peering
        | (allow forwarded traffic)    | (allow forwarded traffic)
        v                              v
  vnet-spoke-app 10.1.0.0/16     vnet-spoke-shared 10.2.0.0/16
  +------------------------+     +---------------------------+
  | snet-app 10.1.1.0/24   |     | snet-shared 10.2.1.0/24   |
  |   [ vm-app ]           |     |   [ vm-shared ]           |
  |   route: 10.2.0.0/16   |     |   route: 10.1.0.0/16      |
  |          -> 10.0.1.4   |     |          -> 10.0.1.4      |
  +------------------------+     +---------------------------+

           NO peering between the two spokes

  Firewall rules:
    Allow  10.1.0.0/16 -> 10.2.0.0/16  TCP 443, 3389, 22
    (nothing for the reverse direction, so the default deny applies)
```

---

## Build Instructions

Build this yourself first. The finished Terraform is in [`solution/`](solution/)
to compare against afterwards.

### Step 1 - Create the resource group

Create a resource group named **`rg-lab02`**.

> **Why:** One delete boundary for the lab. Azure Firewall bills by the hour, so
> being able to remove everything in one command matters.

### Step 2 - Create the hub virtual network

Create a virtual network named **`vnet-hub`** with address space **`10.0.0.0/16`**
and two subnets:

| Subnet name | Address prefix | Extra configuration |
| --- | --- | --- |
| `AzureFirewallSubnet` | `10.0.1.0/26` | name must be exactly this, and /26 is the minimum size |
| `AzureBastionSubnet` | `10.0.2.0/26` | name must be exactly this |

> **Why the hub exists at all:** Anything shared by more than one application
> belongs here - firewall, gateways, DNS. Put it in the hub once instead of once
> per spoke, and you have a single place to inspect and control traffic.

> **Why the subnet names are fixed:** Azure Firewall and Bastion are managed
> services that Azure deploys into your network on your behalf. They look for
> those exact names. Anything else and deployment fails.

### Step 3 - Create the two spoke virtual networks

| VNet name | Address space | Subnet | Subnet prefix |
| --- | --- | --- | --- |
| `vnet-spoke-app` | `10.1.0.0/16` | `snet-app` | `10.1.1.0/24` |
| `vnet-spoke-shared` | `10.2.0.0/16` | `snet-shared` | `10.2.1.0/24` |

> **Why the address ranges must not overlap:** Two networks with the same range
> cannot be peered, and even if they could, routing would be ambiguous. Plan
> address space before you build anything - reworking it later means rebuilding
> every subnet.

### Step 4 - Peer each spoke to the hub, and only to the hub

Create **four** peerings. Peering is directional, so each connection is two
separate objects that both have to exist:

| Name | From | To | Extra configuration |
| --- | --- | --- | --- |
| `hub-to-app` | `vnet-hub` | `vnet-spoke-app` | allow forwarded traffic |
| `app-to-hub` | `vnet-spoke-app` | `vnet-hub` | allow forwarded traffic |
| `hub-to-shared` | `vnet-hub` | `vnet-spoke-shared` | allow forwarded traffic |
| `shared-to-hub` | `vnet-spoke-shared` | `vnet-hub` | allow forwarded traffic |

**Do not** create a peering between the two spokes. That absence is the whole
requirement.

> **Why "allow forwarded traffic":** By default a network only accepts packets
> from a peer if the packet came from the peer's own address range. Once the
> firewall starts relaying packets that originated in the other spoke, the
> destination sees a source address that does not belong to the hub and rejects
> them. This setting says "accept traffic my peer is passing along for someone
> else".

### Step 5 - Look at the effective routes before you fix anything

Deploy a small Linux VM in each spoke - **`vm-app`** in `snet-app` and
**`vm-shared`** in `snet-shared` - with **no public IP** on either. Deploy
**Azure Bastion** in the hub so you can sign in to them.

Now look at the effective routes on `vm-app`'s network interface, in the portal or
with `az network nic show-effective-route-table`.

You will see a route for `10.0.0.0/16` via `VNetPeering`, a route for
`10.1.0.0/16` via `VnetLocal`, and a `0.0.0.0/0` route to the internet. There is
**no route for `10.2.0.0/16`**. That single missing line is the entire lesson -
save a screenshot of it for your write-up.

> **Why look before fixing:** Understanding the failure is the point of the lab.
> If you deploy the firewall first, you never see the broken state and you learn
> the recipe instead of the reason.

### Step 6 - Deploy Azure Firewall in the hub

Create:

- A **Standard** SKU public IP named **`pip-afw`** with static allocation
- An **Azure Firewall** named **`afw-hub`**, SKU `AZFW_VNet`, tier **Standard**,
  with its IP configuration in `AzureFirewallSubnet` and using `pip-afw`

Note down the firewall's **private** IP address - it will be `10.0.1.4`. You need
it for the route tables.

> **Why a firewall and not just routes:** A route only says where to send a
> packet. Something has to actually receive it and send it onward. The firewall
> is that something, and it also gives you the inspection point and the logs.

> **Cost warning:** Azure Firewall Standard costs roughly a pound an hour plus
> data charges, whether you use it or not. If you would rather not pay that, you
> can substitute a small Linux VM in the hub with IP forwarding enabled on its
> network interface and `net.ipv4.ip_forward=1` in the guest. Everything else in
> this lab is identical. The validation script supports either.

### Step 7 - Force spoke-to-spoke traffic through the firewall

Create two route tables:

| Route table | Route name | Address prefix | Next hop type | Next hop IP | Associate with |
| --- | --- | --- | --- | --- | --- |
| `rt-app` | `to-shared` | `10.2.0.0/16` | Virtual appliance | `10.0.1.4` | `snet-app` |
| `rt-shared` | `to-app` | `10.1.0.0/16` | Virtual appliance | `10.0.1.4` | `snet-shared` |

> **Why the shared spoke needs one too:** It never starts a conversation, so it
> feels unnecessary. But when it *replies* to the app spoke, that reply has to go
> back through the same firewall. If it takes the peering route instead, the
> firewall only ever sees one direction of the conversation and drops it. This is
> asymmetric routing, and it produces intermittent, confusing failures.

> **Never put a route table on `AzureFirewallSubnet`.** The firewall would end up
> routing its own traffic through itself. Leave that subnet on system routes.

### Step 8 - Write the firewall rules, in one direction only

Create a network rule collection named **`spoke-to-shared`**, priority **200**,
action **Allow**, containing one rule named `app-to-shared`:

| Setting | Value |
| --- | --- |
| Source addresses | `10.1.0.0/16` |
| Destination addresses | `10.2.0.0/16` |
| Destination ports | 443, 3389, 22 |
| Protocols | TCP |

Do **not** create any collection allowing `10.2.0.0/16` to reach `10.1.0.0/16`.

Optionally add a second collection named **`shared-to-spoke-deny`** at priority
**300**, action **Deny**, covering the reverse direction on all ports.

> **Why an explicit deny is optional:** Azure Firewall already denies anything you
> have not allowed. The traffic is blocked either way. What the explicit deny buys
> you is a clear log entry saying "this was denied by this named rule", instead of
> a generic default-deny entry - which is much easier to explain during an
> incident.

### Step 9 - Prove the isolation in both directions

Sign in to both VMs through Bastion.

- From `vm-app`, connect to `vm-shared` on port 443 - this should **succeed**
- From `vm-shared`, connect to `vm-app` on port 443 - this should **time out**

Then check the *path*, not just the outcome, using Network Watcher's next hop
feature from `vm-app` to `vm-shared`'s address.

- If it says `VirtualAppliance` with the firewall's IP, you built it correctly
- If it says `VNetPeering`, you have a direct spoke-to-spoke peering you did not
  mean to create
- If it says `Internet` or `None`, your route table is not attached to the subnet
  the VM is actually in

> **Why check the path separately:** "It works" and "it works for the reason I
> intended" are different statements. A direct peering would also make the test
> pass, while failing the actual requirement.

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

Set `deploy_firewall = false` in `terraform.tfvars` to build everything except the
firewall, if you want to see the broken state from Step 5 for yourself.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | The hub virtual network exists and contains an `AzureFirewallSubnet` of /26 or larger |
| 2 | Both spoke virtual networks exist |
| 3 | Hub <-> app spoke peering exists in both directions and both are `Connected` |
| 4 | Hub <-> shared spoke peering exists in both directions and both are `Connected` |
| 5 | There is **no** peering of any kind directly between the two spokes |
| 6 | `allowForwardedTraffic` is enabled on the spoke-side peerings so forwarded frames are accepted |
| 7 | A forwarding device (Azure Firewall or an NVA) exists in the hub and its private IP is known |
| 8 | The app spoke subnet has a route table sending the shared spoke prefix to that device as `VirtualAppliance` |
| 9 | The shared spoke subnet has a route table sending the app spoke prefix to that device, so return traffic is symmetric |
| 10 | `AzureFirewallSubnet` has no user-defined route table attached |
| 11 | A firewall rule permits app spoke -> shared spoke |
| 12 | No firewall rule permits shared spoke -> app spoke |
| 13 | (Optional, with VM names) Next hop from an app-spoke VM to a shared-spoke address is `VirtualAppliance`, not `VNetPeering` |
| 14 | (Optional, with VM names) Next hop from a shared-spoke VM to an app-spoke address is `VirtualAppliance`, not `VNetPeering` |

---

## Validation Script

[`validate.ps1`](validate.ps1) checks every criterion above. It is read-only.

```bash
pwsh ./validate.ps1
```

It prompts for the resource group and the three virtual network names. To include
the Network Watcher next-hop checks (criteria 13 and 14), also supply the VM names:

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab02 -HubVnetName vnet-hub `
  -AppSpokeVnetName vnet-spoke-app -SharedSpokeVnetName vnet-spoke-shared `
  -AppVmName vm-app -SharedVmName vm-shared
```

If a spoke has more than one subnet, name the workload subnet explicitly so the
route-table checks look at the right one: `-AppSubnetName snet-app
-SharedSubnetName snet-shared`. Without it the script takes the first subnet that
is not a reserved gateway or firewall subnet.

If you built the hub with an NVA instead of Azure Firewall, pass its private
address so the route checks know what to look for, and criteria 11 and 12 will be
skipped since the rules live inside the appliance:

```bash
pwsh ./validate.ps1 -NvaPrivateIp 10.0.1.4
```

---

## Follow-Up Questions

No answers here on purpose. Each one is a real thing you will be asked eventually.

1. `allowForwardedTraffic` is off by default. What accident or attack is that
   default protecting you from, and what makes it safe to turn on here?
2. You put a route table on both spokes but none on `AzureFirewallSubnet`. Trace
   exactly what would happen to a spoke-to-spoke packet if you added
   `0.0.0.0/0 -> firewall` on the firewall's own subnet.
3. The shared spoke never starts a conversation, so why does it need a route table
   at all? Would removing it fail every single time, or only sometimes - and why
   does that distinction matter for how you would be told about it?
4. Azure Firewall already denies whatever you have not allowed. So what does the
   explicit deny rule actually buy you, and exactly where would you see the
   difference?
5. Adding a fourth spoke tomorrow: how many objects do you create or change, and
   which of them could you get wrong without anything appearing broken until much
   later?
6. Why can two virtual networks with overlapping address space not be peered, when
   the internet routes overlapping RFC 1918 ranges all day long?
7. Your route sends `10.2.0.0/16` to the firewall, and the peering advertises
   `10.0.0.0/16`. If a route table entry and a peering-injected route covered the
   same destination, which one would win, and on what basis?

---

## Clean Up

```bash
az group delete -n rg-lab02 --yes --no-wait
```

Or `terraform destroy`. Azure Firewall bills from the moment it is provisioned.
Delete it the same day.

---

[Back to the catalogue](../../README.md)
