# Lab 04: Three-Tier Segmentation with Application Security Groups

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Deploy a web tier, an application tier, and a database tier in one virtual
network. Traffic must flow only web to app and app to database, never web to
database, and never any tier to the internet inbound. Build the rules with
application security groups rather than IP prefixes. Show that the rules survive
scaling the tiers out.

---

## What You Will Learn

- **An NSG is a stateful firewall attached to a subnet or a NIC.** Rules are
  evaluated lowest priority number first, and the first match wins.
- **Your VNet is wide open by default.** Every NSG has a hidden
  `AllowVnetInBound` rule at priority 65000 that permits *all* traffic between
  anything in the virtual network. Web can reach database until you explicitly
  stop it.
- **An Application Security Group is a label for network cards.** Instead of
  writing rules about `10.40.1.0/24`, you write rules about `asg-web`. Machines
  join the group, and the rules follow them.
- **That is why ASG rules survive scaling.** Add a fifth web server, put its NIC
  in `asg-web`, and every rule already applies. With IP prefixes you would be
  editing rules every time the estate changed.
- **Deny rules must outrank the defaults.** A deny at priority 4000 beats
  `AllowVnetInBound` at 65000. A deny at 65100 would not.
- **Blocking is asymmetric work.** You allow the two paths you want and deny the
  tier you are protecting; you do not enumerate every path you dislike.

---

## Reference Architecture

```
  vnet-lab04 10.40.0.0/16      one NSG (nsg-tiers) on all three subnets
  +------------------------------------------------------------------+
  |  snet-web 10.40.1.0/24    [vm-web-1] [vm-web-2]  --> asg-web      |
  |         |  443                                                    |
  |         v                                                         |
  |  snet-app 10.40.2.0/24    [vm-app-1]             --> asg-app      |
  |         |  1433                                                   |
  |         v                                                         |
  |  snet-db  10.40.3.0/24    [vm-db-1]              --> asg-db       |
  |                                                                   |
  |  AzureBastionSubnet 10.40.4.0/26                                  |
  +------------------------------------------------------------------+

  nsg-tiers inbound rules
    100   Allow  asg-web -> asg-app            TCP 443
    110   Allow  asg-app -> asg-db             TCP 1433
    120   Allow  AzureBastionSubnet -> *       TCP 22, 3389
    4000  Deny   *       -> asg-db             any
    4010  Deny   *       -> asg-app            any
    4020  Deny   Internet -> *                 any
    65000 (built in) AllowVnetInBound          <- the one that would let web
                                                  reach db if you stopped early
```

---

## Build Instructions

Build this yourself. The finished Terraform is in [`solution/`](solution/).

### Step 1 - Create the resource group and virtual network

Create a resource group named **`rg-lab04`**, and a virtual network named
**`vnet-lab04`** with address space **`10.40.0.0/16`** and four subnets:

| Subnet name | Address prefix |
| --- | --- |
| `snet-web` | `10.40.1.0/24` |
| `snet-app` | `10.40.2.0/24` |
| `snet-db` | `10.40.3.0/24` |
| `AzureBastionSubnet` | `10.40.4.0/26` |

> **Why one virtual network and not three:** The requirement is segmentation
> *inside* a network. Splitting into separate VNets would make isolation the
> default and teach you nothing. Real applications usually live in one network
> with tiers separated by rules.

### Step 2 - Create three application security groups

Create **`asg-web`**, **`asg-app`** and **`asg-db`**. They have no settings - an
ASG is just a named group.

> **Why:** An ASG lets a rule say "traffic from the web tier" without knowing any
> addresses. The membership lives on the network cards, so the rules stop caring
> how many machines there are or which subnet they landed in.

### Step 3 - Create one network security group and attach it to all three subnets

Create an NSG named **`nsg-tiers`** and associate it with `snet-web`, `snet-app`
and `snet-db`. Do **not** attach it to `AzureBastionSubnet`.

> **Why one NSG for three subnets:** Because the rules are written in terms of
> ASGs, not subnets, the same rule set is correct everywhere. One NSG means one
> place to read, one place to audit, and no chance of the three drifting apart.

> **Why not on the Bastion subnet:** Bastion manages its own subnet's rules.
> Attaching your NSG there will break it unless you replicate a specific set of
> required rules exactly.

### Step 4 - Write the allow rules

| Priority | Direction | Action | Source | Destination | Protocol | Port |
| --- | --- | --- | --- | --- | --- | --- |
| 100 | Inbound | Allow | ASG `asg-web` | ASG `asg-app` | TCP | 443 |
| 110 | Inbound | Allow | ASG `asg-app` | ASG `asg-db` | TCP | 1433 |
| 120 | Inbound | Allow | `10.40.4.0/26` | any | TCP | 22, 3389 |

Use the **application security group** fields for source and destination, not the
address prefix fields.

> **Why inbound rules only:** NSGs are stateful. Allow the inbound connection to
> the app tier and the reply traffic is permitted automatically - you never write
> the return rule. Writing outbound rules to match is a common beginner habit that
> doubles your rule count for no benefit.

> **Why rule 120 uses an address prefix:** Bastion is a managed service; its
> network cards are not yours and cannot join your ASG. Its subnet range is the
> only handle you have.

### Step 5 - Write the deny rules that actually create the isolation

