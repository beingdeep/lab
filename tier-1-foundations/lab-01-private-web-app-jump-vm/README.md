# Lab 01: Fully Private Web App with a Locked-Down Jump VM

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Deploy a web application that is reachable only from a single hardened VM inside a
virtual network. The app must have no public endpoint, and the VM must have no
route to the internet apart from that one app. The app also needs to reach an
Azure SQL database over a private connection, with no password in the connection
string. Public DNS must not resolve the app to anything usable.

---

## What You Will Learn

- **A private endpoint is a network card for a PaaS service.** It gives an App
  Service or a database a private IP inside your virtual network, so traffic
  never goes out to the internet to reach it.
- **Inbound and outbound are separate features.** A private endpoint controls
  traffic coming *in*. For the app to call the database privately you need VNet
  integration, which is a completely different setting.
- **A private IP is useless if DNS still returns the public one.** A private DNS
  zone linked to your VNet is what makes machines inside resolve the private
  address. Skip it and everything quietly keeps using the public path.
- **NSGs block traffic; route tables remove the road.** An NSG is a guard that
  says yes or no. A route decides whether a path exists at all. Real hardening
  does both.
- **Managed identity replaces passwords.** The app asks Azure for a short-lived
  token instead of storing a database password. Nothing to leak, nothing to
  rotate.
- **Some subnet names are mandatory.** `AzureBastionSubnet` must be spelled
  exactly that, or Bastion will not deploy at all.

---

## Reference Architecture

```
                        Azure Bastion  (only way in)
                              |
  vnet-lab01 10.10.0.0/16     |
  +---------------------------|-------------------------------------+
  |  AzureBastionSubnet       |                                      |
  |  10.10.3.0/26 ------------+                                      |
  |                                                                  |
  |  snet-jump 10.10.2.0/24                                          |
  |    [ vm-jump ]  no public IP                                     |
  |      NSG: outbound allow -> PE IP :443 only, deny Internet       |
  |      UDR: 0.0.0.0/0 -> None                                      |
  |            |                                                     |
  |            | https                                               |
  |            v                                                     |
  |  snet-pe 10.10.1.0/24                                            |
  |    [ pe-web  ] --> App Service   (public network access off)     |
  |    [ pe-sql  ] --> Azure SQL     (public network access off)     |
  |            ^                                                     |
  |            | Entra token, no password                            |
  |  snet-appint 10.10.4.0/24   (App Service VNet integration)       |
  +------------------------------------------------------------------+

  Private DNS zones linked to vnet-lab01:
    privatelink.azurewebsites.net      -> pe-web private IP
    privatelink.database.windows.net   -> pe-sql private IP
```

---

## Build Instructions

Work through these in order and build it yourself in the portal, the CLI, or your
own code. Each step says what to create and what to name it, and explains in a
couple of lines why the step exists. The finished Terraform is in
[`solution/`](solution/) if you get stuck or want to compare afterwards.

### Step 1 - Create the resource group

Create a resource group named **`rg-lab01`** in a region of your choice. Every
resource in this lab goes in it.

> **Why:** A resource group is a delete boundary. Keeping one lab in one group
> means you can remove everything with a single command when you are done, which
> matters here because several resources bill by the hour.

### Step 2 - Create the virtual network and its four subnets

Create a virtual network named **`vnet-lab01`** with address space
**`10.10.0.0/16`**, containing four subnets:

| Subnet name | Address prefix | Extra configuration |
| --- | --- | --- |
| `snet-pe` | `10.10.1.0/24` | none |
| `snet-jump` | `10.10.2.0/24` | none |
| `AzureBastionSubnet` | `10.10.3.0/26` | name must be exactly this, and it must be /26 or larger |
| `snet-appint` | `10.10.4.0/24` | delegate the subnet to `Microsoft.Web/serverFarms` |

> **Why four subnets:** Private endpoints, the jump VM, Bastion and App Service
> outbound each need their own space so you can apply different rules to each.
> A route table or NSG attaches to a whole subnet, so anything you want to treat
> differently needs to be separated out.

> **Why the delegation on `snet-appint`:** Delegation is you handing a subnet over
> to an Azure service so that service is allowed to inject its own networking
> hardware into it. App Service VNet integration works by placing an invisible
> network interface for your app inside that subnet, and Azure refuses to do that
> unless you have explicitly said "this subnet belongs to `Microsoft.Web/serverFarms`".
> A delegated subnet can only be used by that one service - no VMs, no other apps,
> no second web app plan.

