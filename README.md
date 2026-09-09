# Azure Networking, DevOps and Security Labs

Fifty-six hands-on labs, ordered from foundational to expert. Each lab states a
requirement and gives you build instructions in plain language - what to create,
what to name it, and why the step exists. You work out the rest and build it
yourself. A finished Terraform build is included in every lab so you can compare
afterwards, and a script that checks your work against the acceptance criteria.

Tier 1 rebuilds the base properly. Tier 2 covers the work that shows up in real
delivery. Tier 3 is the material that separates senior from principal. Tier 4 is
deliberately hard, and several of those labs have no single correct answer.

## How each lab is laid out

Every lab lives in its own folder:

```
lab-NN-short-name/
├── README.md          the problem, what you will learn, build instructions,
│                      acceptance criteria
├── validate.ps1       checks your build against the acceptance criteria
└── solution/          the reference build in Terraform
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── versions.tf
    └── terraform.tfvars.example
```

The README is the exercise. It tells you what to create and what to call it, and
explains in two or three lines why each step exists - why a subnet needs a
delegation, why a peering needs forwarded traffic allowed, why a DNS zone needs a
link. It does not give you the commands. Build it in the portal, the CLI, or your
own code, then check your work.

## Working through a lab

**1. Build it yourself.** Read the build instructions and create the resources.
Getting stuck and working out why is the part that teaches you something.

**2. Check it.** Every lab has a `validate.ps1` that inspects what you actually
built and prints a pass or fail line per acceptance criterion, with a diagnostic
line explaining any failure. It needs the Azure CLI and PowerShell 7:

```bash
az login
az account set --subscription "<your-subscription-id>"
pwsh ./validate.ps1
```

The scripts prompt for the names you chose, so nothing is hardcoded to a
particular naming convention. They are read-only unless a lab says otherwise.

**3. Compare against the reference.** Only after you have built it yourself:

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Every solution outputs a ready-made `validate_command` you can paste straight in.
Several labs also have a variable that deliberately breaks something, so you can
see the failure mode the lab is teaching.

## What you need

