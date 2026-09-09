#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 13 - Self-Hosted Build Agents Inside a Private Network.

.DESCRIPTION
    Read-only. Reports a PASS or FAIL line for each acceptance criterion in
    README.md and exits 0 if everything passed, 1 otherwise.

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab13 -VnetName vnet-lab13 `
        -ScaleSetName vmss-agents -RegistryName acrlab13abc123
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$VnetName,
    [string]$ScaleSetName,
    [string]$RegistryName,
    [string]$AgentSubnetName = 'snet-agents',
    [string]$DnsResourceGroup
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

function Test-PrivateIp {
    param([string]$Ip)
    if (-not $Ip) { return $false }
    return ($Ip -match '^10\.' -or $Ip -match '^192\.168\.' -or $Ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.')
}

Write-Host ''
Write-Host 'Lab 13 - Self-Hosted Build Agents Inside a Private Network' -ForegroundColor Cyan
Write-Host '==========================================================' -ForegroundColor Cyan
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
$ScaleSetName  = Ask 'Scale set name' $ScaleSetName
$RegistryName  = Ask 'Container registry name' $RegistryName
if (-not $DnsResourceGroup) { $DnsResourceGroup = $ResourceGroup }
Write-Host ''

$vnet = Invoke-Az network vnet show -g $ResourceGroup -n $VnetName
$vmss = Invoke-Az vmss show -g $ResourceGroup -n $ScaleSetName
$acr  = Invoke-Az acr show -g $ResourceGroup -n $RegistryName

if (-not $vnet -or -not $vmss) {
    Write-Host "Could not find the virtual network or the scale set in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

$agentSubnet = $vnet.subnets | Where-Object { $_.name -eq $AgentSubnetName } | Select-Object -First 1

# ---------------------------------------------------------------------------
# The scale set
# ---------------------------------------------------------------------------

Write-Host 'Scale set' -ForegroundColor Cyan

$netProfile = $vmss.virtualMachineProfile.networkProfile.networkInterfaceConfigurations
$publicIpConfigs = @()
$vmssSubnetIds = @()
foreach ($nic in @($netProfile)) {
    foreach ($ipc in @($nic.ipConfigurations)) {
        if ($ipc.publicIPAddressConfiguration) { $publicIpConfigs += $ipc.name }
        if ($ipc.subnet) { $vmssSubnetIds += $ipc.subnet.id }
    }
}

Check 1 'The scale set has no public IP configuration' `
    ($publicIpConfigs.Count -eq 0) `
    $(if ($publicIpConfigs.Count -gt 0) { "public IP configuration on: $($publicIpConfigs -join ', ')" }
      else { "$($vmss.sku.capacity) instance(s) in $(($vmssSubnetIds | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object -Unique) -join ', ')" })

Check 2 'The scale set has a managed identity' `
    ($null -ne $vmss.identity -and $vmss.identity.type -match 'SystemAssigned|UserAssigned') `
    $(if ($vmss.identity) { "$($vmss.identity.type), principalId $($vmss.identity.principalId)" }
      else { 'no identity - the agents have no way to authenticate to Azure without a stored credential' })

$osProfile = $vmss.virtualMachineProfile.osProfile
$passwordDisabled = $osProfile.linuxConfiguration.disablePasswordAuthentication -eq $true

Check 3 'Password authentication is disabled on the scale set' `
    $passwordDisabled `
    $(if ($passwordDisabled) { 'key-based only' }
      else { 'password authentication is on. A build agent runs code from every pull request, so anything on the machine is readable by anyone who can open one' })

Write-Host ''

# ---------------------------------------------------------------------------
# The network security group
# ---------------------------------------------------------------------------

Write-Host 'Network rules' -ForegroundColor Cyan

$nsgId = $null
if ($agentSubnet -and $agentSubnet.networkSecurityGroup) {
    $nsgId = $agentSubnet.networkSecurityGroup.id
}
else {
    foreach ($nic in @($netProfile)) {
        if ($nic.networkSecurityGroup) { $nsgId = $nic.networkSecurityGroup.id; break }
    }
}
$nsg = if ($nsgId) { Invoke-Az network nsg show --ids $nsgId } else { $null }

if (-not $nsg) {
    Check 4 'No inbound Allow rule from the internet' $false 'no NSG found on the agent subnet or the scale set NIC'
    Check 5 'Outbound to Internet is denied below priority 65000' $false 'no NSG found'
    Check 6 'Every outbound Allow rule names a service tag or the virtual network' $false 'no NSG found'
}
else {
    $inbound = @($nsg.securityRules | Where-Object { $_.direction -eq 'Inbound' } | Sort-Object priority)
    $outbound = @($nsg.securityRules | Where-Object { $_.direction -eq 'Outbound' } | Sort-Object priority)

    $inboundAllows = @($inbound | Where-Object { $_.access -eq 'Allow' })

    Check 4 'No inbound Allow rule from the internet' `
        ($inboundAllows.Count -eq 0) `
        $(if ($inboundAllows.Count -gt 0) { "inbound allows present: $(($inboundAllows | ForEach-Object { "$($_.name) from $($_.sourceAddressPrefix)" }) -join ', ') - the agent connects out and holds the connection, so nothing should need to reach it" }
          else { "NSG '$($nsg.name)' has no inbound Allow rules at all, which is correct" })

    function Get-RuleDestinations {
        param($Rule)
        $d = @()
        if ($Rule.destinationAddressPrefix) { $d += $Rule.destinationAddressPrefix }
        if ($Rule.destinationAddressPrefixes) { $d += @($Rule.destinationAddressPrefixes) }
        return $d
    }

    $firstInternet = $outbound | Where-Object {
        @(Get-RuleDestinations $_ | Where-Object { $_ -in @('Internet', '0.0.0.0/0', '*') }).Count -gt 0
    } | Select-Object -First 1

    Check 5 'Outbound to Internet is denied below priority 65000' `
        ($null -ne $firstInternet -and $firstInternet.access -eq 'Deny' -and $firstInternet.priority -lt 65000) `
        $(if (-not $firstInternet) { 'no explicit outbound rule for Internet - the built-in AllowInternetOutBound at 65001 lets the agents reach anything' }
          elseif ($firstInternet.access -ne 'Deny') { "'$($firstInternet.name)' at priority $($firstInternet.priority) allows it" }
          else { "'$($firstInternet.name)' priority $($firstInternet.priority)" })

    $wildcardAllows = @($outbound | Where-Object {
        $_.access -eq 'Allow' -and
        @(Get-RuleDestinations $_ | Where-Object { $_ -in @('*', '0.0.0.0/0', 'Internet') }).Count -gt 0
    })

    Check 6 'Every outbound Allow rule names a service tag or the virtual network' `
        ($wildcardAllows.Count -eq 0) `
        $(if ($wildcardAllows.Count -gt 0) { "unrestricted: $(($wildcardAllows | ForEach-Object { $_.name }) -join ', ')" }
          else { "allowed destinations: $((@($outbound | Where-Object { $_.access -eq 'Allow' } | ForEach-Object { Get-RuleDestinations $_ }) | Sort-Object -Unique) -join ', ')" })
}

Write-Host ''

# ---------------------------------------------------------------------------
# Scaling and egress
# ---------------------------------------------------------------------------

Write-Host 'Scaling and egress' -ForegroundColor Cyan

$autoscaleList = @(Invoke-Az monitor autoscale list -g $ResourceGroup)
$autoscale = $autoscaleList | Where-Object { $_.targetResourceUri -eq $vmss.id } | Select-Object -First 1
$capacity = if ($autoscale) { $autoscale.profiles[0].capacity } else { $null }

Check 7 'An autoscale setting targets the scale set, with a maximum above the minimum' `
    ($null -ne $capacity -and [int]$capacity.maximum -gt [int]$capacity.minimum) `
    $(if (-not $autoscale) { 'no autoscale setting targets this scale set - the fleet is a fixed size' }
      elseif ([int]$capacity.maximum -le [int]$capacity.minimum) { "min $($capacity.minimum), max $($capacity.maximum) - it cannot actually scale" }
      else { "$($autoscale.name): min $($capacity.minimum), default $($capacity.default), max $($capacity.maximum)" })

$natId = if ($agentSubnet) { $agentSubnet.natGateway.id } else { $null }

Check 8 'The agent subnet egresses through a NAT gateway' `
    ($null -ne $natId) `
    $(if ($natId) { "$(Split-Path $natId -Leaf) - all agents leave from one known address, and the port budget is pooled" }
      else { "no NAT gateway on '$AgentSubnetName'. Each instance then does its own outbound translation from a small port allocation, and a busy fleet exhausts it" })

Write-Host ''

# ---------------------------------------------------------------------------
# The registry
# ---------------------------------------------------------------------------

Write-Host 'Registry' -ForegroundColor Cyan

if (-not $acr) {
    Check 9  'The registry has public access disabled and an approved private endpoint' $false "container registry '$RegistryName' not found in '$ResourceGroup'"
    Check 10 'privatelink.azurecr.io is linked to the VNet and resolves the registry privately' $false 'registry not found'
    Check 11 'The scale set identity holds AcrPull and no wider role' $false 'registry not found'
}
else {
    $endpoints = @(Invoke-Az network private-endpoint list -g $ResourceGroup)
    $pe = $endpoints | Where-Object {
        $_.privateLinkServiceConnections | Where-Object {
            $_.privateLinkServiceId -eq $acr.id -and $_.groupIds -contains 'registry'
        }
    } | Select-Object -First 1
    $peState = if ($pe) { ($pe.privateLinkServiceConnections | Select-Object -First 1).privateLinkServiceConnectionState.status } else { $null }

    Check 9 'The registry has public access disabled and an approved private endpoint' `
        ($acr.publicNetworkAccess -eq 'Disabled' -and $null -ne $pe -and $peState -eq 'Approved') `
        $(if ($acr.publicNetworkAccess -ne 'Disabled') { "publicNetworkAccess = $($acr.publicNetworkAccess)" }
          elseif (-not $pe) { 'no private endpoint with sub-resource registry' }
          else { "publicNetworkAccess Disabled, $($pe.name) $peState, sku $($acr.sku.name)" })

    $zoneName = 'privatelink.azurecr.io'
    $zone = Invoke-Az network private-dns zone show -g $DnsResourceGroup -n $zoneName
    $linked = $false
    $recordIp = $null
    if ($zone) {
        $links = @(Invoke-Az network private-dns link vnet list -g $DnsResourceGroup -z $zoneName)
        $linked = @($links | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
        $rec = @(Invoke-Az network private-dns record-set a list -g $DnsResourceGroup -z $zoneName) |
            Where-Object { $_.name -eq $RegistryName } | Select-Object -First 1
        if ($rec) { $recordIp = ($rec.aRecords | Select-Object -First 1).ipv4Address }
    }

    Check 10 "$zoneName is linked to the VNet and resolves the registry privately" `
        ($null -ne $zone -and $linked -and (Test-PrivateIp $recordIp)) `
        $(if (-not $zone) { "zone not found in '$DnsResourceGroup'" }
          elseif (-not $linked) { "zone exists but is not linked to $VnetName" }
          elseif (-not $recordIp) { "zone linked but no A record named '$RegistryName' - note ACR also registers a regional data endpoint record" }
          else { "$RegistryName -> $recordIp" })

    $principalId = if ($vmss.identity) { $vmss.identity.principalId } else { $null }
    if (-not $principalId) {
        Check 11 'The scale set identity holds AcrPull and no wider role' $false 'the scale set has no identity'
    }
    else {
        $assignments = @(Invoke-Az role assignment list --assignee $principalId --all)
        $acrPull = @($assignments | Where-Object { $_.roleDefinitionName -eq 'AcrPull' -and $_.scope -eq $acr.id })
        $wider = @($assignments | Where-Object { $_.roleDefinitionName -in @('AcrPush', 'AcrDelete', 'Owner', 'Contributor', 'User Access Administrator') })

        Check 11 'The scale set identity holds AcrPull and no wider role' `
            ($acrPull.Count -gt 0 -and $wider.Count -eq 0) `
            $(if ($acrPull.Count -eq 0) { "no AcrPull assignment on $RegistryName for the scale set identity" }
              elseif ($wider.Count -gt 0) { "over-granted: $(($wider | ForEach-Object { "$($_.roleDefinitionName) at $($_.scope)" }) -join '; ') - agents pull images, they do not push or delete" }
              else { 'AcrPull on the registry, and nothing else' })
    }
}

Write-Host ''
Write-Host '----------------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 13 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 13 acceptance criteria met.' -ForegroundColor Green
exit 0