> **Why `AzureBastionSubnet` must have that exact name:** Bastion is a managed
> service that Azure deploys into your network for you. It finds the subnet to
> deploy into by looking for that literal name. Call it anything else and Bastion
> deployment fails with an unhelpful error.

### Step 3 - Create the private DNS zones and link them to the virtual network

Create two private DNS zones:

- **`privatelink.azurewebsites.net`**
- **`privatelink.database.windows.net`**

Link **both** zones to `vnet-lab01`. Set **registration to disabled** on both
links.

> **Why these exact names:** Every Azure service that supports private endpoints
> has one specific private DNS zone name it works with. App Service is
> `privatelink.azurewebsites.net`, SQL is `privatelink.database.windows.net`. A
> zone with any other name will be created happily and will resolve nothing.

> **Why link them to the VNet:** A private DNS zone does nothing on its own. The
> link is what tells Azure's built-in resolver "when a machine in this virtual
> network asks for a name in this zone, answer from here". No link, no private
> resolution.

> **Why registration disabled:** Registration means "automatically add a DNS
> record for every VM in this network". These zones hold records written by
> private endpoints, not VMs, and a zone can only have one registration link -
> leaving it on causes later links to fail.

> **Do this step before creating the private endpoints.** The endpoints will then
> write their records into the zones automatically.

### Step 4 - Create the Azure SQL server and database

Create a SQL logical server named **`sql-lab01-<something-unique>`** (the name is
part of a public DNS name, so it has to be globally unique) with:

- **Public network access disabled**
- **Microsoft Entra admin** set to your own user account
- **Entra-only authentication enabled**
- Minimum TLS version 1.2

Then create a database on it named **`appdb`** (Basic tier is plenty).

> **Why Entra-only authentication:** The requirement says no password in the
> connection string. If the server still accepts SQL username/password logins,
> then a password still exists somewhere and can still be stolen - you have just
> moved it. Turning on Entra-only authentication removes the SQL admin login
> entirely, so token-based sign-in is the only way in.

> **Why disable public network access:** Without this, the database is still
> reachable from the internet by anyone with valid credentials. The private
> endpoint you add next gives you a private path *in addition to* the public one
> until you explicitly close the public one.

### Step 5 - Create a private endpoint for the SQL server

Create a private endpoint named **`pe-sql`** in subnet `snet-pe`, targeting your
SQL server, with sub-resource (group ID) **`sqlServer`**.

Attach a **private DNS zone group** to it pointing at
`privatelink.database.windows.net`.

> **Why the sub-resource matters:** One Azure resource can expose several
> different things privately. For SQL the sub-resource is `sqlServer`; for a
> storage account you would pick `blob`, `file`, `table` and so on. Picking the
> wrong one gives you an endpoint that connects to the wrong service.

> **Why the DNS zone group:** This is the piece that writes the A record into your
> private DNS zone. Without it the private endpoint exists, has a working private
> IP, and absolutely nothing resolves to it. If you only remember one thing from
> this lab, make it this.

### Step 6 - Create the App Service plan and web app

Create a Linux App Service plan named **`plan-lab01`** on a **Premium v3 (P0v3)**
SKU, and a web app named **`app-lab01-<something-unique>`** on it.

> **Why Premium v3:** Private endpoints need Basic tier or above, and VNet
> integration has its own tier requirements. Premium v3 avoids you hitting a
> feature that is silently unavailable on a cheaper plan. Delete it when you
> finish the lab - it bills hourly.

### Step 7 - Turn on VNet integration and force all outbound traffic through it

On the web app:

