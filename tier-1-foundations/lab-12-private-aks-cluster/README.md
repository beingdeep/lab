# Lab 12: Private AKS Cluster

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Deploy an AKS cluster with a private API server endpoint, Azure CNI overlay
networking, and no public IP on any node. Cluster administration must work from a
jump host inside the network. Explain the address space implications of overlay
versus traditional CNI and justify your choice of pod CIDR.

---

## What You Will Learn

- **The API server is the cluster's control plane, and normally it is on the
  internet.** A private cluster puts it behind a private endpoint instead, so
  `kubectl` only works from inside your network.
- **Pods need IP addresses, and where they come from is the biggest decision you
  make.** Traditional Azure CNI gives every pod an address from your VNet.
  Overlay gives pods addresses from a separate private range that never touches
  your VNet.
- **Overlay saves an enormous amount of address space.** With traditional CNI, a
  node with 30 pods consumes 31 VNet addresses. A 100-node cluster needs a /19
  before you have deployed anything.
- **The overlay pod CIDR is invisible outside the cluster.** It can overlap with
  other clusters, and it must *not* overlap with anything the pods need to reach.
- **Nodes having no public IP is the default, but the egress path is not.** The
  cluster still reaches out through a load balancer with a public IP unless you
  change the outbound type.
- **Private cluster means private DNS.** The API server's name resolves through a
  private DNS zone linked to your VNet - which is the same mechanism as every
  other lab in this tier.

---

## Address Space: Overlay versus Traditional

The problem asks you to explain this, so work it out rather than reading it.

| | Traditional Azure CNI | Azure CNI Overlay |
| --- | --- | --- |
| Pod addresses come from | your VNet subnet | a separate pod CIDR |
| Pods routable from the VNet | yes, directly | no, NAT via the node |
| VNet addresses used per node | 1 + max pods per node | 1 |
| Pod CIDR can overlap other clusters | no | yes |
| A 100-node, 30-pod-per-node cluster needs | ~3100 VNet addresses (a /20) | 100 VNet addresses (a /25) |

The cost of overlay is that a pod is not directly reachable from the rest of the
network - traffic leaving a pod is translated to the node's address. If something
outside the cluster needs to connect *to* a pod address, overlay is the wrong
choice. Almost nothing does; they connect to services, through a load balancer or
an ingress.

**Choosing the pod CIDR.** It must not overlap with your VNet, any peered
network, on-premises, or anything your pods need to reach. It does not have to be
globally unique - a second cluster can use the same range. Pick something large
and deliberately outside your normal allocations, and write down why.

---

## Reference Architecture

```
  vnet-lab12 10.120.0.0/16
  +----------------------------------------------------------------+
  |  snet-aks 10.120.0.0/20                                        |
  |    [ node ] [ node ]     one VNet address each, no public IP   |
  |       pods on 192.168.0.0/16  <- overlay, invisible outside    |
  |                                                                |
  |  snet-jump 10.120.16.0/24                                      |
  |    [ vm-jump ]  Azure Kubernetes Service Cluster User Role     |
  |                                                                |
  |  AzureBastionSubnet 10.120.17.0/26                             |
  +----------------------------------------------------------------+
        |
        | private endpoint for the API server
        v
  privatelink.<region>.azmk8s.io  ->  10.120.x.x
     (system-managed zone, linked to the VNet automatically)

  service CIDR 172.16.0.0/16, DNS service 172.16.0.10
     also invisible outside the cluster
```

---

## Build Instructions

### Step 1 - Resource group and virtual network

Create **`rg-lab12`** and **`vnet-lab12`** with address space **`10.120.0.0/16`**:

| Subnet name | Address prefix | Notes |
| --- | --- | --- |
| `snet-aks` | `10.120.0.0/20` | nodes only, generous room to scale |
| `snet-jump` | `10.120.16.0/24` | |
| `AzureBastionSubnet` | `10.120.17.0/26` | |

> **Why a /20 for nodes when overlay only needs one address per node:** Because
> you cannot resize a subnet that has resources in it, and because internal load
> balancers, future node pools and Azure's own reserved addresses all live here
> too. Subnets are free. Rebuilding a cluster is not.

### Step 2 - Deploy the AKS cluster

Create **`aks-lab12`** with:

| Setting | Value |
| --- | --- |
| Private cluster | **Enabled** |
| Private DNS zone | **System** (let AKS manage it) |
| Network plugin | **azure** |
| Network plugin mode | **overlay** |
| Pod CIDR | `192.168.0.0/16` |
| Service CIDR | `172.16.0.0/16` |
| DNS service IP | `172.16.0.10` |
| Node subnet | `snet-aks` |
| Node public IP | **disabled** |
| Identity | system-assigned managed identity |
| Local accounts | disabled, Entra + RBAC enabled |

