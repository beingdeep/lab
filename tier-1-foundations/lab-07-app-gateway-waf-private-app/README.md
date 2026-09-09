# Lab 07: Application Gateway with WAF in Front of a Private App

**Tier:** Tier 1 - Foundations
**Status:** Instructions, Terraform solution and validation script written

---

## The Problem

Publish a privately deployed App Service to the internet through Application
Gateway v2 with the Web Application Firewall in prevention mode. The app itself
must remain unreachable except through the gateway. Terminate TLS at the gateway
and re-encrypt to the backend. Confirm the WAF blocks a basic injection payload
while normal traffic passes.

---

## What You Will Learn

- **A reverse proxy is how you publish something without exposing it.** The
  gateway has the public IP; the app has only a private one. The only route in is
  through your rules.
- **Detection mode and prevention mode are different products in practice.**
  Detection logs an attack and lets it through. Prevention blocks it. Shipping in
  detection and forgetting is extremely common.
- **TLS termination means the gateway decrypts your traffic.** That is what lets
  it inspect the request body for attacks. Re-encrypting to the backend means the
  hop from gateway to app is encrypted again.
- **The gateway resolves DNS from inside your VNet.** That is why it can reach
  `yourapp.azurewebsites.net` at a private address, and why the private DNS zone
  has to be linked to the gateway's network too.
- **App Service backends care about the Host header.** Send the wrong hostname
  and you get a 404 from Azure's shared front end rather than your app.
- **A WAF in front of an open app is theatre.** Closing the app's public access is
  what makes the gateway the only way in.

---

## Reference Architecture

```
   internet
      |  HTTPS 443, TLS terminated here
      v
  [ pip-agw ]  public IP
  +---------------------------------------------------------------+
  | vnet-lab07 10.70.0.0/16                                       |
  |  snet-agw 10.70.1.0/24                                        |
  |    [ agw-lab07 ]  WAF_v2, firewall policy in Prevention mode  |
  |         |   re-encrypted HTTPS 443, Host header preserved     |
  |         v                                                     |
  |  snet-pe 10.70.2.0/24                                         |
  |    [ pe-web ] --> App Service (public network access off)     |
  |                                                               |
  |  snet-appint 10.70.3.0/24  (delegated, app outbound)          |
  +---------------------------------------------------------------+

  privatelink.azurewebsites.net linked to vnet-lab07, so the gateway
  resolves the app's own hostname to 10.70.2.x
```

---

## Build Instructions

### Step 1 - Resource group and virtual network

Create **`rg-lab07`** and **`vnet-lab07`** with address space **`10.70.0.0/16`**:

| Subnet name | Address prefix | Extra configuration |
| --- | --- | --- |
| `snet-agw` | `10.70.1.0/24` | dedicated to the gateway, nothing else in it |
| `snet-pe` | `10.70.2.0/24` | |
| `snet-appint` | `10.70.3.0/24` | delegated to `Microsoft.Web/serverFarms` |

> **Why the gateway gets its own subnet:** Application Gateway v2 takes the whole
> subnet for itself, scales into it, and rejects other resource types. Size it
> generously - a /24 is far more than you need but resizing later means
> redeploying the gateway.

### Step 2 - Private DNS zone

Create **`privatelink.azurewebsites.net`**, link it to `vnet-lab07`, registration
disabled.

> **Why the gateway needs this:** The gateway will address the backend by the app's
> own hostname. It resolves that name using the DNS of the VNet it sits in. Without
> the zone link, the gateway resolves the public address and your "private" backend
> is reached over the internet - which still works, so nothing looks wrong.

### Step 3 - App Service, private and closed

Create an App Service plan **`plan-lab07`** (Linux, P0v3) and a web app
**`app-lab07-<unique>`**. Then:

- Enable regional VNet integration into `snet-appint`
- Create private endpoint **`pe-web`** in `snet-pe`, sub-resource **`sites`**, with
  a DNS zone group
- Set **public network access to Disabled**

> **Why close it now, before the gateway works:** So you find out whether the
> gateway is genuinely reaching the private endpoint rather than quietly using the
> public path. Build it open and you will never know which one you tested.

### Step 4 - A certificate for the gateway

Create a Key Vault **`kv-lab07-<unique>`** with RBAC authorisation, and inside it a
self-signed certificate named **`agw-cert`** with subject `CN=lab07.local`.

Create a **user-assigned managed identity** named **`id-agw`** and give it
**`Key Vault Secrets User`** on the vault.

> **Why a user-assigned identity:** The gateway needs to fetch its certificate
> from the vault at start-up and on every renewal. A user-assigned identity exists
> before the gateway does, so you can grant it the role first and avoid a
> chicken-and-egg problem at creation time.

> **Why the certificate lives in a vault at all:** Certificates expire. A gateway
> holding an uploaded copy needs a manual redeploy every renewal; a gateway
> referencing a vault picks up the new version by itself.

> **Note:** this vault keeps public access enabled, because Terraform has to write
> the certificate into it. Locking a vault down properly is Lab 06.

### Step 5 - The WAF policy

Create a **web application firewall policy** named **`waf-lab07`** with:

| Setting | Value |
| --- | --- |
| Mode | **Prevention** |
| Managed rule set | OWASP 3.2 |
| State | Enabled |

