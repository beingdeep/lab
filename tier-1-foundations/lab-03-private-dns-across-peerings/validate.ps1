#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 03 - Private DNS Resolution Across Peered Networks.

.DESCRIPTION
    Read-only for criteria 1-10. Criterion 11 is opt-in and runs nslookup inside
    your VMs via "az vm run-command invoke"; it changes nothing but does execute
    a command in the guest.

    Reports a PASS or FAIL line per acceptance criterion in README.md and exits
    0 if everything passed, 1 otherwise.

    Assumes you are already signed in ("az login") and that the correct
    subscription is selected ("az account set --subscription <id>").

.EXAMPLE
    pwsh ./validate.ps1

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab03 -DnsResourceGroup rg-lab03-dns `
        -VnetNames vnet-a,vnet-b,vnet-c -LiveDnsTest -VmNames vm-a,vm-b,vm-c
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$DnsResourceGroup,
    [string[]]$VnetNames,
    [string[]]$VmNames,
    [switch]$LiveDnsTest
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Lab 03 - Private DNS Resolution Across Peered Networks' -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
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
$ResourceGroup = Ask 'Resource group holding the VNets and private endpoints' $ResourceGroup
if (-not $DnsResourceGroup) {
    $answer = (Read-Host "  Resource group holding the private DNS zones [$ResourceGroup]").Trim()
    $DnsResourceGroup = if ($answer) { $answer } else { $ResourceGroup }
}
if (-not $VnetNames -or $VnetNames.Count -lt 3) {
    $answer = Ask 'The three VNet names, comma separated' $null
    $VnetNames = $answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
Write-Host ''

if ($VnetNames.Count -ne 3) {
    Write-Host "Expected three VNet names, got $($VnetNames.Count)." -ForegroundColor Red
    exit 1
}

if (-not (Invoke-Az group show -n $ResourceGroup)) {
    Write-Host "Resource group '$ResourceGroup' not found in this subscription." -ForegroundColor Red
    exit 1
}

$vnets = @()
foreach ($n in $VnetNames) {
    $v = Invoke-Az network vnet show -g $ResourceGroup -n $n
    if (-not $v) {
        Write-Host "Virtual network '$n' not found in '$ResourceGroup'. Cannot continue." -ForegroundColor Red
        exit 1
    }
    $vnets += $v
}

# ---------------------------------------------------------------------------
# Networks
# ---------------------------------------------------------------------------

Write-Host 'Networks' -ForegroundColor Cyan

Check 1 'All three virtual networks exist' `
    ($vnets.Count -eq 3) `
    (($vnets | ForEach-Object { "$($_.name) $($_.addressSpace.addressPrefixes[0])" }) -join '   ')

$missingPeerings = @()
foreach ($src in $vnets) {
    $peerings = @(Invoke-Az network vnet peering list -g $ResourceGroup --vnet-name $src.name)
    foreach ($dst in $vnets) {
        if ($dst.id -eq $src.id) { continue }
        $p = $peerings | Where-Object { $_.remoteVirtualNetwork.id -eq $dst.id } | Select-Object -First 1
        if (-not $p) { $missingPeerings += "$($src.name) -> $($dst.name) (absent)" }
        elseif ($p.peeringState -ne 'Connected') { $missingPeerings += "$($src.name) -> $($dst.name) ($($p.peeringState))" }
    }
}

Check 2 'The three VNets are peered in a full mesh and every peering is Connected' `
    ($missingPeerings.Count -eq 0) `
    $(if ($missingPeerings.Count -gt 0) { "problems: $($missingPeerings -join ', ')" } else { 'all 6 directional peerings present and Connected' })

$customDns = @()
foreach ($v in $vnets) {
    $servers = @()
    if ($v.dhcpOptions -and $v.dhcpOptions.dnsServers) { $servers = @($v.dhcpOptions.dnsServers) }
    if ($servers.Count -gt 0) { $customDns += "$($v.name) -> $($servers -join ', ')" }
}

Check 3 'Every VNet uses Azure-provided DNS (no custom DNS servers)' `
    ($customDns.Count -eq 0) `
    $(if ($customDns.Count -gt 0) { "custom DNS set on: $($customDns -join '; ') - private zones will not apply to these clients" }
      else { 'all three VNets resolve via 168.63.129.16' })

Write-Host ''

# ---------------------------------------------------------------------------
# Private endpoints
# ---------------------------------------------------------------------------

Write-Host 'Private endpoints' -ForegroundColor Cyan

$vnetIds = $vnets | ForEach-Object { $_.id }
$allEndpoints = @(Invoke-Az network private-endpoint list -g $ResourceGroup)
$endpoints = @($allEndpoints | Where-Object {
    $sid = $_.subnet.id
    @($vnetIds | Where-Object { $sid -like "$_/subnets/*" }).Count -gt 0
})

if ($endpoints.Count -eq 0) {
    Write-Host "  No private endpoints found in '$ResourceGroup' inside those VNets." -ForegroundColor Red
}

$peInfo = @()
foreach ($pe in $endpoints) {
    $nicIp = $null
    foreach ($nicRef in @($pe.networkInterfaces)) {
        $nic = Invoke-Az network nic show --ids $nicRef.id
        if ($nic) { $nicIp = ($nic.ipConfigurations | Select-Object -First 1).privateIPAddress; break }
    }
    $conn = @($pe.privateLinkServiceConnections) | Select-Object -First 1
    $zoneGroups = @(Invoke-Az network private-endpoint dns-zone-group list -g $ResourceGroup --endpoint-name $pe.name)
    $peInfo += [pscustomobject]@{
        Name       = $pe.name
        GroupId    = if ($conn) { ($conn.groupIds | Select-Object -First 1) } else { $null }
        State      = if ($conn) { $conn.privateLinkServiceConnectionState.status } else { $null }
        TargetName = if ($conn -and $conn.privateLinkServiceId) { Split-Path $conn.privateLinkServiceId -Leaf } else { $null }
        Ip         = $nicIp
        ZoneGroups = $zoneGroups
    }
}

$expectedZones = @{
    'blob'      = 'privatelink.blob.core.windows.net'
    'vault'     = 'privatelink.vaultcore.azure.net'
    'sqlServer' = 'privatelink.database.windows.net'
}

$zoneNames = @()
foreach ($p in $peInfo) {
    if ($p.GroupId -and $expectedZones.ContainsKey($p.GroupId)) { $zoneNames += $expectedZones[$p.GroupId] }
}
$zoneNames = @($zoneNames | Sort-Object -Unique)

$noZoneGroup = @($peInfo | Where-Object { -not $_.ZoneGroups -or $_.ZoneGroups.Count -eq 0 })
$notApproved = @($peInfo | Where-Object { $_.State -ne 'Approved' })

Write-Host ("  Discovered {0} private endpoint(s): {1}" -f $peInfo.Count,
    (($peInfo | ForEach-Object { "$($_.Name) [$($_.GroupId)] $($_.Ip)" }) -join ', ')) -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# Zones and links
# ---------------------------------------------------------------------------

Write-Host 'Private DNS zones' -ForegroundColor Cyan

if ($zoneNames.Count -eq 0) {
    $zoneNames = @($expectedZones.Values)
}

$zones = @{}
$missingZones = @()
foreach ($zn in $zoneNames) {
    $z = Invoke-Az network private-dns zone show -g $DnsResourceGroup -n $zn
    if ($z) { $zones[$zn] = $z } else { $missingZones += $zn }
}

Check 4 'All required private DNS zones exist with the exact private link names' `
    ($missingZones.Count -eq 0 -and $zones.Count -gt 0) `
    $(if ($missingZones.Count -gt 0) { "not found in '$DnsResourceGroup': $($missingZones -join ', ')" }
      else { "$($zones.Count) zones: $(($zones.Keys | Sort-Object) -join ', ')" })

$linkProblems = @()
$registrationProblems = @()
$totalLinks = 0
foreach ($zn in $zones.Keys) {
    $links = @(Invoke-Az network private-dns link vnet list -g $DnsResourceGroup -z $zn)
    $totalLinks += $links.Count
    foreach ($v in $vnets) {
        $l = $links | Where-Object { $_.virtualNetwork.id -eq $v.id } | Select-Object -First 1
        if (-not $l) { $linkProblems += "$zn is not linked to $($v.name)" }
        elseif ($l.registrationEnabled -eq $true) { $registrationProblems += "$zn / $($l.name)" }
    }
}

$expectedLinkCount = $zones.Count * 3

Check 5 "Each zone is linked to all three VNets ($expectedLinkCount links expected)" `
    ($linkProblems.Count -eq 0 -and $zones.Count -gt 0) `
    $(if ($linkProblems.Count -gt 0) { "$($linkProblems -join '; ') - clients in those VNets fall back to public resolution" }
      else { "$totalLinks links present across $($zones.Count) zones" })

Check 6 'Every VNet link has registration disabled' `
    ($registrationProblems.Count -eq 0) `
    $(if ($registrationProblems.Count -gt 0) { "registration enabled on: $($registrationProblems -join ', ')" }
      else { 'all links are resolution-only' })

Check 7 'Every private endpoint has a DNS zone group attached' `
    ($peInfo.Count -gt 0 -and $noZoneGroup.Count -eq 0) `
    $(if ($peInfo.Count -eq 0) { 'no private endpoints found' }
      elseif ($noZoneGroup.Count -gt 0) { "missing zone group on: $(($noZoneGroup | ForEach-Object { $_.Name }) -join ', ') - these endpoints have no A record anywhere" }
      else { "$($peInfo.Count) endpoints, all with a zone group" })

Check 8 'Every private endpoint connection is Approved' `
    ($peInfo.Count -gt 0 -and $notApproved.Count -eq 0) `
    $(if ($peInfo.Count -eq 0) { 'no private endpoints found' }
      elseif ($notApproved.Count -gt 0) { "not approved: $(($notApproved | ForEach-Object { "$($_.Name) [$($_.State)]" }) -join ', ')" }
      else { (($peInfo | ForEach-Object { "$($_.Name) -> $($_.TargetName) $($_.Ip)" }) -join '; ') })

$recordProblems = @()
$publicRecords = @()
$recordSummary = @()
foreach ($zn in $zones.Keys) {
    $records = @(Invoke-Az network private-dns record-set a list -g $DnsResourceGroup -z $zn)
    $peForZone = @($peInfo | Where-Object { $_.GroupId -and $expectedZones[$_.GroupId] -eq $zn })
    foreach ($p in $peForZone) {
        $r = $records | Where-Object { $_.name -eq $p.TargetName } | Select-Object -First 1
        if (-not $r) {
            $recordProblems += "$zn has no A record named '$($p.TargetName)'"
            continue
        }
        $ip = ($r.aRecords | Select-Object -First 1).ipv4Address
        $recordSummary += "$($p.TargetName).$zn -> $ip"
        if ($p.Ip -and $ip -ne $p.Ip) {
            $recordProblems += "$($p.TargetName): zone says $ip but the endpoint NIC is $($p.Ip)"
        }
        if (-not (Test-PrivateIp $ip)) { $publicRecords += "$($p.TargetName) -> $ip" }
    }
}

Check 9 'Each zone A record matches its private endpoint NIC address' `
    ($recordProblems.Count -eq 0 -and $recordSummary.Count -gt 0) `
    $(if ($recordSummary.Count -eq 0) { 'no records could be matched to endpoints' }
      elseif ($recordProblems.Count -gt 0) { $recordProblems -join '; ' }
      else { $recordSummary -join '; ' })

Check 10 'Every A record resolves to a private address' `
    ($publicRecords.Count -eq 0 -and $recordSummary.Count -gt 0) `
    $(if ($publicRecords.Count -gt 0) { "public addresses found: $($publicRecords -join ', ')" }
      elseif ($recordSummary.Count -eq 0) { 'no records to check' }
      else { 'all records point inside the VNet address space' })

Write-Host ''

# ---------------------------------------------------------------------------
# Live resolution from inside the VNets
# ---------------------------------------------------------------------------

Write-Host 'Live resolution' -ForegroundColor Cyan

if (-not $LiveDnsTest) {
    Skip 11 'Every VM resolves all three service names to private addresses' 'pass -LiveDnsTest with -VmNames to run nslookup inside the VMs'
}
elseif (-not $VmNames -or $VmNames.Count -lt 1) {
    Skip 11 'Every VM resolves all three service names to private addresses' '-LiveDnsTest was given but -VmNames was not'
}
else {
    # Build the public FQDNs the workloads would actually use.
    $fqdnSuffix = @{
        'privatelink.blob.core.windows.net'   = 'blob.core.windows.net'
        'privatelink.vaultcore.azure.net'     = 'vault.azure.net'
        'privatelink.database.windows.net'    = 'database.windows.net'
    }
    $targets = @()
    foreach ($p in $peInfo) {
        if (-not $p.GroupId -or -not $expectedZones.ContainsKey($p.GroupId)) { continue }
        $zn = $expectedZones[$p.GroupId]
        $targets += [pscustomobject]@{ Fqdn = "$($p.TargetName).$($fqdnSuffix[$zn])"; Expected = $p.Ip }
    }

    $failures = @()
    $observed = @()
    foreach ($vm in $VmNames) {
        $script = ($targets | ForEach-Object { "getent hosts $($_.Fqdn) || echo 'UNRESOLVED $($_.Fqdn)'" }) -join '; '
        Write-Host "              querying from $vm ..." -ForegroundColor DarkGray
        $result = Invoke-Az vm run-command invoke -g $ResourceGroup -n $vm `
            --command-id RunShellScript --scripts $script
        $out = if ($result) { ($result.value | ForEach-Object { $_.message }) -join "`n" } else { '' }

        foreach ($t in $targets) {
            $line = ($out -split "`n" | Where-Object { $_ -match [regex]::Escape($t.Fqdn) } | Select-Object -First 1)
            if (-not $line -or $line -match 'UNRESOLVED') {
                $failures += "$vm could not resolve $($t.Fqdn)"
                continue
            }
            $ip = if ($line -match '(\d{1,3}(?:\.\d{1,3}){3})') { $Matches[1] } else { $null }
            $observed += "$vm : $($t.Fqdn) -> $ip"
            if (-not (Test-PrivateIp $ip)) {
                $failures += "$vm resolved $($t.Fqdn) to public address $ip"
            }
            elseif ($t.Expected -and $ip -ne $t.Expected) {
                $failures += "$vm resolved $($t.Fqdn) to $ip, expected $($t.Expected)"
            }
        }
    }

    Check 11 'Every VM resolves all three service names to private addresses' `
        ($failures.Count -eq 0 -and $observed.Count -gt 0) `
        $(if ($failures.Count -gt 0) { $failures -join '; ' }
          elseif ($observed.Count -eq 0) { 'no lookups returned anything - are the VMs running?' }
          else { "$($observed.Count) lookups, all private: $($observed -join '; ')" })
}

Write-Host ''

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host '------------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 03 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 03 acceptance criteria met.' -ForegroundColor Green
exit 0
