#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 07 - Application Gateway with WAF in Front of a Private App.

.DESCRIPTION
    Criteria 1-11 are read-only configuration checks. Criteria 12-14 are opt-in
    and send real HTTP requests through the gateway and at the app.

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab07 -VnetName vnet-lab07 `
        -AppGatewayName agw-lab07 -WebAppName app-lab07-abc123 -Probe
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$VnetName,
    [string]$AppGatewayName,
    [string]$WebAppName,
    [string]$DnsResourceGroup,
    [switch]$Probe
)

$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AzArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = & az @AzArgs 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0 -or -not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Ask {
    param([string]$Prompt, [string]$Current)
    if ($Current) { return $Current }
    do { $v = (Read-Host "  $Prompt").Trim() } while (-not $v)
    return $v
}

function Check {
    param([int]$Number, [string]$Name, [bool]$Ok, [string]$Detail)
    $tag = '{0:d2}' -f $Number
    if ($Ok) { $script:Passed++; Write-Host "  [PASS] $tag  $Name" -ForegroundColor Green }
    else     { $script:Failed++; Write-Host "  [FAIL] $tag  $Name" -ForegroundColor Red }
    if ($Detail) { Write-Host "              $Detail" -ForegroundColor DarkGray }
}

function Skip {
    param([int]$Number, [string]$Name, [string]$Reason)
    $script:Skipped++
    $tag = '{0:d2}' -f $Number
    Write-Host "  [SKIP] $tag  $Name" -ForegroundColor Yellow
    Write-Host "              $Reason" -ForegroundColor DarkGray
}

function Test-PrivateIp {
    param([string]$Ip)
    if (-not $Ip) { return $false }
    return ($Ip -match '^10\.' -or $Ip -match '^192\.168\.' -or $Ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.')
}

function Get-HttpStatus {
    param([string]$Uri)
    try {
        $resp = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 30 -SkipHttpErrorCheck -SkipCertificateCheck
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Status = $null; Error = $_.Exception.Message }
    }
}

Write-Host ''
Write-Host 'Lab 07 - Application Gateway with WAF in Front of a Private App' -ForegroundColor Cyan
Write-Host '===============================================================' -ForegroundColor Cyan
Write-Host ''

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host 'The Azure CLI (az) was not found on PATH. Install it and try again.' -ForegroundColor Red
    exit 1
}

$account = Invoke-Az account show
if (-not $account) {
    Write-Host 'Not signed in. Run "az login" and select your subscription first.' -ForegroundColor Red
    exit 1
}
Write-Host ("Subscription: {0} ({1})" -f $account.name, $account.id) -ForegroundColor DarkGray
Write-Host ''

Write-Host 'Tell me what you named things:' -ForegroundColor Cyan
$ResourceGroup  = Ask 'Resource group' $ResourceGroup
$VnetName       = Ask 'Virtual network name' $VnetName
$AppGatewayName = Ask 'Application Gateway name' $AppGatewayName
$WebAppName     = Ask 'Web app name' $WebAppName
if (-not $DnsResourceGroup) { $DnsResourceGroup = $ResourceGroup }
Write-Host ''

$vnet = Invoke-Az network vnet show -g $ResourceGroup -n $VnetName
$agw  = Invoke-Az network application-gateway show -g $ResourceGroup -n $AppGatewayName
$app  = Invoke-Az webapp show -g $ResourceGroup -n $WebAppName

foreach ($pair in @(@($vnet, "virtual network '$VnetName'"), @($agw, "application gateway '$AppGatewayName'"), @($app, "web app '$WebAppName'"))) {
    if (-not $pair[0]) {
        Write-Host "Could not find $($pair[1]) in '$ResourceGroup'. Cannot continue." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# The gateway
# ---------------------------------------------------------------------------

Write-Host 'Gateway' -ForegroundColor Cyan

Check 1 'The Application Gateway SKU is WAF_v2' `
    ($agw.sku.name -eq 'WAF_v2' -and $agw.sku.tier -eq 'WAF_v2') `
    "sku = $($agw.sku.name) / tier = $($agw.sku.tier), capacity $($agw.sku.capacity)"

$policyId = $agw.firewallPolicy.id
$policy = if ($policyId) { Invoke-Az network application-gateway waf-policy show --ids $policyId } else { $null }

Check 2 'A WAF policy is attached to the gateway' `
    ($null -ne $policy) `
    $(if ($policy) { "$($policy.name)" } else { 'no firewallPolicy on the gateway - a WAF_v2 SKU with no policy inspects nothing' })

$mode = if ($policy) { $policy.policySettings.mode } else { $null }
$enabled = if ($policy) { $policy.policySettings.state -eq 'Enabled' -or $policy.policySettings.enabled -eq $true } else { $false }

Check 3 'The WAF policy mode is Prevention and the policy is enabled' `
    ($mode -eq 'Prevention' -and $enabled) `
    $(if (-not $policy) { 'no policy' }
      elseif ($mode -ne 'Prevention') { "mode = $mode - attacks are logged and then served to the backend anyway" }
      elseif (-not $enabled) { 'policy is disabled' }
      else { 'mode = Prevention, state = Enabled' })

$managedSets = if ($policy) { @($policy.managedRules.managedRuleSets) } else { @() }
$owasp = @($managedSets | Where-Object { $_.ruleSetType -match 'OWASP|Microsoft_DefaultRuleSet' })

Check 4 'A managed rule set is assigned in the policy' `
    ($owasp.Count -gt 0) `
    $(if ($owasp.Count -gt 0) { (($owasp | ForEach-Object { "$($_.ruleSetType) $($_.ruleSetVersion)" }) -join ', ') }
      else { 'no managed rule set - the WAF has no signatures to match against' })

Write-Host ''

# ---------------------------------------------------------------------------
# The path to the backend
# ---------------------------------------------------------------------------

Write-Host 'Backend path' -ForegroundColor Cyan

$pool = @($agw.backendAddressPools) | Select-Object -First 1
$poolFqdns = @()
$poolIps = @()
foreach ($p in @($agw.backendAddressPools)) {
    foreach ($addr in @($p.backendAddresses)) {
        if ($addr.fqdn) { $poolFqdns += $addr.fqdn }
        if ($addr.ipAddress) { $poolIps += $addr.ipAddress }
    }
}

Check 5 'The backend pool addresses the app by hostname, not by IP address' `
    ($poolFqdns.Count -gt 0 -and $poolIps.Count -eq 0) `
    $(if ($poolIps.Count -gt 0) { "pool contains IP addresses ($($poolIps -join ', ')) - App Service routes by Host header and will return 404" }
      elseif ($poolFqdns.Count -eq 0) { 'backend pool is empty' }
      else { "fqdns: $($poolFqdns -join ', ')" })

$settings = @($agw.backendHttpSettingsCollection)
$httpsSettings = @($settings | Where-Object { $_.protocol -eq 'Https' })

Check 6 'Backend HTTP settings use HTTPS, so traffic is re-encrypted to the backend' `
    ($httpsSettings.Count -gt 0) `
    $(if ($httpsSettings.Count -gt 0) { (($httpsSettings | ForEach-Object { "$($_.name): $($_.protocol):$($_.port), pickHostNameFromBackendAddress = $($_.pickHostNameFromBackendAddress)" }) -join '; ') }
      else { "all backend settings use $((($settings | ForEach-Object { $_.protocol }) | Sort-Object -Unique) -join ', ') - the second hop is plaintext" })

$listeners = @($agw.httpListeners)
$httpsListeners = @($listeners | Where-Object { $_.protocol -eq 'Https' -and $_.sslCertificate })

Check 7 'The listener is HTTPS with a certificate, so TLS terminates at the gateway' `
    ($httpsListeners.Count -gt 0) `
    $(if ($httpsListeners.Count -gt 0) { (($httpsListeners | ForEach-Object { "$($_.name) on $($_.protocol), certificate $(Split-Path $_.sslCertificate.id -Leaf)" }) -join '; ') }
      else { 'no HTTPS listener with a certificate - nothing is terminating TLS, so the WAF cannot read request bodies' })

$probes = @($agw.probes)
$hostPreservingProbe = @($probes | Where-Object { $_.pickHostNameFromBackendHttpSettings -eq $true })
$probeReferenced = @($settings | Where-Object { $_.probe }).Count -gt 0

Check 8 'A custom health probe exists, preserves the backend hostname, and is referenced' `
    ($hostPreservingProbe.Count -gt 0 -and $probeReferenced) `
    $(if ($probes.Count -eq 0) { 'no custom probe - the default probe sends the backend IP as the Host header and App Service answers 404, so the pool shows unhealthy' }
      elseif ($hostPreservingProbe.Count -eq 0) { 'a probe exists but does not pick the host name from the backend settings' }
      elseif (-not $probeReferenced) { 'a probe exists but no backend settings reference it' }
      else { "$($hostPreservingProbe[0].name), path $($hostPreservingProbe[0].path)" })

Write-Host ''

# ---------------------------------------------------------------------------
# The app stays private
# ---------------------------------------------------------------------------

Write-Host 'App privacy' -ForegroundColor Cyan

$pna = $app.publicNetworkAccess
if (-not $pna) {
    $props = Invoke-Az resource show --ids $app.id --query properties
    if ($props) { $pna = $props.publicNetworkAccess }
}

Check 9 'The web app has public network access Disabled' `
    ($pna -eq 'Disabled') `
    "publicNetworkAccess = $(if ($pna) { $pna } else { '<not set>' }) - if this is enabled, attackers simply bypass your gateway"

$endpoints = @(Invoke-Az network private-endpoint list -g $ResourceGroup)
$pe = $endpoints | Where-Object {
    $_.privateLinkServiceConnections | Where-Object {
        $_.privateLinkServiceId -eq $app.id -and $_.groupIds -contains 'sites'
    }
} | Select-Object -First 1
$peState = if ($pe) { ($pe.privateLinkServiceConnections | Select-Object -First 1).privateLinkServiceConnectionState.status } else { $null }

Check 10 'The web app has an approved private endpoint with sub-resource sites' `
    ($null -ne $pe -and $peState -eq 'Approved') `
    $(if ($pe) { "$($pe.name), connection state $peState" } else { 'no private endpoint found for this app' })

$zoneName = 'privatelink.azurewebsites.net'
$zone = Invoke-Az network private-dns zone show -g $DnsResourceGroup -n $zoneName
$linked = $false
$recordIp = $null
if ($zone) {
    $links = @(Invoke-Az network private-dns link vnet list -g $DnsResourceGroup -z $zoneName)
    $linked = @($links | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
    $rec = @(Invoke-Az network private-dns record-set a list -g $DnsResourceGroup -z $zoneName) |
        Where-Object { $_.name -eq $WebAppName } | Select-Object -First 1
    if ($rec) { $recordIp = ($rec.aRecords | Select-Object -First 1).ipv4Address }
}

Check 11 "$zoneName is linked to the gateway's VNet and resolves the app privately" `
    ($null -ne $zone -and $linked -and (Test-PrivateIp $recordIp)) `
    $(if (-not $zone) { "zone not found in '$DnsResourceGroup'" }
      elseif (-not $linked) { "zone exists but is not linked to $VnetName - the gateway will resolve the public address and reach your backend over the internet, and nothing will look wrong" }
      elseif (-not $recordIp) { "zone linked but no A record named '$WebAppName'" }
      else { "$WebAppName -> $recordIp" })

Write-Host ''

# ---------------------------------------------------------------------------
# Live requests
# ---------------------------------------------------------------------------

Write-Host 'Live requests' -ForegroundColor Cyan

if (-not $Probe) {
    Skip 12 'A normal request through the gateway returns 200' 'pass -Probe to send real HTTP requests'
    Skip 13 'An injection payload through the gateway is blocked with 403' 'pass -Probe to send real HTTP requests'
    Skip 14 'The app public hostname does not serve the app' 'pass -Probe to send real HTTP requests'
}
else {
    $feIpId = ($agw.frontendIPConfigurations | Where-Object { $_.publicIPAddress } | Select-Object -First 1).publicIPAddress.id
    $pip = if ($feIpId) { Invoke-Az network public-ip show --ids $feIpId } else { $null }
    $gatewayIp = if ($pip) { $pip.ipAddress } else { $null }

    if (-not $gatewayIp) {
        Check 12 'A normal request through the gateway returns 200' $false 'could not determine the gateway public IP'
        Check 13 'An injection payload through the gateway is blocked with 403' $false 'could not determine the gateway public IP'
    }
    else {
        Write-Host "              gateway at https://$gatewayIp" -ForegroundColor DarkGray

        $normal = Get-HttpStatus "https://$gatewayIp/"
        Check 12 'A normal request through the gateway returns 200' `
            ($normal.Status -eq 200) `
            $(if ($normal.Error) { "request failed: $($normal.Error)" }
              else { "HTTP $($normal.Status) - 502 usually means the backend pool is unhealthy, which is normally the probe or the Host header" })

        $payload = "https://$gatewayIp/?id=1%27%20or%20%271%27=%271"
        $attack = Get-HttpStatus $payload
        Check 13 'An injection payload through the gateway is blocked with 403' `
            ($attack.Status -eq 403) `
            $(if ($attack.Error) { "request failed: $($attack.Error)" }
              elseif ($attack.Status -eq 200) { "HTTP 200 - the payload reached the backend. Check the policy is in Prevention mode, not Detection" }
              else { "HTTP $($attack.Status)" })
    }

    $appHost = $app.defaultHostName
    $direct = Get-HttpStatus "https://$appHost/"
    Check 14 'The app public hostname does not serve the app' `
        ($null -ne $direct.Error -or $direct.Status -ne 200) `
        $(if ($direct.Error) { "https://$appHost -> request failed: $($direct.Error)" }
          else { "https://$appHost -> HTTP $($direct.Status) (403 expected; 200 means your WAF can simply be walked around)" })
}

Write-Host ''
Write-Host '---------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 07 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 07 acceptance criteria met.' -ForegroundColor Green
exit 0
