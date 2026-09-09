#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 02 - Hub and Spoke with a Shared Services Spoke.

.DESCRIPTION
    Read-only. Queries Azure with the Azure CLI and reports a PASS or FAIL line
    for each acceptance criterion in README.md. Exits 0 if everything passed,
    1 otherwise.

    Assumes you are already signed in ("az login") and that the correct
    subscription is selected ("az account set --subscription <id>").

.EXAMPLE
    pwsh ./validate.ps1

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab02 -HubVnetName vnet-hub `
        -AppSpokeVnetName vnet-spoke-app -SharedSpokeVnetName vnet-spoke-shared `
        -AppVmName vm-app -SharedVmName vm-shared
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$HubVnetName,
    [string]$AppSpokeVnetName,
    [string]$SharedSpokeVnetName,
    [string]$AppSubnetName,
    [string]$SharedSubnetName,
    [string]$AppVmName,
    [string]$SharedVmName,
    [string]$NvaPrivateIp
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

function Get-PrefixLength {
    param([string]$Cidr)
    if ($Cidr -match '/(\d+)$') { return [int]$Matches[1] }
    return 32
}

function Get-SubnetRouteTable {
    param($Subnet)
    if (-not $Subnet -or -not $Subnet.routeTable) { return $null }
    return Invoke-Az network route-table show --ids $Subnet.routeTable.id
}

