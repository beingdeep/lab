# Lab 08: Egress Control with Azure Firewall

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Route all outbound traffic from a spoke through Azure Firewall in the hub.
Workloads may reach a defined list of fully qualified domain names and nothing
else. Everything denied must appear in the firewall logs with enough detail to
identify the source workload. Show why a network rule and an application rule
produce different log entries for the same request.

---

## What You Will Learn

- **Egress control is about what leaves, not what arrives.** Most breaches need an
  outbound connection at some point - to fetch a payload, or to send your data
  somewhere. Controlling egress is what makes that hard.
- **Network rules and application rules work at different layers.** A network rule
  decides on addresses and ports; it never sees the URL. An application rule
  terminates the connection, reads the TLS handshake, and decides on the hostname.
- **Rule type determines what you can log.** A network rule can only tell you
  "10.81.1.4 talked to 20.1.2.3:443". An application rule can tell you which
  hostname was requested and which rule allowed or denied it.
- **Application rules are evaluated after network rules.** If a network rule
  already allows the traffic, the application rule never runs - and your hostname
  allow-list quietly stops applying.
- **A firewall only sees traffic that is routed to it.** The route table is what
  forces the traffic past it. Without that, the firewall is an expensive idle
  resource.
- **Logs need a destination configured before they exist.** Azure keeps nothing by
  default. No diagnostic setting means no evidence, retroactively.

---

## Reference Architecture

```
  vnet-hub 10.80.0.0/16
  +-------------------------------------------------------+
  |  AzureFirewallSubnet 10.80.1.0/26                     |
  |    [ afw-hub ] --- policy fwp-lab08                   |
  |         |                                             |
  |         |  diagnostic setting -> law-lab08            |
  |  AzureBastionSubnet 10.80.2.0/26                      |
  +-------------------------------------------------------+
        ^ peering (forwarded traffic allowed)
        |
  vnet-spoke 10.81.0.0/16
  +-------------------------------------------------------+
  |  snet-workload 10.81.1.0/24                           |
  |    [ vm-spoke ]                                       |
  |    route table rt-spoke: 0.0.0.0/0 -> firewall        |
  +-------------------------------------------------------+

  Policy
    application rules  allow https to a named FQDN list
    network rules      allow tcp/443 to one specific address (teaching device)
    everything else    denied by the implicit default
```

---

## Build Instructions

### Step 1 - Resource group, hub and spoke

Create **`rg-lab08`**, then:

| VNet | Address space | Subnets |
| --- | --- | --- |
| `vnet-hub` | `10.80.0.0/16` | `AzureFirewallSubnet` `10.80.1.0/26`, `AzureBastionSubnet` `10.80.2.0/26` |
| `vnet-spoke` | `10.81.0.0/16` | `snet-workload` `10.81.1.0/24` |

Peer them in both directions, with **forwarded traffic allowed** on both.

### Step 2 - Create a Log Analytics workspace

Create **`law-lab08`** with 30 days retention.

> **Why before the firewall:** Because the diagnostic setting needs somewhere to
> point at, and because logs that were not configured before an event do not exist
> after it. You cannot go back and turn on logging for last Tuesday.

### Step 3 - Create the firewall policy

Create a firewall policy named **`fwp-lab08`**, Standard tier, with a rule
collection group named **`rcg-egress`** at priority 200 containing:

An **application rule collection** named `allow-fqdns`, priority 200, action
Allow, with one rule:

| Setting | Value |
| --- | --- |
| Source addresses | `10.81.0.0/16` |
| Protocols | https:443, http:80 |
| Destination FQDNs | your allow-list, e.g. `archive.ubuntu.com`, `security.ubuntu.com`, `login.microsoftonline.com` |

A **network rule collection** named `allow-one-address`, priority 300, action
Allow, with one rule:

| Setting | Value |
| --- | --- |
| Source addresses | `10.81.0.0/16` |
| Destination addresses | `1.1.1.1` |
| Protocol / ports | TCP 443 |

Add **no** rule with a destination of `*` or `0.0.0.0/0`.

> **Why the network rule is here at all:** It is the teaching device for the last
> part of the problem. You will send effectively the same request twice - once
> matched by an application rule, once by a network rule - and compare what
> arrives in the logs.

> **Why order matters:** Azure Firewall evaluates network rules before application
> rules. If a network rule already allows a flow, the application rule collection
> is never consulted and your hostname allow-list silently stops applying to that
> traffic. Broad network rules are how FQDN filtering gets quietly disabled.

### Step 4 - Deploy the firewall

Create a Standard public IP **`pip-afw`** and an Azure Firewall **`afw-hub`**,
SKU `AZFW_VNet`, tier **Standard**, attached to policy `fwp-lab08`, with its IP
configuration in `AzureFirewallSubnet`.

Note its **private** IP - you need it in the next step.

### Step 5 - Force the spoke's traffic through it

Create a route table **`rt-spoke`** with one route:

