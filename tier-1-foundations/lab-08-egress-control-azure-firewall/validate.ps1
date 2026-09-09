#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 08 - Egress Control with Azure Firewall.

.DESCRIPTION
    Criteria 1-9 are read-only. Criteria 10 and 11 are opt-in and run curl inside
    the workload VM through the run-command extension.

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab08 -HubVnetName vnet-hub `
        -SpokeVnetName vnet-spoke -FirewallName afw-hub -VmName vm-spoke
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$HubVnetName,
    [string]$SpokeVnetName,
    [string]$FirewallName,
    [string]$SpokeSubnetName,
    [string]$VmName,
    [string]$DeniedTestFqdn = 'example.org'
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

Write-Host ''
Write-Host 'Lab 08 - Egress Control with Azure Firewall' -ForegroundColor Cyan
Write-Host '===========================================' -ForegroundColor Cyan
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
$HubVnetName   = Ask 'Hub VNet name' $HubVnetName
$SpokeVnetName = Ask 'Spoke VNet name' $SpokeVnetName
$FirewallName  = Ask 'Azure Firewall name' $FirewallName
Write-Host ''

$hub      = Invoke-Az network vnet show -g $ResourceGroup -n $HubVnetName
$spoke    = Invoke-Az network vnet show -g $ResourceGroup -n $SpokeVnetName
$firewall = Invoke-Az network firewall show -g $ResourceGroup -n $FirewallName

foreach ($pair in @(@($hub, "hub VNet '$HubVnetName'"), @($spoke, "spoke VNet '$SpokeVnetName'"), @($firewall, "firewall '$FirewallName'"))) {
    if (-not $pair[0]) {
        Write-Host "Could not find $($pair[1]) in '$ResourceGroup'. Cannot continue." -ForegroundColor Red
        exit 1
    }
}

$fwPrivateIp = ($firewall.ipConfigurations | Where-Object { $_.privateIPAddress } | Select-Object -First 1).privateIPAddress

# ---------------------------------------------------------------------------
# Topology and routing
# ---------------------------------------------------------------------------

Write-Host 'Topology and routing' -ForegroundColor Cyan

$hubPeerings   = @(Invoke-Az network vnet peering list -g $ResourceGroup --vnet-name $HubVnetName)
$spokePeerings = @(Invoke-Az network vnet peering list -g $ResourceGroup --vnet-name $SpokeVnetName)
$hubToSpoke = $hubPeerings   | Where-Object { $_.remoteVirtualNetwork.id -eq $spoke.id } | Select-Object -First 1
$spokeToHub = $spokePeerings | Where-Object { $_.remoteVirtualNetwork.id -eq $hub.id }   | Select-Object -First 1

Check 1 'Hub and spoke are peered in both directions and Connected' `
    ($null -ne $hubToSpoke -and $null -ne $spokeToHub -and
     $hubToSpoke.peeringState -eq 'Connected' -and $spokeToHub.peeringState -eq 'Connected') `
    $(if (-not $hubToSpoke) { 'no hub -> spoke peering' }
      elseif (-not $spokeToHub) { 'no spoke -> hub peering' }
      else { "hub->spoke $($hubToSpoke.peeringState), spoke->hub $($spokeToHub.peeringState)" })

Check 2 'The spoke peering allows forwarded traffic' `
    ($null -ne $spokeToHub -and $spokeToHub.allowForwardedTraffic -eq $true) `
    $(if (-not $spokeToHub) { 'spoke peering missing' }
      else { "allowForwardedTraffic = $($spokeToHub.allowForwardedTraffic) - without it the spoke rejects traffic the firewall relays back to it" })

$policyId = $firewall.firewallPolicy.id
$policy = if ($policyId) { Invoke-Az network firewall policy show --ids $policyId } else { $null }

Check 3 'An Azure Firewall exists in the hub with a firewall policy attached' `
    ($null -ne $policy -and $null -ne $fwPrivateIp) `
    $(if (-not $policy) { 'the firewall has no policy attached - classic rules are being used, or there are no rules at all' }
      else { "$($firewall.name) at $fwPrivateIp using policy $($policy.name) ($($policy.sku) tier)" })

$reserved = @('AzureFirewallSubnet', 'GatewaySubnet', 'AzureBastionSubnet', 'AzureFirewallManagementSubnet', 'RouteServerSubnet')
$workloadSubnet = if ($SpokeSubnetName) {
    $spoke.subnets | Where-Object { $_.name -eq $SpokeSubnetName } | Select-Object -First 1
}
else {
    $spoke.subnets | Where-Object { $_.name -notin $reserved } | Select-Object -First 1
}

$defaultRoute = $null
if ($workloadSubnet -and $workloadSubnet.routeTable) {
    $rt = Invoke-Az network route-table show --ids $workloadSubnet.routeTable.id
    $defaultRoute = @($rt.routes) | Where-Object { $_.addressPrefix -eq '0.0.0.0/0' } | Select-Object -First 1
}

Check 4 'The spoke subnet routes 0.0.0.0/0 to the firewall as VirtualAppliance' `
    ($null -ne $defaultRoute -and $defaultRoute.nextHopType -eq 'VirtualAppliance' -and $defaultRoute.nextHopIpAddress -eq $fwPrivateIp) `
    $(if (-not $workloadSubnet) { 'could not identify a workload subnet in the spoke' }
      elseif (-not $workloadSubnet.routeTable) { "subnet '$($workloadSubnet.name)' has no route table - traffic takes the default internet route and the firewall never sees it" }
      elseif (-not $defaultRoute) { 'route table attached but it has no 0.0.0.0/0 route' }
      elseif ($defaultRoute.nextHopIpAddress -ne $fwPrivateIp) { "0.0.0.0/0 points at $($defaultRoute.nextHopIpAddress), not the firewall at $fwPrivateIp" }
      else { "$($workloadSubnet.name): 0.0.0.0/0 -> VirtualAppliance $fwPrivateIp" })

$fwSubnet = $hub.subnets | Where-Object { $_.name -eq 'AzureFirewallSubnet' } | Select-Object -First 1

Check 5 'AzureFirewallSubnet has no route table' `
    ($null -ne $fwSubnet -and $null -eq $fwSubnet.routeTable) `
    $(if (-not $fwSubnet) { 'no AzureFirewallSubnet in the hub' }
      elseif ($fwSubnet.routeTable) { "route table $(Split-Path $fwSubnet.routeTable.id -Leaf) is attached - the firewall would route its own egress through itself" }
      else { 'system routes only, as intended' })

Write-Host ''

# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

Write-Host 'Rules' -ForegroundColor Cyan

$appRules = @()
$netRules = @()

if ($policy) {
    foreach ($rcgRef in @($policy.ruleCollectionGroups)) {
        $rcg = Invoke-Az network firewall policy rule-collection-group show --ids $rcgRef.id
        foreach ($rc in @($rcg.ruleCollections)) {
            $action = $rc.action.type
            foreach ($r in @($rc.rules)) {
                $entry = [pscustomobject]@{
                    Collection = $rc.name
                    Priority   = $rc.priority
                    Rule       = $r.name
                    Action     = $action
                    Fqdns      = @($r.destinationFqdns)
                    Addresses  = @($r.destinationAddresses)
                    Ports      = @($r.destinationPorts)
                }
                if ($r.ruleType -eq 'ApplicationRule') { $appRules += $entry }
                elseif ($r.ruleType -eq 'NetworkRule') { $netRules += $entry }
            }
        }
    }
}

$allowedFqdnRules = @($appRules | Where-Object { $_.Action -eq 'Allow' -and $_.Fqdns.Count -gt 0 })

Check 6 'The policy has an application rule collection allowing a specific list of FQDNs' `
    ($allowedFqdnRules.Count -gt 0) `
    $(if ($allowedFqdnRules.Count -gt 0) { "$(($allowedFqdnRules | ForEach-Object { "$($_.Collection)/$($_.Rule): $($_.Fqdns -join ', ')" }) -join '; ')" }
      else { 'no application rule allowing named FQDNs - egress is being decided on addresses only, and nothing records which hostname was requested' })

$wildcardTargets = @('*', '0.0.0.0/0')
$broadAllows = @()
foreach ($r in @($appRules) + @($netRules)) {
    if ($r.Action -ne 'Allow') { continue }
    $targets = @($r.Fqdns) + @($r.Addresses)
    if (@($targets | Where-Object { $_ -in $wildcardTargets }).Count -gt 0) {
        $broadAllows += "$($r.Collection)/$($r.Rule) (priority $($r.Priority))"
    }
}

Check 7 'No rule allows an unrestricted destination' `
    ($broadAllows.Count -eq 0) `
    $(if ($broadAllows.Count -gt 0) { "these allow anywhere: $($broadAllows -join ', ') - network rules are evaluated first, so a broad one silently disables the whole FQDN allow-list" }
      else { "$($appRules.Count) application rule(s) and $($netRules.Count) network rule(s), all with named destinations" })

Write-Host ''

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

Write-Host 'Diagnostics' -ForegroundColor Cyan

$diagResult = Invoke-Az monitor diagnostic-settings list --resource $firewall.id
# Older CLI versions wrap the list in a "value" property; newer ones return the
# array directly.
$diags = if ($diagResult -and $diagResult.PSObject.Properties.Name -contains 'value') { @($diagResult.value) } else { @($diagResult) }
$lawDiags = @($diags | Where-Object { $_ -and $_.workspaceId })

Check 8 'A diagnostic setting on the firewall sends logs to a Log Analytics workspace' `
    ($lawDiags.Count -gt 0) `
    $(if ($lawDiags.Count -gt 0) { "$($lawDiags[0].name) -> $(Split-Path $lawDiags[0].workspaceId -Leaf) (destination type $(if ($lawDiags[0].logAnalyticsDestinationType) { $lawDiags[0].logAnalyticsDestinationType } else { 'AzureDiagnostics' }))" }
      else { 'no diagnostic setting - nothing is being kept, and you cannot turn logging on retroactively' })

$appCategories = @('AZFWApplicationRule', 'AzureFirewallApplicationRule')
$netCategories = @('AZFWNetworkRule', 'AzureFirewallNetworkRule')
$enabledCats = @()
foreach ($d in $lawDiags) {
    foreach ($l in @($d.logs)) {
        if ($l.enabled) {
            if ($l.category) { $enabledCats += $l.category }
            if ($l.categoryGroup) { $enabledCats += $l.categoryGroup }
        }
    }
}
$hasApp = (@($enabledCats | Where-Object { $_ -in $appCategories }).Count -gt 0) -or ($enabledCats -contains 'allLogs')
$hasNet = (@($enabledCats | Where-Object { $_ -in $netCategories }).Count -gt 0) -or ($enabledCats -contains 'allLogs')

Check 9 'Both application rule and network rule log categories are enabled' `
    ($hasApp -and $hasNet) `
    $(if ($enabledCats.Count -eq 0) { 'no log categories enabled on the diagnostic setting' }
      else { "enabled: $(($enabledCats | Sort-Object -Unique) -join ', ')$(if (-not $hasApp) { ' - application rule logs missing' })$(if (-not $hasNet) { ' - network rule logs missing' })" })

Write-Host ''

# ---------------------------------------------------------------------------
# Live egress test
# ---------------------------------------------------------------------------

Write-Host 'Live egress' -ForegroundColor Cyan

$allowedFqdn = if ($allowedFqdnRules.Count -gt 0) { $allowedFqdnRules[0].Fqdns[0] } else { $null }

if (-not $VmName) {
    Skip 10 'An allowed FQDN is reachable from the spoke workload' 'pass -VmName to run curl inside the workload VM'
    Skip 11 'A denied FQDN is not reachable from the spoke workload' 'pass -VmName to run curl inside the workload VM'
}
elseif (-not $allowedFqdn) {
    Skip 10 'An allowed FQDN is reachable from the spoke workload' 'no allowed FQDN found in the policy to test with'
    Skip 11 'A denied FQDN is not reachable from the spoke workload' 'no allowed FQDN found in the policy to test with'
}
else {
    Write-Host "              testing from $VmName (this takes a minute) ..." -ForegroundColor DarkGray

    $script = @(
        "echo ALLOWED=`$(curl -sS -m 20 -o /dev/null -w '%{http_code}' https://$allowedFqdn/ 2>/dev/null || echo FAILED)",
        "echo DENIED=`$(curl -sS -m 20 -o /dev/null -w '%{http_code}' https://$DeniedTestFqdn/ 2>/dev/null || echo FAILED)"
    ) -join '; '

    $result = Invoke-Az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunShellScript --scripts $script
    $out = if ($result) { ($result.value | ForEach-Object { $_.message }) -join "`n" } else { '' }

    $allowedCode = if ($out -match 'ALLOWED=(\S+)') { $Matches[1] } else { $null }
    $deniedCode  = if ($out -match 'DENIED=(\S+)')  { $Matches[1] } else { $null }

    Check 10 'An allowed FQDN is reachable from the spoke workload' `
        ($allowedCode -match '^[23]\d\d$') `
        $(if (-not $allowedCode) { 'no result returned - is the VM running?' }
          else { "https://$allowedFqdn -> $allowedCode" })

    Check 11 'A denied FQDN is not reachable from the spoke workload' `
        ($deniedCode -eq 'FAILED' -or $deniedCode -eq '000') `
        $(if (-not $deniedCode) { 'no result returned' }
          elseif ($deniedCode -match '^[23]\d\d$') { "https://$DeniedTestFqdn returned $deniedCode - the allow-list is not being applied. Check for a broad network rule ahead of the application rules" }
          else { "https://$DeniedTestFqdn -> $deniedCode (blocked)" })
}

Write-Host ''
Write-Host '-------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 08 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 08 acceptance criteria met.' -ForegroundColor Green
exit 0