# Returns the named subnet, or the first non-reserved subnet if no name was given.
function Get-WorkloadSubnet {
    param($Vnet, [string]$Name)
    if ($Name) {
        return $Vnet.subnets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    }
    $reserved = @('AzureFirewallSubnet', 'GatewaySubnet', 'AzureBastionSubnet', 'AzureFirewallManagementSubnet', 'RouteServerSubnet')
    return $Vnet.subnets | Where-Object { $_.name -notin $reserved } | Select-Object -First 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Lab 02 - Hub and Spoke with a Shared Services Spoke' -ForegroundColor Cyan
Write-Host '===================================================' -ForegroundColor Cyan
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
$ResourceGroup       = Ask 'Resource group' $ResourceGroup
$HubVnetName         = Ask 'Hub VNet name' $HubVnetName
$AppSpokeVnetName    = Ask 'Application spoke VNet name' $AppSpokeVnetName
$SharedSpokeVnetName = Ask 'Shared services spoke VNet name' $SharedSpokeVnetName
Write-Host ''

if (-not (Invoke-Az group show -n $ResourceGroup)) {
    Write-Host "Resource group '$ResourceGroup' not found in this subscription." -ForegroundColor Red
    exit 1
}

$hub    = Invoke-Az network vnet show -g $ResourceGroup -n $HubVnetName
$spokeA = Invoke-Az network vnet show -g $ResourceGroup -n $AppSpokeVnetName
$spokeS = Invoke-Az network vnet show -g $ResourceGroup -n $SharedSpokeVnetName

foreach ($pair in @(@($hub, $HubVnetName), @($spokeA, $AppSpokeVnetName), @($spokeS, $SharedSpokeVnetName))) {
    if (-not $pair[0]) {
        Write-Host "Virtual network '$($pair[1])' not found in '$ResourceGroup'. Cannot continue." -ForegroundColor Red
        exit 1
    }
}

$appPrefix    = $spokeA.addressSpace.addressPrefixes[0]
$sharedPrefix = $spokeS.addressSpace.addressPrefixes[0]
$hubPrefix    = $hub.addressSpace.addressPrefixes[0]

Write-Host ("Hub {0}   App spoke {1}   Shared spoke {2}" -f $hubPrefix, $appPrefix, $sharedPrefix) -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# Topology
# ---------------------------------------------------------------------------

Write-Host 'Topology' -ForegroundColor Cyan

$fwSubnet = $hub.subnets | Where-Object { $_.name -eq 'AzureFirewallSubnet' } | Select-Object -First 1
$fwSubnetSize = if ($fwSubnet) { Get-PrefixLength $fwSubnet.addressPrefix } else { 99 }

Check 1 'Hub VNet exists with an AzureFirewallSubnet of /26 or larger' `
    ($null -ne $fwSubnet -and $fwSubnetSize -le 26) `
    $(if (-not $fwSubnet) { "no subnet named AzureFirewallSubnet in $HubVnetName" }
      else { "AzureFirewallSubnet = $($fwSubnet.addressPrefix)" })

Check 2 'Both spoke VNets exist' `
    ($null -ne $spokeA -and $null -ne $spokeS) `
    "$AppSpokeVnetName ($appPrefix), $SharedSpokeVnetName ($sharedPrefix)"

$hubPeerings    = @(Invoke-Az network vnet peering list -g $ResourceGroup --vnet-name $HubVnetName)
$appPeerings    = @(Invoke-Az network vnet peering list -g $ResourceGroup --vnet-name $AppSpokeVnetName)
$sharedPeerings = @(Invoke-Az network vnet peering list -g $ResourceGroup --vnet-name $SharedSpokeVnetName)

$hubToApp    = $hubPeerings    | Where-Object { $_.remoteVirtualNetwork.id -eq $spokeA.id } | Select-Object -First 1
$appToHub    = $appPeerings    | Where-Object { $_.remoteVirtualNetwork.id -eq $hub.id }    | Select-Object -First 1
$hubToShared = $hubPeerings    | Where-Object { $_.remoteVirtualNetwork.id -eq $spokeS.id } | Select-Object -First 1
$sharedToHub = $sharedPeerings | Where-Object { $_.remoteVirtualNetwork.id -eq $hub.id }    | Select-Object -First 1

Check 3 'Hub <-> application spoke peering exists in both directions and is Connected' `
    ($null -ne $hubToApp -and $null -ne $appToHub -and
     $hubToApp.peeringState -eq 'Connected' -and $appToHub.peeringState -eq 'Connected') `
    $(if (-not $hubToApp) { 'no hub -> app peering' }
      elseif (-not $appToHub) { 'no app -> hub peering (peering is directional, both halves are needed)' }
      else { "hub->app $($hubToApp.peeringState), app->hub $($appToHub.peeringState)" })

Check 4 'Hub <-> shared spoke peering exists in both directions and is Connected' `
    ($null -ne $hubToShared -and $null -ne $sharedToHub -and
     $hubToShared.peeringState -eq 'Connected' -and $sharedToHub.peeringState -eq 'Connected') `
    $(if (-not $hubToShared) { 'no hub -> shared peering' }
      elseif (-not $sharedToHub) { 'no shared -> hub peering' }
      else { "hub->shared $($hubToShared.peeringState), shared->hub $($sharedToHub.peeringState)" })

$directPeerings = @()
$directPeerings += @($appPeerings    | Where-Object { $_.remoteVirtualNetwork.id -eq $spokeS.id })
$directPeerings += @($sharedPeerings | Where-Object { $_.remoteVirtualNetwork.id -eq $spokeA.id })

Check 5 'No direct peering between the two spokes' `
    ($directPeerings.Count -eq 0) `
    $(if ($directPeerings.Count -gt 0) { "found direct spoke peering(s): $(($directPeerings | ForEach-Object { $_.name }) -join ', ')" }
      else { 'the spokes are peered only to the hub' })

$fwdOk = ($null -ne $appToHub -and $appToHub.allowForwardedTraffic -eq $true -and
          $null -ne $sharedToHub -and $sharedToHub.allowForwardedTraffic -eq $true)

Check 6 'allowForwardedTraffic is enabled on the spoke-side peerings' `
    $fwdOk `
    $(if (-not $appToHub -or -not $sharedToHub) { 'spoke-side peerings missing' }
      else { "app->hub $($appToHub.allowForwardedTraffic), shared->hub $($sharedToHub.allowForwardedTraffic) - without this the destination spoke drops frames sourced outside the hub prefix" })

Write-Host ''

# ---------------------------------------------------------------------------
# The forwarding device
# ---------------------------------------------------------------------------

Write-Host 'Forwarding device' -ForegroundColor Cyan

$firewall = $null
$deviceIp = $NvaPrivateIp
$deviceKind = 'NVA'

if (-not $deviceIp) {
    $firewalls = @(Invoke-Az network firewall list -g $ResourceGroup)
    $firewall = $firewalls | Where-Object {
        $_.ipConfigurations | Where-Object { $_.subnet.id -like "$($hub.id)/subnets/*" }
    } | Select-Object -First 1
    if ($firewall) {
        $deviceKind = 'Azure Firewall'
        $deviceIp = ($firewall.ipConfigurations | Where-Object { $_.privateIPAddress } | Select-Object -First 1).privateIPAddress
    }
}

Check 7 'A forwarding device exists in the hub and its private IP is known' `
    ([string]::IsNullOrWhiteSpace($deviceIp) -eq $false) `
    $(if ($deviceIp) { "$deviceKind at $deviceIp" }
      else { "no Azure Firewall found with an IP configuration in $HubVnetName, and -NvaPrivateIp was not supplied" })

Write-Host ''

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

Write-Host 'Routing' -ForegroundColor Cyan

$appSubnet    = Get-WorkloadSubnet $spokeA $AppSubnetName
$sharedSubnet = Get-WorkloadSubnet $spokeS $SharedSubnetName
$appRt        = Get-SubnetRouteTable $appSubnet
$sharedRt     = Get-SubnetRouteTable $sharedSubnet

function Find-ApplianceRoute {
    param($RouteTable, [string]$Prefix, [string]$DeviceIp)
    if (-not $RouteTable) { return $null }
    return $RouteTable.routes | Where-Object {
        $_.addressPrefix -eq $Prefix -and
        $_.nextHopType -eq 'VirtualAppliance' -and
        (-not $DeviceIp -or $_.nextHopIpAddress -eq $DeviceIp)
    } | Select-Object -First 1
}

$appRoute = Find-ApplianceRoute $appRt $sharedPrefix $deviceIp

Check 8 'App spoke subnet routes the shared spoke prefix to the forwarding device' `
    ($null -ne $appRoute) `
    $(if (-not $appSubnet) { 'could not identify a workload subnet in the app spoke' }
      elseif (-not $appRt) { "subnet '$($appSubnet.name)' has no route table - traffic to $sharedPrefix follows the default route and is dropped" }
      elseif (-not $appRoute) { "route table '$($appRt.name)' has no VirtualAppliance route for $sharedPrefix pointing at $deviceIp" }
      else { "$($appRt.name): $sharedPrefix -> VirtualAppliance $($appRoute.nextHopIpAddress)" })

$sharedRoute = Find-ApplianceRoute $sharedRt $appPrefix $deviceIp

Check 9 'Shared spoke subnet routes the app spoke prefix back through the same device' `
    ($null -ne $sharedRoute) `
    $(if (-not $sharedSubnet) { 'could not identify a workload subnet in the shared spoke' }
      elseif (-not $sharedRt) { "subnet '$($sharedSubnet.name)' has no route table - return traffic will be asymmetric and the firewall will drop it" }
      elseif (-not $sharedRoute) { "route table '$($sharedRt.name)' has no VirtualAppliance route for $appPrefix pointing at $deviceIp" }
      else { "$($sharedRt.name): $appPrefix -> VirtualAppliance $($sharedRoute.nextHopIpAddress)" })

Check 10 'AzureFirewallSubnet has no user-defined route table' `
    ($null -eq $fwSubnet -or $null -eq $fwSubnet.routeTable) `
    $(if ($fwSubnet -and $fwSubnet.routeTable) { "route table $(Split-Path $fwSubnet.routeTable.id -Leaf) is attached - the firewall would route its own return traffic through itself" }
      else { 'no route table on AzureFirewallSubnet, as intended' })

Write-Host ''

# ---------------------------------------------------------------------------
# Firewall rules
# ---------------------------------------------------------------------------

Write-Host 'Rules' -ForegroundColor Cyan

if (-not $firewall) {
    Skip 11 'A rule permits app spoke -> shared spoke' 'rules live inside the NVA and cannot be read from the Azure control plane'
    Skip 12 'No rule permits shared spoke -> app spoke' 'rules live inside the NVA and cannot be read from the Azure control plane'
}
else {
    # Rules may be classic (on the firewall) or in a firewall policy.
    $collections = @()
    if ($firewall.networkRuleCollections) { $collections += @($firewall.networkRuleCollections) }

    if ($firewall.firewallPolicy) {
        $policy = Invoke-Az network firewall policy show --ids $firewall.firewallPolicy.id
        if ($policy -and $policy.ruleCollectionGroups) {
            foreach ($rcgRef in $policy.ruleCollectionGroups) {
                $rcg = Invoke-Az network firewall policy rule-collection-group show --ids $rcgRef.id
                foreach ($rc in @($rcg.ruleCollections)) {
                    if ($rc.ruleCollectionType -ne 'FirewallPolicyFilterRuleCollection') { continue }
                    $collections += [pscustomobject]@{
                        name   = $rc.name
                        action = [pscustomobject]@{ type = $rc.action.type }
                        rules  = $rc.rules
                    }
                }
            }
        }
    }

    function Test-RuleMatches {
        param($Rule, [string]$SrcPrefix, [string]$DstPrefix)
        $srcs = @()
        if ($Rule.sourceAddresses) { $srcs += @($Rule.sourceAddresses) }
        $dsts = @()
        if ($Rule.destinationAddresses) { $dsts += @($Rule.destinationAddresses) }
        $srcHit = @($srcs | Where-Object { $_ -eq $SrcPrefix -or $_ -eq '*' -or $_ -eq '0.0.0.0/0' }).Count -gt 0
        $dstHit = @($dsts | Where-Object { $_ -eq $DstPrefix -or $_ -eq '*' -or $_ -eq '0.0.0.0/0' }).Count -gt 0
        return ($srcHit -and $dstHit)
    }

    $allowAppToShared = @()
    $allowSharedToApp = @()
    foreach ($c in $collections) {
        $action = $c.action.type
        foreach ($r in @($c.rules)) {
            if (Test-RuleMatches $r $appPrefix $sharedPrefix) {
                if ($action -eq 'Allow') { $allowAppToShared += "$($c.name)/$($r.name)" }
            }
            if (Test-RuleMatches $r $sharedPrefix $appPrefix) {
                if ($action -eq 'Allow') { $allowSharedToApp += "$($c.name)/$($r.name)" }
            }
        }
    }

    Check 11 'A rule permits app spoke -> shared spoke' `
        ($allowAppToShared.Count -gt 0) `
        $(if ($allowAppToShared.Count -gt 0) { "allowed by: $($allowAppToShared -join ', ')" }
          else { "no Allow network rule matching $appPrefix -> $sharedPrefix was found on $($firewall.name)" })

    Check 12 'No rule permits shared spoke -> app spoke' `
        ($allowSharedToApp.Count -eq 0) `
        $(if ($allowSharedToApp.Count -gt 0) { "isolation broken by: $($allowSharedToApp -join ', ')" }
          else { "nothing allows $sharedPrefix -> $appPrefix, so the implicit deny applies" })
}

Write-Host ''

# ---------------------------------------------------------------------------
# Live next-hop checks
# ---------------------------------------------------------------------------

Write-Host 'Effective path' -ForegroundColor Cyan

function Get-VmFirstNic {
    param([string]$VmName)
    $vm = Invoke-Az vm show -g $ResourceGroup -n $VmName
    if (-not $vm) { return $null }
    $nicId = $vm.networkProfile.networkInterfaces[0].id
    $nic = Invoke-Az network nic show --ids $nicId
    if (-not $nic) { return $null }
    return [pscustomobject]@{
        VmId  = $vm.id
        NicId = $nicId
        Ip    = ($nic.ipConfigurations | Select-Object -First 1).privateIPAddress
    }
}

if (-not $AppVmName -or -not $SharedVmName) {
    Skip 13 'Next hop from the app spoke to the shared spoke is VirtualAppliance' 'pass -AppVmName and -SharedVmName to run the Network Watcher next-hop checks'
    Skip 14 'Next hop from the shared spoke to the app spoke is VirtualAppliance' 'pass -AppVmName and -SharedVmName to run the Network Watcher next-hop checks'
}
else {
    $appVm    = Get-VmFirstNic $AppVmName
    $sharedVm = Get-VmFirstNic $SharedVmName

    if (-not $appVm -or -not $sharedVm) {
        Check 13 'Next hop from the app spoke to the shared spoke is VirtualAppliance' $false "could not resolve NIC details for $AppVmName or $SharedVmName"
        Check 14 'Next hop from the shared spoke to the app spoke is VirtualAppliance' $false 'see above'
    }
    else {
        $hopA = Invoke-Az network watcher show-next-hop -g $ResourceGroup `
            --vm $AppVmName --nic $appVm.NicId `
            --source-ip $appVm.Ip --dest-ip $sharedVm.Ip

        Check 13 'Next hop from the app spoke to the shared spoke is VirtualAppliance' `
            ($null -ne $hopA -and $hopA.nextHopType -eq 'VirtualAppliance') `
            $(if (-not $hopA) { 'Network Watcher returned nothing - it may not be enabled in this region' }
              else { "$($appVm.Ip) -> $($sharedVm.Ip): nextHopType $($hopA.nextHopType) $($hopA.nextHopIpAddress)" })

        $hopB = Invoke-Az network watcher show-next-hop -g $ResourceGroup `
            --vm $SharedVmName --nic $sharedVm.NicId `
            --source-ip $sharedVm.Ip --dest-ip $appVm.Ip

        Check 14 'Next hop from the shared spoke to the app spoke is VirtualAppliance' `
            ($null -ne $hopB -and $hopB.nextHopType -eq 'VirtualAppliance') `
            $(if (-not $hopB) { 'Network Watcher returned nothing - it may not be enabled in this region' }
              else { "$($sharedVm.Ip) -> $($appVm.Ip): nextHopType $($hopB.nextHopType) $($hopB.nextHopIpAddress)" })
    }
}

Write-Host ''

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host '---------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 02 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 02 acceptance criteria met.' -ForegroundColor Green
exit 0