| Address prefix | Next hop type | Next hop IP |
| --- | --- | --- |
| `0.0.0.0/0` | Virtual appliance | the firewall's private IP |

Associate it with `snet-workload`.

> **Why `0.0.0.0/0` and not a list of destinations:** The point is that *everything*
> not otherwise routed goes to the firewall. Listing destinations means anything
> you did not think of takes the default internet route and escapes.

> **Do not put a route table on `AzureFirewallSubnet`.** The firewall would route
> its own outbound traffic through itself.

### Step 6 - Turn on the logs

Create a diagnostic setting on `afw-hub` sending to `law-lab08`, with at least
the application rule and network rule log categories enabled. Use the
resource-specific tables rather than the legacy `AzureDiagnostics` table.

> **Why resource-specific tables:** `AzureDiagnostics` is one enormous shared
> table where every service dumps its columns, and it has a hard column limit that
> different services compete for. Resource-specific tables (`AZFWApplicationRule`,
> `AZFWNetworkRule`) have real schemas, cost less to query, and are far easier to
> write alerts against.

### Step 7 - Deploy a workload and Bastion

Create **`vm-spoke`** in `snet-workload` with no public IP, and Bastion in the
hub.

### Step 8 - Prove it, then read the logs

From `vm-spoke`:

- Reach an allowed FQDN over HTTPS - should **succeed**
- Reach a denied FQDN, say `example.org` - should **fail**
- Reach `1.1.1.1` on 443 by address - should **succeed**, via the network rule

Then query the workspace and compare. Look at what each log record contains:

- The application rule record names the **hostname** requested, the rule that
  matched, and the source address
- The network rule record has the destination **IP and port** and no hostname at
  all

> **Why that difference matters:** Six months from now, someone asks which
> workload contacted a particular domain. If that traffic was matched by a network
> rule, you cannot answer - the hostname was never recorded, because at that layer
> the firewall never saw it.

> **Also notice:** the denied request appears in the logs with the source address,
> which is how you trace it back to a workload. Getting from an address to a
> workload name is a separate problem, and one worth thinking about now.

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `add_broad_network_rule = true` to see the failure mode from Step 3: a
network rule allowing all of TCP 443, which causes the whole FQDN allow-list to
stop applying without a single error anywhere.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | Hub and spoke virtual networks exist and are peered in both directions, `Connected` |
| 2 | The spoke peering allows forwarded traffic |
| 3 | An Azure Firewall exists in the hub with a firewall policy attached |
| 4 | The spoke subnet has a route table sending `0.0.0.0/0` to the firewall as `VirtualAppliance` |
| 5 | `AzureFirewallSubnet` has no route table |
| 6 | The policy has an application rule collection allowing a specific list of FQDNs |
| 7 | No rule allows an unrestricted destination (`*` FQDN, `0.0.0.0/0`, or `*` address) |
| 8 | A diagnostic setting on the firewall sends logs to a Log Analytics workspace |
| 9 | The diagnostic setting enables both application rule and network rule log categories |
| 10 | (Optional, with `-VmName`) An allowed FQDN is reachable from the spoke workload |
| 11 | (Optional, with `-VmName`) A denied FQDN is not reachable from the spoke workload |

---

## Validation Script

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab08 -HubVnetName vnet-hub `
  -SpokeVnetName vnet-spoke -FirewallName afw-hub -VmName vm-spoke
```

The optional checks run `curl` inside the workload VM through the run-command
extension.

---

## Follow-Up Questions

No answers here on purpose.

1. Your application rule matched on the hostname. Where did the firewall get that
   hostname from in an HTTPS connection it is not decrypting, and what does an
   attacker have to do to hide it?
2. The network rule log has no hostname. Reconstruct, as precisely as you can,
   what you *could* still determine about that traffic six months later - and what
   you could not.
3. `0.0.0.0/0` on the spoke sends everything to the firewall, including traffic to
   Azure services like storage and Key Vault. What does that do to your firewall's
   throughput bill, and what would you route differently?
4. If the firewall is unavailable, what happens to the spoke's traffic? Is that
   the behaviour you want, and what is the alternative?
5. The denied log entry gives you a source IP address. What would you have to build
   so that an on-call engineer at 3am gets a workload name instead?
6. Someone adds a network rule allowing TCP 443 to `*` "temporarily, to unblock a
   deployment". Which of your acceptance criteria catches it, how long could it sit
   there unnoticed, and what would you put in place so it cannot be added at all?
7. Azure Firewall bills per hour and per gigabyte processed. Work out roughly what
   this design costs for a spoke doing 1 TB of egress a month, and at what point
   you would choose a NAT gateway with NSG rules instead.

---

## Clean Up

```bash
az group delete -n rg-lab08 --yes --no-wait
```

Azure Firewall is the most expensive resource in Tier 1. Delete it the same day.

---

[Back to the catalogue](../../README.md)
