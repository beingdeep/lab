#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 06 - Key Vault with RBAC and Identity-Only Access.

.DESCRIPTION
    Read-only. Reports a PASS or FAIL line for each acceptance criterion in
    README.md and exits 0 if everything passed, 1 otherwise.

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab06 -VnetName vnet-lab06 `
        -KeyVaultName kv-lab06-abc123 -VmName vm-app -PublicProbe
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$VnetName,
    [string]$KeyVaultName,
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
Write-Host 'Lab 06 - Key Vault with RBAC and Identity-Only Access' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
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
$ResourceGroup = Ask 'Resource group' $ResourceGroup
$VnetName      = Ask 'Virtual network name' $VnetName
$KeyVaultName  = Ask 'Key Vault name' $KeyVaultName
if (-not $DnsResourceGroup) { $DnsResourceGroup = $ResourceGroup }
Write-Host ''

$vnet = Invoke-Az network vnet show -g $ResourceGroup -n $VnetName
if (-not $vnet) {
    Write-Host "Virtual network '$VnetName' not found in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

$kv = Invoke-Az keyvault show -g $ResourceGroup -n $KeyVaultName
if (-not $kv) {
    Write-Host "Key Vault '$KeyVaultName' not found in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Permission model
# ---------------------------------------------------------------------------

Write-Host 'Permission model' -ForegroundColor Cyan

Check 1 'The vault uses the Azure RBAC permission model' `
    ($kv.properties.enableRbacAuthorization -eq $true) `
    $(if ($kv.properties.enableRbacAuthorization -eq $true) { 'enableRbacAuthorization = true, so every grant is a role assignment and shows up in access reviews' }
      else { 'access policy model in use - grants are invisible to access reviews, PIM and role assignment reports' })

$policies = @($kv.properties.accessPolicies)

Check 2 'The vault has no legacy access policies' `
    ($policies.Count -eq 0) `
    $(if ($policies.Count -gt 0) { "$($policies.Count) access polic$(if ($policies.Count -eq 1) { 'y' } else { 'ies' }) still present, granting access that no audit report will mention" }
      else { 'no access policies' })

Check 9 'Soft delete is enabled with at least 7 days retention' `
    ($kv.properties.enableSoftDelete -ne $false -and [int]$kv.properties.softDeleteRetentionInDays -ge 7) `
    "enableSoftDelete = $($kv.properties.enableSoftDelete), retention = $($kv.properties.softDeleteRetentionInDays) days, purgeProtection = $($kv.properties.enablePurgeProtection)"

Write-Host ''

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

Write-Host 'Network' -ForegroundColor Cyan

$pnaOk = ($kv.properties.publicNetworkAccess -eq 'Disabled')
$aclOk = ($kv.properties.networkAcls.defaultAction -eq 'Deny')

Check 3 'Public network access is Disabled and the network ACL default action is Deny' `
    ($pnaOk -and $aclOk) `
    "publicNetworkAccess = $($kv.properties.publicNetworkAccess), networkAcls.defaultAction = $($kv.properties.networkAcls.defaultAction)"

$endpoints = @(Invoke-Az network private-endpoint list -g $ResourceGroup)
$pe = $endpoints | Where-Object {
    $_.privateLinkServiceConnections | Where-Object {
        $_.privateLinkServiceId -eq $kv.id -and $_.groupIds -contains 'vault'
    }
} | Select-Object -First 1

$peState = $null
$peIp = $null
if ($pe) {
    $conn = $pe.privateLinkServiceConnections | Where-Object { $_.privateLinkServiceId -eq $kv.id } | Select-Object -First 1
    $peState = $conn.privateLinkServiceConnectionState.status
    $peIp = ($pe.customDnsConfigs | Select-Object -First 1).ipAddresses | Select-Object -First 1
}

Check 4 'An approved private endpoint exists with sub-resource vault' `
    ($null -ne $pe -and $peState -eq 'Approved') `
    $(if ($pe) { "$($pe.name), connection state $peState, IP $peIp" } else { 'no private endpoint found targeting this vault with group vault' })

$zoneName = 'privatelink.vaultcore.azure.net'
$zone = Invoke-Az network private-dns zone show -g $DnsResourceGroup -n $zoneName
$linked = $false
$recordIp = $null
if ($zone) {
    $links = @(Invoke-Az network private-dns link vnet list -g $DnsResourceGroup -z $zoneName)
    $linked = @($links | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
    $rec = @(Invoke-Az network private-dns record-set a list -g $DnsResourceGroup -z $zoneName) |
        Where-Object { $_.name -eq $KeyVaultName } | Select-Object -First 1
    if ($rec) { $recordIp = ($rec.aRecords | Select-Object -First 1).ipv4Address }
}

Check 5 "$zoneName exists, is linked to the VNet, and resolves the vault privately" `
    ($null -ne $zone -and $linked -and (Test-PrivateIp $recordIp)) `
    $(if (-not $zone) { "zone not found in '$DnsResourceGroup' - check you did not create privatelink.vault.azure.net by mistake" }
      elseif (-not $linked) { "zone exists but has no link to $VnetName" }
      elseif (-not $recordIp) { "zone linked but no A record named '$KeyVaultName'" }
      else { "$KeyVaultName -> $recordIp" })

Write-Host ''

# ---------------------------------------------------------------------------
# Who can read secrets
# ---------------------------------------------------------------------------

Write-Host 'Who can read secrets' -ForegroundColor Cyan

$secretRoles = @('Key Vault Secrets User', 'Key Vault Secrets Officer', 'Key Vault Administrator')
$assignments = @(Invoke-Az role assignment list --scope $kv.id)
$readers = @($assignments | Where-Object { $_.roleDefinitionName -in $secretRoles })

$identityReaders = @($readers | Where-Object { $_.principalType -eq 'ServicePrincipal' })
$humanReaders = @($readers | Where-Object { $_.principalType -in @('User', 'Group') })
$admins = @($assignments | Where-Object { $_.roleDefinitionName -eq 'Key Vault Administrator' })

Check 6 'A secret-reading role is assigned to a managed identity at the vault scope' `
    ($identityReaders.Count -gt 0) `
    $(if ($identityReaders.Count -gt 0) { (($identityReaders | ForEach-Object { "$($_.roleDefinitionName) -> $($_.principalId)" }) -join '; ') }
      else { 'nothing holds a secret-reading role - either the grant is missing, or you removed it for Step 8' })

Check 7 'No user or group holds a secret-reading role at the vault scope' `
    ($humanReaders.Count -eq 0) `
    $(if ($humanReaders.Count -gt 0) { "standing human access: $(($humanReaders | ForEach-Object { "$($_.principalType) $($_.principalId) as $($_.roleDefinitionName)" }) -join '; ')" }
      else { 'no standing human access to secrets' })

Check 8 'No principal holds Key Vault Administrator at the vault scope' `
    ($admins.Count -eq 0) `
    $(if ($admins.Count -gt 0) { "$($admins.Count) administrator assignment(s) - that role can read, write, delete and re-grant" }
      else { 'no vault administrators assigned at this scope' })

Write-Host ''

# ---------------------------------------------------------------------------
# Live checks
# ---------------------------------------------------------------------------

Write-Host 'Live checks' -ForegroundColor Cyan

$fqdn = "$KeyVaultName.vault.azure.net"

if (-not $VmName) {
    Skip 10 'The VM resolves the vault hostname to the private address' 'pass -VmName to run a lookup inside the VM'
}
else {
    $result = Invoke-Az vm run-command invoke -g $ResourceGroup -n $VmName `
        --command-id RunShellScript --scripts "getent hosts $fqdn || echo UNRESOLVED"
    $out = if ($result) { ($result.value | ForEach-Object { $_.message }) -join "`n" } else { '' }
    $ip = if ($out -match '(\d{1,3}(?:\.\d{1,3}){3})') { $Matches[1] } else { $null }

    Check 10 'The VM resolves the vault hostname to the private address' `
        ((Test-PrivateIp $ip) -and (-not $peIp -or $ip -eq $peIp)) `
        $(if (-not $ip) { "no address returned for $fqdn from $VmName" }
          elseif (-not (Test-PrivateIp $ip)) { "$VmName resolved $fqdn to $ip - a public address, so the zone link is missing" }
          else { "$fqdn -> $ip" })
}

if (-not $PublicProbe) {
    Skip 11 'The vault endpoint is not usable from the internet' 'pass -PublicProbe to test, from a machine outside the virtual network'
}
else {
    $status = $null
    $probeError = $null
    try {
        $resp = Invoke-WebRequest -Uri "https://$fqdn/secrets?api-version=7.4" -Method Get -TimeoutSec 15 -SkipHttpErrorCheck
        $status = $resp.StatusCode
    }
    catch {
        $probeError = $_.Exception.Message
    }

    # 401 would mean the endpoint answered and merely wants a token, which is a
    # working public surface. Forbidden or a failed connection is what we want.
    Check 11 'The vault endpoint is not usable from the internet' `
        ($null -ne $probeError -or $status -eq 403) `
        $(if ($probeError) { "https://$fqdn -> request failed: $probeError" }
          else { "https://$fqdn -> HTTP $status (403 expected; 401 means the public endpoint is still answering)" })
}

Write-Host ''
Write-Host '-----------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 06 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 06 acceptance criteria met.' -ForegroundColor Green
exit 0