| Priority | Direction | Action | Source | Destination | Protocol | Port |
| --- | --- | --- | --- | --- | --- | --- |
| 4000 | Inbound | Deny | any | ASG `asg-db` | any | any |
| 4010 | Inbound | Deny | any | ASG `asg-app` | any | any |
| 4020 | Inbound | Deny | `Internet` | any | any | any |

> **Why these are the whole lab:** Without them, the built-in `AllowVnetInBound`
> rule at priority 65000 permits every machine in the virtual network to reach
> every other machine, including web straight to database. Your two allow rules
> at 100 and 110 add nothing until something denies the rest.

> **Why deny everything to the database rather than deny web-to-database:** If you
> only block the path you thought of, the next tier someone adds gets through.
> Deny by destination and let the specific allow rules above it carve out the
> exceptions.

> **Why 4000 and not 65100:** The first matching rule wins, and `AllowVnetInBound`
> sits at 65000. Anything numbered above that never gets evaluated.

### Step 6 - Deploy the virtual machines and put their NICs in the right groups

| VM | Subnet | ASG |
| --- | --- | --- |
| `vm-web-1` | `snet-web` | `asg-web` |
| `vm-web-2` | `snet-web` | `asg-web` |
| `vm-app-1` | `snet-app` | `asg-app` |
| `vm-db-1` | `snet-db` | `asg-db` |

None of them get a public IP. Add Bastion in `AzureBastionSubnet` so you can sign
in.

> **Why two web machines from the start:** So the "survives scaling out" claim is
> demonstrated rather than asserted. Nothing about the rules changed to add the
> second one - it inherited every rule the moment its NIC joined `asg-web`.

### Step 7 - Prove it

From `vm-web-1`:

- Connect to `vm-app-1` on 443 - should **succeed**
- Connect to `vm-db-1` on 1433 - should **fail**

From `vm-app-1`:

- Connect to `vm-db-1` on 1433 - should **succeed**

Then confirm the reason rather than the symptom, using Network Watcher's IP flow
verify against `vm-db-1` inbound. It tells you which named rule made the decision.
If a deny comes back attributed to `DenyAllInBound` at 65500 rather than your rule
at 4000, your rule is not matching and you have got lucky, not correct.

> **Why check the deciding rule:** Two different mistakes produce the same failed
> connection. Knowing which rule fired is the difference between "it is blocked"
> and "it is blocked for the reason I designed".

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `deploy_deny_rules = false` to build the trap - allow rules present, deny
rules absent - and watch web reach the database anyway through
`AllowVnetInBound`. Change `web_instance_count` to add web servers and re-run the
validation to see the rules cover them with no rule changes.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | All three application security groups exist |
| 2 | One NSG is associated with the web, app and database subnets |
| 3 | A rule allows the web ASG to reach the app ASG, expressed with ASGs on both sides |
| 4 | A rule allows the app ASG to reach the database ASG, expressed with ASGs on both sides |
| 5 | No rule permits the web ASG to reach the database ASG |
| 6 | A deny rule protects the database ASG at a priority below 65000 |
| 7 | A deny rule protects the app ASG at a priority below 65000 |
| 8 | No inbound rule allows the `Internet` service tag as a source |
| 9 | No tier-identity rule uses a subnet address prefix where an ASG should be used |
| 10 | Every workload NIC belongs to exactly one tier ASG, matching its subnet |
| 11 | The web ASG contains more than one NIC, proving the rules scale out |
| 12 | (Optional, with VM names) IP flow verify: app tier inbound from web on 443 is allowed by your named rule |
| 13 | (Optional, with VM names) IP flow verify: database tier inbound from web on 1433 is denied by your named rule, not by the default deny |

---

## Validation Script

[`validate.ps1`](validate.ps1) checks every criterion above. It is read-only.

```bash
pwsh ./validate.ps1
```

To include the Network Watcher IP flow checks (criteria 12 and 13), supply the VM
names:

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab04 -VnetName vnet-lab04 `
  -WebVmName vm-web-1 -AppVmName vm-app-1 -DbVmName vm-db-1
```

---

## Follow-Up Questions

No answers here on purpose. Each one is a real thing you will be asked eventually.

1. `AllowVnetInBound` at priority 65000 is on by default in every NSG Azure
   creates. Why would Microsoft choose that as the default, given how much trouble
   it causes here?
2. NSGs are stateful, so you never wrote a return rule. What state is actually
   being tracked, where does it live, and what happens to a long-lived connection
   when you edit the rule that originally permitted it?
3. Your rules attach to subnets. NSGs can also attach to individual NICs, and a
   packet can traverse both. In what order are they evaluated inbound versus
   outbound, and which combination is most likely to produce a rule you think is
   active but is not?
4. An ASG cannot span virtual networks. Why not - what would break in the data
   plane if it could?
5. You denied `Internet` inbound explicitly, but the default `DenyAllInBound` at
   65500 already covered it. Name a situation where that explicit rule changes the
   outcome rather than just the logging.
6. If the database tier were an Azure SQL private endpoint instead of a VM, which
   of your rules would still work, and which would silently stop applying?
7. Someone adds `vm-web-3` and forgets to put its NIC in `asg-web`. What can it
   reach, what can reach it, and what would you build so that mistake cannot ship?

---

## Clean Up

```bash
az group delete -n rg-lab04 --yes --no-wait
```

Or `terraform destroy`. Bastion bills by the hour.

---

[Back to the catalogue](../../README.md)
