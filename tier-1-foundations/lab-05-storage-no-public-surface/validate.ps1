#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 05 - Storage Account with No Public Surface.

.DESCRIPTION
    Read-only. Reports a PASS or FAIL line for each acceptance criterion in
    README.md and exits 0 if everything passed, 1 otherwise.

    Assumes you are already signed in ("az login") and that the correct
    subscription is selected ("az account set --subscription <id>").

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab05 -VnetName vnet-lab05 `
        -StorageAccountName stglab05abc123 -VmName vm-app -PublicProbe
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$VnetName,
    [string]$StorageAccountName,
    [string]$DnsResourceGroup,
    [string]$VmName,
    [switch]$PublicProbe
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

Write-Host ''
Write-Host 'Lab 05 - Storage Account with No Public Surface' -ForegroundColor Cyan
Write-Host '===============================================' -ForegroundColor Cyan
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
$ResourceGroup      = Ask 'Resource group' $ResourceGroup
$VnetName           = Ask 'Virtual network name' $VnetName
$StorageAccountName = Ask 'Storage account name' $StorageAccountName
if (-not $DnsResourceGroup) { $DnsResourceGroup = $ResourceGroup }
Write-Host ''

$vnet = Invoke-Az network vnet show -g $ResourceGroup -n $VnetName
if (-not $vnet) {
    Write-Host "Virtual network '$VnetName' not found in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

$sa = Invoke-Az storage account show -g $ResourceGroup -n $StorageAccountName
if (-not $sa) {
    Write-Host "Storage account '$StorageAccountName' not found in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Account settings
# ---------------------------------------------------------------------------

Write-Host 'Account settings' -ForegroundColor Cyan

Check 1 'Public network access is Disabled' `
    ($sa.publicNetworkAccess -eq 'Disabled') `
    "publicNetworkAccess = $($sa.publicNetworkAccess)"

# The property is absent on older accounts and means "enabled" when absent.
$sharedKey = $sa.allowSharedKeyAccess
Check 2 'Shared key authorisation is disabled' `
    ($sharedKey -eq $false) `
    $(if ($sharedKey -eq $false) { 'allowSharedKeyAccess = false, so every data-plane role assignment is actually enforced' }
      else { 'allowSharedKeyAccess is not false - anyone who can read the account keys bypasses all of your RBAC, as nobody' })

$anonOk = ($sa.allowBlobPublicAccess -eq $false)
$tlsOk = ($sa.minimumTlsVersion -eq 'TLS1_2')
Check 3 'Anonymous blob access is disabled and minimum TLS is 1.2' `
    ($anonOk -and $tlsOk) `
    "allowBlobPublicAccess = $($sa.allowBlobPublicAccess), minimumTlsVersion = $($sa.minimumTlsVersion)"

Check 4 'The account defaults to Entra authorisation' `
    ($sa.defaultToOAuthAuthentication -eq $true) `
    "defaultToOAuthAuthentication = $($sa.defaultToOAuthAuthentication)"

Check 5 'Network rules default action is Deny' `
    ($sa.networkRuleSet.defaultAction -eq 'Deny') `
    "defaultAction = $($sa.networkRuleSet.defaultAction)"

Write-Host ''

# ---------------------------------------------------------------------------
# Private endpoint and DNS
# ---------------------------------------------------------------------------

Write-Host 'Private endpoint and DNS' -ForegroundColor Cyan

$endpoints = @(Invoke-Az network private-endpoint list -g $ResourceGroup)
$pe = $endpoints | Where-Object {
    $_.privateLinkServiceConnections | Where-Object {
        $_.privateLinkServiceId -eq $sa.id -and $_.groupIds -contains 'blob'
    }
} | Select-Object -First 1

$peState = $null
$peIp = $null
if ($pe) {
    $conn = $pe.privateLinkServiceConnections | Where-Object { $_.privateLinkServiceId -eq $sa.id } | Select-Object -First 1
    $peState = $conn.privateLinkServiceConnectionState.status
    $peIp = ($pe.customDnsConfigs | Select-Object -First 1).ipAddresses | Select-Object -First 1
}

Check 6 'An approved private endpoint exists with sub-resource blob' `
    ($null -ne $pe -and $peState -eq 'Approved') `
    $(if ($pe) { "$($pe.name), connection state $peState, IP $peIp" } else { 'no private endpoint found targeting this account with group blob' })

$zoneName = 'privatelink.blob.core.windows.net'
$zone = Invoke-Az network private-dns zone show -g $DnsResourceGroup -n $zoneName
$linked = $false
$recordIp = $null
if ($zone) {
    $links = @(Invoke-Az network private-dns link vnet list -g $DnsResourceGroup -z $zoneName)
    $linked = @($links | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
    $rec = @(Invoke-Az network private-dns record-set a list -g $DnsResourceGroup -z $zoneName) |
        Where-Object { $_.name -eq $StorageAccountName } | Select-Object -First 1
    if ($rec) { $recordIp = ($rec.aRecords | Select-Object -First 1).ipv4Address }
}

Check 7 "$zoneName exists, is linked to the VNet, and resolves privately" `
    ($null -ne $zone -and $linked -and (Test-PrivateIp $recordIp)) `
    $(if (-not $zone) { "zone not found in '$DnsResourceGroup'" }
      elseif (-not $linked) { "zone exists but has no link to $VnetName" }
      elseif (-not $recordIp) { "zone linked but no A record named '$StorageAccountName' - the endpoint has no DNS zone group" }
      else { "$StorageAccountName -> $recordIp" })

Write-Host ''

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

Write-Host 'Permissions' -ForegroundColor Cyan

# Assignments made at the account scope itself. Without --include-inherited the
# CLI does not walk up to the subscription, which is what we want here.
$assignments = @(Invoke-Az role assignment list --scope $sa.id)

# Containers are enumerated through Resource Manager, not the storage data plane,
# so this still works with the public endpoint closed.
$containerAssignments = @()
$containerList = Invoke-Az rest --method get --url "https://management.azure.com$($sa.id)/blobServices/default/containers?api-version=2023-01-01"
foreach ($c in @($containerList.value)) {
    $containerAssignments += @(Invoke-Az role assignment list --scope $c.id)
}
$allAssignments = @($assignments) + @($containerAssignments)

$dataRoles = @($allAssignments | Where-Object { $_.roleDefinitionName -like 'Storage Blob Data*' })

Check 8 'A Storage Blob Data role is assigned at the account or a container' `
    ($dataRoles.Count -gt 0) `
    $(if ($dataRoles.Count -gt 0) { (($dataRoles | ForEach-Object { "$($_.roleDefinitionName) -> $($_.principalType) $($_.principalId)" }) -join '; ') }
      else { 'no data-plane role assignments found - with keys disabled, nothing can read a blob' })

$keyReaders = @($assignments | Where-Object { $_.roleDefinitionName -in @('Owner', 'Contributor', 'Storage Account Contributor') })

Check 9 'No key-reading role is assigned directly at the account scope' `
    ($keyReaders.Count -eq 0) `
    $(if ($keyReaders.Count -gt 0) { "these can read the account keys and bypass your data-plane RBAC: $(($keyReaders | ForEach-Object { "$($_.roleDefinitionName) -> $($_.principalId)" }) -join '; ')" }
      else { 'nothing at account scope can list keys' })

Write-Host ''

# ---------------------------------------------------------------------------
# Live checks
# ---------------------------------------------------------------------------

Write-Host 'Live checks' -ForegroundColor Cyan

$fqdn = "$StorageAccountName.blob.core.windows.net"

if (-not $VmName) {
    Skip 10 'The VM resolves the blob endpoint to the private address' 'pass -VmName to run a lookup inside the VM'
}
else {
    $result = Invoke-Az vm run-command invoke -g $ResourceGroup -n $VmName `
        --command-id RunShellScript --scripts "getent hosts $fqdn || echo UNRESOLVED"
    $out = if ($result) { ($result.value | ForEach-Object { $_.message }) -join "`n" } else { '' }
    $ip = if ($out -match '(\d{1,3}(?:\.\d{1,3}){3})') { $Matches[1] } else { $null }

    Check 10 'The VM resolves the blob endpoint to the private address' `
        ((Test-PrivateIp $ip) -and (-not $peIp -or $ip -eq $peIp)) `
        $(if (-not $ip) { "no address returned for $fqdn from $VmName" }
          elseif (-not (Test-PrivateIp $ip)) { "$VmName resolved $fqdn to $ip - a public address, so the zone link is missing" }
          elseif ($peIp -and $ip -ne $peIp) { "resolved to $ip but the endpoint is at $peIp" }
          else { "$fqdn -> $ip" })
}

if (-not $PublicProbe) {
    Skip 11 'The blob endpoint is not usable from the internet' 'pass -PublicProbe to test, from a machine outside the virtual network'
}
else {
    $status = $null
    $probeError = $null
    try {
        $resp = Invoke-WebRequest -Uri "https://$fqdn/?comp=list" -Method Get -TimeoutSec 15 -SkipHttpErrorCheck
        $status = $resp.StatusCode
    }
    catch {
        $probeError = $_.Exception.Message
    }

    Check 11 'The blob endpoint is not usable from the internet' `
        ($status -ne 200) `
        $(if ($probeError) { "https://$fqdn -> request failed: $probeError" }
          else { "https://$fqdn -> HTTP $status (403 is the expected result)" })
}

Write-Host ''
Write-Host '-----------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 05 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 05 acceptance criteria met.' -ForegroundColor Green
exit 0