| Tool | Why |
| --- | --- |
| An Azure subscription you can create resources in | The labs deploy real infrastructure |
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | The validation scripts query Azure through it |
| [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`) | Runs the validation scripts, on Windows, macOS or Linux |
| [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or later | Only needed for the reference solutions |

## Progress

| | Labs | Instructions | Terraform | Validation |
| --- | --- | --- | --- | --- |
| Tier 1 - Foundations | 14 | 01-03 | 01-03 | 01-03 |
| Tier 2 - Intermediate | 16 | - | - | - |
| Tier 3 - Advanced | 14 | - | - | - |
| Tier 4 - Expert | 12 | - | - | - |

---

## Tier 1 - Foundations

Deceptively simple. Every one of these has a detail that fails silently if you skip it.

| # | Lab | Status |
| --- | --- | --- |
| 01 | [Fully Private Web App with a Locked-Down Jump VM](tier-1-foundations/lab-01-private-web-app-jump-vm/) | Ready |
| 02 | [Hub and Spoke with a Shared Services Spoke](tier-1-foundations/lab-02-hub-spoke-shared-services/) | Ready |
| 03 | [Private DNS Resolution Across Peered Networks](tier-1-foundations/lab-03-private-dns-across-peerings/) | Ready |
| 04 | [Three-Tier Segmentation with Application Security Groups](tier-1-foundations/lab-04-three-tier-asg-segmentation/) | Problem only |
| 05 | [Storage Account with No Public Surface](tier-1-foundations/lab-05-storage-no-public-surface/) | Problem only |
| 06 | [Key Vault with RBAC and Identity-Only Access](tier-1-foundations/lab-06-key-vault-rbac-identity-only/) | Problem only |
| 07 | [Application Gateway with WAF in Front of a Private App](tier-1-foundations/lab-07-app-gateway-waf-private-app/) | Problem only |
| 08 | [Egress Control with Azure Firewall](tier-1-foundations/lab-08-egress-control-azure-firewall/) | Problem only |
| 09 | [Terraform Remote State Done Properly](tier-1-foundations/lab-09-terraform-remote-state/) | Problem only |
| 10 | [Secretless Pipelines with Workload Identity Federation](tier-1-foundations/lab-10-secretless-pipelines-oidc/) | Problem only |
| 11 | [Gated Infrastructure Deployment with Preview](tier-1-foundations/lab-11-gated-deployment-preview/) | Problem only |
| 12 | [Private AKS Cluster](tier-1-foundations/lab-12-private-aks-cluster/) | Problem only |
| 13 | [Self-Hosted Build Agents Inside a Private Network](tier-1-foundations/lab-13-self-hosted-build-agents/) | Problem only |
| 14 | [Diagnostics Enforced by Policy](tier-1-foundations/lab-14-diagnostics-enforced-by-policy/) | Problem only |

---

## Tier 2 - Intermediate

Real delivery work. These labs have moving parts that interact.

| # | Lab | Status |
| --- | --- | --- |
| 15 | [Hybrid DNS with Azure DNS Private Resolver](tier-2-intermediate/lab-15-hybrid-dns-private-resolver/) | Problem only |
| 16 | [Site-to-Site VPN with BGP](tier-2-intermediate/lab-16-site-to-site-vpn-bgp/) | Problem only |
| 17 | [Global Front Door with Private Link Origins](tier-2-intermediate/lab-17-front-door-private-link-origins/) | Problem only |
| 18 | [Zero-Downtime Release with Slots](tier-2-intermediate/lab-18-zero-downtime-slot-release/) | Problem only |
| 19 | [Internal Ingress on AKS with Private Certificates](tier-2-intermediate/lab-19-aks-internal-ingress-certs/) | Problem only |
| 20 | [Workload Identity for Pods](tier-2-intermediate/lab-20-aks-workload-identity-pods/) | Problem only |
| 21 | [Locked-Down Container Supply Chain](tier-2-intermediate/lab-21-container-supply-chain/) | Problem only |
| 22 | [Guardrails That Prevent Public Exposure](tier-2-intermediate/lab-22-policy-guardrails-public-exposure/) | Problem only |
| 23 | [Event-Driven Secret Rotation](tier-2-intermediate/lab-23-event-driven-secret-rotation/) | Problem only |
| 24 | [Private Databricks Workspace](tier-2-intermediate/lab-24-private-databricks-workspace/) | Problem only |
| 25 | [Unified Telemetry Pipeline](tier-2-intermediate/lab-25-unified-telemetry-pipeline/) | Problem only |
| 26 | [Service Level Objectives and Error Budgets](tier-2-intermediate/lab-26-slo-error-budgets/) | Problem only |
| 27 | [Cross-Subscription Private Endpoint Approval](tier-2-intermediate/lab-27-cross-sub-private-endpoint-approval/) | Problem only |
| 28 | [Regional Failover for App and Data](tier-2-intermediate/lab-28-regional-failover-app-data/) | Problem only |
| 29 | [Traffic Visibility and Egress Cost](tier-2-intermediate/lab-29-traffic-visibility-egress-cost/) | Problem only |
| 30 | [Privileged Access Without Standing Permissions](tier-2-intermediate/lab-30-privileged-access-no-standing/) | Problem only |

---

## Tier 3 - Advanced

These require you to reason about failure modes, not just configuration.

| # | Lab | Status |
| --- | --- | --- |
| 31 | [Third-Party Appliance and Asymmetric Routing](tier-3-advanced/lab-31-nva-asymmetric-routing/) | Problem only |
| 32 | [Virtual WAN with Secured Hubs](tier-3-advanced/lab-32-virtual-wan-secured-hubs/) | Problem only |
| 33 | [ExpressRoute and VPN Coexistence](tier-3-advanced/lab-33-expressroute-vpn-coexistence/) | Problem only |
| 34 | [Forced Tunnelling with Split DNS](tier-3-advanced/lab-34-forced-tunnelling-split-dns/) | Problem only |
| 35 | [Progressive Delivery Across a Cluster Fleet](tier-3-advanced/lab-35-progressive-delivery-fleet/) | Problem only |
| 36 | [Mutual TLS and Authorization Inside the Mesh](tier-3-advanced/lab-36-mtls-mesh-authorization/) | Problem only |
| 37 | [Cluster with No Internet Access at All](tier-3-advanced/lab-37-fully-isolated-aks-cluster/) | Problem only |
| 38 | [GitOps with Enforced Drift Correction](tier-3-advanced/lab-38-gitops-drift-correction/) | Problem only |
| 39 | [Verifiable Build Provenance](tier-3-advanced/lab-39-verifiable-build-provenance/) | Problem only |
| 40 | [Break-Glass Access Design](tier-3-advanced/lab-40-break-glass-access/) | Problem only |
| 41 | [Encryption in Use for a Regulated Workload](tier-3-advanced/lab-41-encryption-in-use-confidential/) | Problem only |
| 42 | [Customer-Managed Keys End to End](tier-3-advanced/lab-42-customer-managed-keys/) | Problem only |
| 43 | [Chaos Experiments Against Objectives](tier-3-advanced/lab-43-chaos-experiments-slo/) | Problem only |
| 44 | [Active-Active Across Regions with Data Residency](tier-3-advanced/lab-44-active-active-data-residency/) | Problem only |

---

## Tier 4 - Expert

Open-ended. Several of these have no single correct answer, and defending your reasoning is part of the exercise.

| # | Lab | Status |
| --- | --- | --- |
| 45 | [Landing Zone from First Principles](tier-4-expert/lab-45-landing-zone-first-principles/) | Problem only |
| 46 | [Sovereign and Air-Gapped Deployment](tier-4-expert/lab-46-sovereign-air-gapped/) | Problem only |
| 47 | [Incident - Intermittent Failures Across Private Endpoints](tier-4-expert/lab-47-incident-intermittent-private-endpoints/) | Problem only |
| 48 | [Incident - Resolution Flapping After a Peering Change](tier-4-expert/lab-48-incident-dns-flapping-peering/) | Problem only |
| 49 | [Migrating a Public Monolith to Private with No Downtime](tier-4-expert/lab-49-public-to-private-migration/) | Problem only |
| 50 | [Tenant Isolation for a Multi-Tenant Platform](tier-4-expert/lab-50-multi-tenant-isolation/) | Problem only |
| 51 | [Global Egress Architecture Under Cost Pressure](tier-4-expert/lab-51-global-egress-cost/) | Problem only |
| 52 | [Automated Compliance Evidence](tier-4-expert/lab-52-automated-compliance-evidence/) | Problem only |
| 53 | [Infrastructure Code at Two Hundred Spokes](tier-4-expert/lab-53-iac-at-scale-200-spokes/) | Problem only |
| 54 | [Supply Chain Compromise Response](tier-4-expert/lab-54-supply-chain-compromise-response/) | Problem only |
| 55 | [Private Connectivity Between Clouds](tier-4-expert/lab-55-private-cross-cloud-connectivity/) | Problem only |
| 56 | [Architecture Review Under Cross-Examination](tier-4-expert/lab-56-architecture-review/) | Problem only |

---

## Cost

Nothing in this repository deploys anything on its own. You build the labs in a
subscription you control, and you are responsible for what runs in it.

Several labs use resources that bill by the hour whether or not you are using
them - Azure Firewall, Application Gateway, Bastion, VPN and ExpressRoute
gateways, Databricks, AKS. Delete the resource group the same day:

```bash
az group delete -n rg-labNN --yes --no-wait
```

Or `terraform destroy` from the lab's `solution/` folder. Where a lab has a
cheaper alternative to an expensive resource, its README says so.