> **Why "private cluster" changes more than it sounds:** The API server gets a
> private endpoint in your VNet, and its name is published in a private DNS zone.
> Anything that talked to the cluster from outside - your laptop, a hosted CI
> runner, a monitoring SaaS - now cannot. Plan for that before you enable it,
> not after.

> **Why the DNS service IP must be inside the service CIDR:** CoreDNS is itself a
> Kubernetes service and needs an address from the service range. Picking one
> outside it produces a cluster that comes up and then fails every name lookup.

> **Why disable local accounts:** AKS ships with a certificate-based cluster-admin
> credential that bypasses Entra entirely. `az aks get-credentials --admin` hands
> it out, it cannot be revoked individually, and it does not appear in any sign-in
> log. Disable it, and use Entra groups mapped to Kubernetes RBAC instead.

### Step 3 - Deploy the jump host

Create **`vm-jump`** in `snet-jump`, no public IP, with a system-assigned managed
identity. Deploy Bastion.

Grant the VM's identity **`Azure Kubernetes Service Cluster User Role`** on the
cluster, so it can fetch a kubeconfig.

> **Why "Cluster User" and not "Cluster Admin":** Cluster User gets you a
> kubeconfig for the Entra-integrated endpoint - what you can actually do inside
> the cluster is then decided by Kubernetes RBAC. Cluster Admin gets the local
> admin credential and bypasses that entirely.

### Step 4 - Prove the API server is private

From `vm-jump`:

- Resolve the cluster's private FQDN - expect a `10.120.x.x` address
- `az aks get-credentials` then `kubectl get nodes` - should work

From your laptop:

- Resolve the same FQDN - it should not give you a usable address
- `kubectl get nodes` - should time out

> **Why test resolution separately from connectivity:** They fail differently and
> for different reasons, and knowing which one you are looking at saves an hour.

### Step 5 - Confirm the address spaces behave as you expect

From `vm-jump`:

- `kubectl get nodes -o wide` - node addresses are from `10.120.0.0/20`
- `kubectl get pods -A -o wide` - pod addresses are from `192.168.0.0/16`
- Confirm nothing in your VNet has a route to `192.168.0.0/16`

> **Why the last one matters:** It is the concrete proof that the pod CIDR is not
> consuming your address space, and the concrete reason nothing outside the
> cluster can dial a pod directly.

### Step 6 - Note what still has a public IP

Look at the cluster's node resource group. There is a load balancer with a public
IP on it, used for outbound traffic.

> **Why this lab stops here:** Removing that means setting the outbound type to
> user-defined routing and pointing a route at a firewall - which is Lab 08's
> pattern applied to a cluster, and taken to its conclusion in Lab 37. "No public
> IP on any node" and "no public IP anywhere" are different requirements, and it
> is worth being precise about which one you have met.

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `overlapping_pod_cidr = true` to try a pod CIDR that overlaps the VNet, and
see how Azure responds.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | The cluster has a private API server endpoint |
| 2 | The network plugin is `azure` in `overlay` mode |
| 3 | A pod CIDR is configured and does not overlap the virtual network |
| 4 | The service CIDR does not overlap the virtual network or the pod CIDR |
| 5 | The DNS service IP falls inside the service CIDR |
| 6 | No node pool has node public IPs enabled |
| 7 | Node pools use a subnet in your virtual network |
| 8 | A private DNS zone for the API server exists and is linked to the virtual network |
| 9 | Local accounts are disabled and Entra integration with Kubernetes RBAC is on |
| 10 | The jump host identity holds `Azure Kubernetes Service Cluster User Role`, and no principal holds the admin role |
| 11 | (Optional, with `-VmName`) The jump host resolves the private API FQDN to a private address |

---

## Validation Script

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab12 -VnetName vnet-lab12 -ClusterName aks-lab12 -VmName vm-jump
```

---

## Follow-Up Questions

No answers here on purpose.

1. Your pod CIDR is `192.168.0.0/16` and it never appears in a route table. So how
   does a packet from a pod on one node reach a pod on another node?
2. Two clusters can use the same pod CIDR. What breaks the day someone needs a pod
   in cluster A to talk to a pod in cluster B?
3. The API server is private. How does the Azure portal's Kubernetes resource view
   still show you workloads, and what does the answer imply about what "private"
   means here?
4. You disabled local accounts. If Entra is unavailable, can you still administer
   this cluster - and if not, what is your plan? (Lab 40 is the long answer.)
5. The node resource group is created and managed by AKS. What happens if you
   modify something in it by hand, and what stops someone doing so?
6. Node images and Kubernetes versions have to come from somewhere. List every
   outbound dependency this cluster has right now, and how each would be satisfied
   with no internet access at all.
7. You chose a /20 for the node subnet. Work out, with numbers, at what node count
   it runs out - and how that number would change with traditional CNI instead of
   overlay.

---

## Clean Up

```bash
az group delete -n rg-lab12 --yes --no-wait
```

AKS deletes its own node resource group with the cluster. Check it is gone.

---

[Back to the catalogue](../../README.md)