- Enable **regional VNet integration** into subnet `snet-appint`
- Set **`vnetRouteAllEnabled` to true** (in the portal this is the "Outbound
  internet traffic" / "Route All" toggle)

> **Why:** This is the outbound half of the problem. VNet integration gives the app
> a foothold inside your network so it can reach the SQL private endpoint at
> `10.10.1.x`. Without it, the app's outbound traffic leaves from Azure's shared
> infrastructure and never touches your network at all.

> **Why Route All:** By default only private address ranges get sent through your
> network; everything else still leaves by the app's own public path. Turning
> Route All on means every outbound packet goes through your VNet, so your routing
> and firewall rules actually apply to all of it.

### Step 8 - Create a private endpoint for the web app and close its public door

Create a private endpoint named **`pe-web`** in subnet `snet-pe`, targeting your
web app, with sub-resource (group ID) **`sites`**, and attach a private DNS zone
group pointing at `privatelink.azurewebsites.net`.

Then set the web app's **public network access to Disabled**.

> **Why both:** The private endpoint creates the private way in. Disabling public
> network access closes the public way in. Doing only the first leaves you with two
> doors and one of them still faces the street.

> **What "public DNS must not resolve to anything usable" means in practice:**
> `app-lab01-xxxx.azurewebsites.net` will still resolve from the public internet -
> it is a shared Azure front end and you cannot make that name disappear. What it
> will no longer do is serve your app: the front end returns **HTTP 403** because
> public access is off. Inside the VNet, the same name resolves through your
> private zone to `10.10.1.x` and works normally. Same name, two different answers
> depending on who is asking. That is called split-horizon DNS.

### Step 9 - Give the app an identity and a passwordless connection string

On the web app:

- Enable the **system-assigned managed identity**
- Add a connection string named **`AppDb`** of type **SQLAzure** whose value uses
  `Authentication=Active Directory Default` and contains **no** username or
  password

Then connect to the database as your Entra admin and create a database user for
the app's identity, granting it read and write:

```sql
CREATE USER [app-lab01-xxxx] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [app-lab01-xxxx];
ALTER ROLE db_datawriter ADD MEMBER [app-lab01-xxxx];
```

Use the web app's name as the user name - that is how a system-assigned managed
identity presents itself to SQL.

> **Why this works:** `Authentication=Active Directory Default` tells the database
> driver "go and find an identity yourself". Running inside App Service, it finds
> the managed identity, asks Azure for a token, and logs in with that. The token
> lasts about an hour and is fetched fresh each time, so there is no long-lived
> secret anywhere in your configuration.

> **Note:** This SQL step cannot be done in Terraform without a database
> connection, so it stays manual in the solution too. Run it from the jump VM once
> the VM is up, or from Cloud Shell before you disable public access.

### Step 10 - Deploy the jump VM with no public IP

Create a small Linux VM named **`vm-jump`** in subnet `snet-jump` with **no public
IP address at all**.

Then deploy **Azure Bastion** into `AzureBastionSubnet` (Basic SKU is fine), with a
Standard public IP named `pip-bastion`, so you still have a way to sign in.

> **Why no public IP:** A VM with a public IP is exposed to the whole internet the
> moment it exists, and internet-wide scanners find new Azure IPs within minutes.
> Create it without one - do not create one and delete it later, because the
> exposure happens in the gap.

> **Why Bastion:** If the VM has no public IP and no internet route, you cannot SSH
> to it directly. Bastion is a managed jump service that lives inside your network
> and gives you a browser-based session, so the VM stays completely private and you
> still get in.

### Step 11 - Remove the jump subnet's route to the internet

Create a route table named **`rt-jump`** containing one route:

| Address prefix | Next hop type |
| --- | --- |
| `0.0.0.0/0` | `None` |

Associate it with subnet `snet-jump`.

> **Why:** Every Azure subnet gets an invisible default route sending unknown
> traffic to the internet. `0.0.0.0/0` means "everywhere I do not have a more
> specific route for", and next hop `None` means "throw it away". This overrides
> the built-in route and genuinely removes the path.

> **Why this does not break anything you need:** Azure keeps more specific system
> routes for your own VNet address space, so the VM can still reach the private
> endpoints at `10.10.1.x`. The platform address `168.63.129.16`, used for DNS and
> VM health, also still works - it is not covered by this override.

### Step 12 - Restrict the jump VM to just that one app

Create a network security group named **`nsg-jump`** with these rules, and
associate it with subnet `snet-jump`:

| Direction | Priority | Action | Source | Destination | Ports |
| --- | --- | --- | --- | --- | --- |
| Inbound | 100 | Allow | `10.10.3.0/26` (Bastion subnet) | any | 22, 3389 |
| Outbound | 100 | Allow | any | the `pe-web` private IP | 443 |
| Outbound | 110 | Allow | any | `168.63.129.16` | 53 |
| Outbound | 4000 | Deny | any | `Internet` | any |

> **Why priority numbers matter:** NSG rules are evaluated lowest number first, and
> the first match wins. Your two allow rules have to sit above the deny rule, and
> the deny rule has to sit above Azure's built-in `AllowInternetOutBound` rule at
> priority 65001 - which is why 4000 works and 65500 would not.

> **Why the rule for `168.63.129.16`:** That address is Azure's platform DNS
> resolver and health probe endpoint. Without it the VM cannot resolve any name at
> all, including the private endpoint's, and you will think your DNS zones are
> broken when they are fine.

> **Why do this as well as the route table:** Belt and braces, and they fail
> differently. The route table removes the path; the NSG logs and blocks attempts.
> If someone later removes one, the other still holds.

### Step 13 - Prove it

From `vm-jump`, connected over Bastion:

- Resolve the app's hostname - you should get a `10.10.1.x` address, not a public one
- Request the app over HTTPS - you should get **HTTP 200**
- Try to reach any other website - it should time out

From your own laptop:

- Request the app's public hostname - you should get **HTTP 403**

Then run the validation script below to check the configuration properly.

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

The only thing it cannot do is the `CREATE USER ... FROM EXTERNAL PROVIDER`
statement from Step 9, because that needs a live database connection. Terraform
prints the exact SQL to run as an output.

Try to build the lab yourself first. The Terraform is there to compare against,
not to skip to.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | The web app exists and `publicNetworkAccess` is `Disabled` |
| 2 | The web app has an approved private endpoint with group ID `sites` |
| 3 | Private DNS zone `privatelink.azurewebsites.net` exists, is linked to the VNet, and holds an A record for the app pointing at a private address |
| 4 | The web app has regional VNet integration into a delegated subnet |
| 5 | `vnetRouteAllEnabled` is `true` on the web app |
| 6 | The web app has a system-assigned managed identity |
| 7 | No app setting or connection string on the web app contains a password |
| 8 | The connection string uses Entra authentication (`Authentication=Active Directory ...`) |
| 9 | The SQL server has `publicNetworkAccess` set to `Disabled` |
| 10 | The SQL server has Entra-only authentication enabled |
| 11 | The SQL server has an approved private endpoint with group ID `sqlServer` |
| 12 | Private DNS zone `privatelink.database.windows.net` exists, is linked to the VNet, and holds an A record for the server |
| 13 | The jump VM has no public IP address on any of its NICs |
| 14 | The jump VM's subnet has a route table with `0.0.0.0/0` going to next hop `None` |
| 15 | The jump VM's subnet NSG denies outbound to `Internet` ahead of any allow rule for it |
| 16 | The jump VM's subnet NSG has an outbound allow rule targeting the app's private endpoint address on 443 |
| 17 | (Optional, with `-PublicProbe`) The app's public hostname does not serve the app from the internet |

---

## Validation Script

[`validate.ps1`](validate.ps1) checks every criterion above. It is read-only - it
makes no changes to your subscription.

```bash
pwsh ./validate.ps1
```

It prompts for the resource group, VNet, web app, SQL server, and jump VM names.
You can also pass them directly:

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab01 -VnetName vnet-lab01 -WebAppName app-lab01-1234 -SqlServerName sql-lab01-1234 -JumpVmName vm-jump
```

If your private DNS zones live in a different resource group, add
`-DnsResourceGroup rg-dns`. To include the public probe (criterion 17), add
`-PublicProbe` - run that one from outside the virtual network or it will be
misleading.

---

## Follow-Up Questions

No answers here on purpose. Each one is a real thing you will be asked eventually.

1. The app's public hostname still resolves from the internet and returns 403. Why
   can you not make that name disappear entirely, and what would have to change
   about the architecture to get a name that genuinely does not exist publicly?
2. You set `vnetRouteAllEnabled` to true. The SQL private endpoint is an RFC 1918
   address, which would have traversed the VNet anyway. So what actually breaks if
   you leave that setting off?
3. Why does `snet-appint` need a delegation while `snet-pe` does not, when both end
   up holding network interfaces that Azure created on your behalf?
4. The jump VM has `0.0.0.0/0` routed to `None`, yet it still resolves DNS and Azure
   still reports it as healthy. Which route is carrying that traffic, and why does
   your override not cover it?
5. Your NSG denies outbound to the `Internet` service tag. What is that tag
   actually defined as, and is your private endpoint's address inside or outside
   it? Would your answer change if the endpoint lived in a peered VNet?
6. Entra-only authentication means the app's access depends entirely on one role
   assignment. If someone deletes it at 2am, how does the app fail, how fast, and
   what would you have to build to find out before your users do?
7. You disabled public network access on the web app *after* creating the private
   endpoint. What was reachable, and by whom, in the window between those two
   operations - and how would you order this differently in a pipeline?

---

## Clean Up

```bash
az group delete -n rg-lab01 --yes --no-wait
```

Or `terraform destroy` if you used the solution. Bastion and the Premium v3 plan
both bill by the hour whether or not you are using them. Do not leave this lab
running overnight.

---

[Back to the catalogue](../../README.md)
