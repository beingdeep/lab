#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 12 - Private AKS Cluster.

.DESCRIPTION
    Read-only for criteria 1-10. Criterion 11 is opt-in and runs a name lookup
    inside the jump host.

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab12 -VnetName vnet-lab12 `
        -ClusterName aks-lab12 -VmName vm-jump
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$VnetName,
    [string]$ClusterName,
    [string]$VmName
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

function ConvertTo-UInt32Ip {
    param([string]$Ip)
    $parts = $Ip.Split('.')
    return ([uint32]$parts[0] -shl 24) -bor ([uint32]$parts[1] -shl 16) -bor ([uint32]$parts[2] -shl 8) -bor [uint32]$parts[3]
}

function Get-CidrRange {
    param([string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') { return $null }
    $base = ConvertTo-UInt32Ip $Matches[1]
    $bits = [int]$Matches[2]
    $mask = if ($bits -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $bits)) }
    $start = $base -band $mask
    $end = $start -bor (-bnot $mask -band [uint32]::MaxValue)
    return [pscustomobject]@{ Start = $start; End = $end }
}

function Test-CidrOverlap {
    param([string]$A, [string]$B)
    $ra = Get-CidrRange $A
    $rb = Get-CidrRange $B
    if (-not $ra -or -not $rb) { return $false }
    return ($ra.Start -le $rb.End -and $rb.Start -le $ra.End)
}

function Test-IpInCidr {
    param([string]$Ip, [string]$Cidr)
    $r = Get-CidrRange $Cidr
    if (-not $r) { return $false }
    if ($Ip -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') { return $false }
    $v = ConvertTo-UInt32Ip $Ip
    return ($v -ge $r.Start -and $v -le $r.End)
}

function Test-PrivateIp {
    param([string]$Ip)
    if (-not $Ip) { return $false }
    return ($Ip -match '^10\.' -or $Ip -match '^192\.168\.' -or $Ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.')
}

Write-Host ''
Write-Host 'Lab 12 - Private AKS Cluster' -ForegroundColor Cyan
Write-Host '============================' -ForegroundColor Cyan
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
$ClusterName   = Ask 'AKS cluster name' $ClusterName
Write-Host ''

$vnet = Invoke-Az network vnet show -g $ResourceGroup -n $VnetName
$aks  = Invoke-Az aks show -g $ResourceGroup -n $ClusterName

if (-not $vnet -or -not $aks) {
    Write-Host "Could not find the virtual network or the cluster in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

$vnetPrefix = $vnet.addressSpace.addressPrefixes[0]
$np = $aks.networkProfile

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

Write-Host 'Control plane' -ForegroundColor Cyan

Check 1 'The cluster has a private API server endpoint' `
    ($aks.apiServerAccessProfile.enablePrivateCluster -eq $true) `
    $(if ($aks.apiServerAccessProfile.enablePrivateCluster -eq $true) { "privateFqdn = $($aks.privateFqdn)" }
      else { 'the API server is on the public internet' })

$privateZoneId = $aks.apiServerAccessProfile.privateDNSZone
$zoneLinked = $false
$zoneDetail = ''
if ($privateZoneId -and $privateZoneId -ne 'none') {
    if ($privateZoneId -eq 'system' -or $privateZoneId -eq 'System') {
        # AKS manages the zone in the node resource group and links it itself.
        $zones = @(Invoke-Az network private-dns zone list -g $aks.nodeResourceGroup)
        $apiZone = $zones | Where-Object { $_.name -like '*azmk8s.io' } | Select-Object -First 1
        if ($apiZone) {
            $links = @(Invoke-Az network private-dns link vnet list -g $aks.nodeResourceGroup -z $apiZone.name)
            $zoneLinked = @($links | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
            $zoneDetail = "$($apiZone.name) in $($aks.nodeResourceGroup), linked to $VnetName = $zoneLinked"
        }
        else {
            $zoneDetail = "no *.azmk8s.io zone found in $($aks.nodeResourceGroup)"
        }
    }
    else {
        $zone = Invoke-Az network private-dns zone show --ids $privateZoneId
        if ($zone) {
            $zoneRg = ($privateZoneId -split '/resourceGroups/')[1].Split('/')[0]
            $links = @(Invoke-Az network private-dns link vnet list -g $zoneRg -z $zone.name)
            $zoneLinked = @($links | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
            $zoneDetail = "$($zone.name), linked to $VnetName = $zoneLinked"
        }
    }
}

Check 8 'A private DNS zone for the API server exists and is linked to the virtual network' `
    $zoneLinked `
    $(if (-not $privateZoneId -or $privateZoneId -eq 'none') { 'privateDNSZone is "none" - the API server name will not resolve privately' }
      else { $zoneDetail })

$aadProfile = $aks.aadProfile
$entraOk = ($aks.disableLocalAccounts -eq $true -and $null -ne $aadProfile -and $aadProfile.enableAzureRBAC -eq $true)

Check 9 'Local accounts are disabled and Entra integration with Kubernetes RBAC is on' `
    $entraOk `
    $(if ($aks.disableLocalAccounts -ne $true) { 'local accounts are enabled - "az aks get-credentials --admin" hands out a certificate that bypasses Entra, cannot be revoked individually, and leaves no sign-in log' }
      elseif (-not $aadProfile) { 'no Entra integration configured' }
      elseif ($aadProfile.enableAzureRBAC -ne $true) { 'Entra integration is on but Azure RBAC for Kubernetes is off' }
      else { 'disableLocalAccounts = true, enableAzureRBAC = true' })

Write-Host ''

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

Write-Host 'Networking' -ForegroundColor Cyan

Check 2 'The network plugin is azure in overlay mode' `
    ($np.networkPlugin -eq 'azure' -and $np.networkPluginMode -eq 'overlay') `
    "networkPlugin = $($np.networkPlugin), networkPluginMode = $(if ($np.networkPluginMode) { $np.networkPluginMode } else { '<not set - traditional CNI>' })"

$podCidr = $np.podCidr
$podOverlaps = $podCidr -and (Test-CidrOverlap $podCidr $vnetPrefix)

Check 3 'A pod CIDR is configured and does not overlap the virtual network' `
    ($null -ne $podCidr -and -not $podOverlaps) `
    $(if (-not $podCidr) { 'no pod CIDR - with traditional CNI, pods take addresses from the node subnet instead' }
      elseif ($podOverlaps) { "pod CIDR $podCidr overlaps the VNet $vnetPrefix" }
      else { "pod CIDR $podCidr, VNet $vnetPrefix - no overlap, and the pod range consumes no VNet space at all" })

$svcCidr = $np.serviceCidr
$svcOverlapsVnet = $svcCidr -and (Test-CidrOverlap $svcCidr $vnetPrefix)
$svcOverlapsPod = ($svcCidr -and $podCidr) -and (Test-CidrOverlap $svcCidr $podCidr)

Check 4 'The service CIDR does not overlap the virtual network or the pod CIDR' `
    ($null -ne $svcCidr -and -not $svcOverlapsVnet -and -not $svcOverlapsPod) `
    $(if (-not $svcCidr) { 'no service CIDR reported' }
      elseif ($svcOverlapsVnet) { "service CIDR $svcCidr overlaps the VNet $vnetPrefix" }
      elseif ($svcOverlapsPod) { "service CIDR $svcCidr overlaps the pod CIDR $podCidr" }
      else { "service CIDR $svcCidr" })

$dnsIp = $np.dnsServiceIp
$dnsInside = $dnsIp -and $svcCidr -and (Test-IpInCidr $dnsIp $svcCidr)

Check 5 'The DNS service IP falls inside the service CIDR' `
    $dnsInside `
    $(if (-not $dnsIp) { 'no DNS service IP reported' }
      elseif (-not $dnsInside) { "$dnsIp is outside $svcCidr - CoreDNS is itself a Kubernetes service, so the cluster comes up and then fails every lookup" }
      else { "$dnsIp inside $svcCidr" })

$pools = @($aks.agentPoolProfiles)
$publicIpPools = @($pools | Where-Object { $_.enableNodePublicIP -eq $true })

Check 6 'No node pool has node public IPs enabled' `
    ($publicIpPools.Count -eq 0) `
    $(if ($publicIpPools.Count -gt 0) { "pools with public node IPs: $(($publicIpPools | ForEach-Object { $_.name }) -join ', ')" }
      else { "$($pools.Count) pool(s), none with node public IPs. Note the outbound load balancer in $($aks.nodeResourceGroup) still has one - that is Lab 37" })

$poolsOutsideVnet = @($pools | Where-Object { -not $_.vnetSubnetId -or $_.vnetSubnetId -notlike "$($vnet.id)/*" })

Check 7 'Node pools use a subnet in your virtual network' `
    ($pools.Count -gt 0 -and $poolsOutsideVnet.Count -eq 0) `
    $(if ($poolsOutsideVnet.Count -gt 0) { "pools not in $VnetName : $(($poolsOutsideVnet | ForEach-Object { $_.name }) -join ', ') - a pool with no vnetSubnetId is using an AKS-managed network" }
      else { (($pools | ForEach-Object { "$($_.name) -> $(Split-Path $_.vnetSubnetId -Leaf)" }) -join ', ') })

Write-Host ''

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

Write-Host 'Access' -ForegroundColor Cyan

$assignments = @(Invoke-Az role assignment list --scope $aks.id)
$clusterUsers = @($assignments | Where-Object { $_.roleDefinitionName -eq 'Azure Kubernetes Service Cluster User Role' })
$clusterAdmins = @($assignments | Where-Object { $_.roleDefinitionName -eq 'Azure Kubernetes Service Cluster Admin Role' })

Check 10 'Cluster User is granted and Cluster Admin is not' `
    ($clusterUsers.Count -gt 0 -and $clusterAdmins.Count -eq 0) `
    $(if ($clusterAdmins.Count -gt 0) { "Cluster Admin assigned to $($clusterAdmins.Count) principal(s) - that role hands out the local admin credential and bypasses Kubernetes RBAC entirely" }
      elseif ($clusterUsers.Count -eq 0) { 'nothing holds Cluster User, so nothing inside the network can fetch a kubeconfig' }
      else { "$($clusterUsers.Count) principal(s) with Cluster User, none with Cluster Admin" })

Write-Host ''

# ---------------------------------------------------------------------------
# Live resolution
# ---------------------------------------------------------------------------

Write-Host 'Live resolution' -ForegroundColor Cyan

if (-not $VmName) {
    Skip 11 'The jump host resolves the private API FQDN to a private address' 'pass -VmName to run a lookup inside the jump host'
}
elseif (-not $aks.privateFqdn) {
    Skip 11 'The jump host resolves the private API FQDN to a private address' 'the cluster has no private FQDN'
}
else {
    $result = Invoke-Az vm run-command invoke -g $ResourceGroup -n $VmName `
        --command-id RunShellScript --scripts "getent hosts $($aks.privateFqdn) || echo UNRESOLVED"
    $out = if ($result) { ($result.value | ForEach-Object { $_.message }) -join "`n" } else { '' }
    $ip = if ($out -match '(\d{1,3}(?:\.\d{1,3}){3})') { $Matches[1] } else { $null }

    Check 11 'The jump host resolves the private API FQDN to a private address' `
        (Test-PrivateIp $ip) `
        $(if (-not $ip) { "no address returned for $($aks.privateFqdn) from $VmName" }
          elseif (-not (Test-PrivateIp $ip)) { "resolved to $ip, which is not a private address" }
          else { "$($aks.privateFqdn) -> $ip" })
}

Write-Host ''
Write-Host '----------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 12 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 12 acceptance criteria met.' -ForegroundColor Green
exit 0