> **Why prevention and not detection:** Detection mode logs the attack and serves
> the request anyway. It exists so you can tune rules against real traffic before
> switching over. Plenty of production gateways are still in detection mode years
> later because nobody came back to flip it.

### Step 6 - The Application Gateway

Create **`agw-lab07`**, SKU **WAF_v2**, in `snet-agw`, with:

| Component | Setting |
| --- | --- |
| Frontend | public IP `pip-agw`, Standard SKU, static |
| Listener | HTTPS on port 443, using the Key Vault certificate |
| Backend pool | the app's hostname (`app-lab07-xxx.azurewebsites.net`), **not** an IP |
| Backend settings | HTTPS on port 443, pick host name from backend address |
| Health probe | custom, picks host name from backend settings, path `/` |
| Identity | user-assigned `id-agw` |
| Firewall policy | `waf-lab07` |

> **Why the backend is a hostname and not an IP:** App Service does not serve your
> app on a bare IP. It routes by the `Host` header. Point the gateway at
> `10.70.2.4` and you get a 404 from Azure's front end, because it has no idea
> which of thousands of apps you meant. Using the hostname, and telling the
> backend settings and the probe to preserve it, is what makes the app answer.

> **Why re-encrypt instead of talking HTTP to the backend:** The gateway decrypts
> to inspect, which is the whole point of a WAF. Re-encrypting means the traffic is
> not in plaintext on the second hop either. Between two Azure subnets the
> practical risk is low, but "encrypted end to end except one bit in the middle"
> is a difficult sentence to say to an auditor.

### Step 7 - Prove it

Against the gateway's public IP:

- A normal request should return **200**
- A request with a basic SQL injection payload in the query string should return
  **403** from the WAF

Against the app's own hostname from the internet:

- It should return **403**, not your app

> **Why test all three:** The first proves the path works. The second proves the
> WAF is in prevention mode, not detection. The third proves the gateway is the
> only way in - without it, you have built a WAF that attackers can simply walk
> around.

---

## Terraform Solution

The full reference build is in [`solution/`](solution/).

```bash
cd solution
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

Set `waf_mode = "Detection"` and re-apply to watch the injection payload sail
straight through while the WAF logs it. That is the difference the mode setting
makes, and it is worth seeing once.

The gateway uses a self-signed certificate, so browsers and `curl` will complain.
That is expected - use `curl -k` or `-SkipCertificateCheck`.

---

## Acceptance Criteria

| # | Criterion |
| --- | --- |
| 1 | An Application Gateway exists with SKU `WAF_v2` |
| 2 | A WAF policy is attached to the gateway |
| 3 | The WAF policy mode is `Prevention` and the policy is enabled |
| 4 | A managed rule set (OWASP) is assigned in the policy |
| 5 | The backend pool addresses the app by hostname, not by IP address |
| 6 | Backend HTTP settings use HTTPS, so traffic is re-encrypted to the backend |
| 7 | The listener is HTTPS with a certificate, so TLS terminates at the gateway |
| 8 | A custom health probe exists and preserves the backend hostname |
| 9 | The web app has public network access `Disabled` |
| 10 | The web app has an approved private endpoint with sub-resource `sites` |
| 11 | `privatelink.azurewebsites.net` is linked to the gateway's VNet and resolves the app privately |
| 12 | (Optional, with `-Probe`) A normal request through the gateway returns 200 |
| 13 | (Optional, with `-Probe`) An injection payload through the gateway is blocked with 403 |
| 14 | (Optional, with `-Probe`) The app's own public hostname does not serve the app |

---

## Validation Script

```bash
pwsh ./validate.ps1 -ResourceGroup rg-lab07 -VnetName vnet-lab07 `
  -AppGatewayName agw-lab07 -WebAppName app-lab07-abc123 -Probe
```

`-Probe` sends three real HTTP requests: one benign, one with an injection
payload, and one straight at the app's public hostname. It skips certificate
validation, because the lab uses a self-signed certificate.

---

## Follow-Up Questions

No answers here on purpose.

1. The gateway resolves the app's hostname through your private DNS zone. What
   would you see, exactly, if that zone link were missing - and would any of your
   tests catch it?
2. TLS terminates at the gateway, so the gateway can read every request body. What
   does that mean for card numbers, passwords and personal data, and who in your
   organisation needs to know it is happening?
3. The WAF blocked your injection payload. What did it actually match on, and what
   is your process when it blocks a legitimate request from a real customer at
   3pm on a Friday?
4. Your certificate lives in Key Vault. Walk through what happens on renewal day -
   which component notices, how quickly, and what happens if the gateway's
   identity lost its role in the meantime?
5. App Service routes by `Host` header. What stops somebody sending a request to
   your gateway with a `Host` header for a completely different app?
6. The gateway is the only way in - until someone creates a second private
   endpoint, or turns public access back on. What control would you put in place
   so that cannot happen quietly?
7. This gateway has one instance. What is your availability story, what does the
   WAF do to your latency budget, and how would you measure both before a launch?

---

## Clean Up

```bash
az group delete -n rg-lab07 --yes --no-wait
```

Application Gateway WAF_v2 and the Premium v3 plan both bill by the hour. This is
one of the more expensive labs - do not leave it running.

---

[Back to the catalogue](../../README.md)
