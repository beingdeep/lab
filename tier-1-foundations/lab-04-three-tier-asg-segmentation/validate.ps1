#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 04 - Three-Tier Segmentation with Application Security Groups.

.DESCRIPTION
    Read-only. Queries Azure with the Azure CLI and reports a PASS or FAIL line
    for each acceptance criterion in README.md. Exits 0 if everything passed,
    1 otherwise.

    Assumes you are already signed in ("az login") and that the correct
    subscription is selected ("az account set --subscription <id>").

.EXAMPLE
    pwsh ./validate.ps1

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab04 -VnetName vnet-lab04 `
        -WebVmName vm-web-1 -AppVmName vm-app-1 -DbVmName vm-db-1
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$VnetName,
    [string]$WebSubnetName = 'snet-web',
    [string]$AppSubnetName = 'snet-app',
    [string]$DbSubnetName = 'snet-db',
    [string]$WebAsgName = 'asg-web',
    [string]$AppAsgName = 'asg-app',
    [string]$DbAsgName = 'asg-db',
    [string]$WebVmName,
    [string]$AppVmName,
    [string]$DbVmName
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

# Does this rule's source side cover traffic from the given ASG?
function Test-SideMatches {
    param($AsgList, $Prefix, $Prefixes, [string]$AsgId)
    if ($AsgList) {
        if (@($AsgList | Where-Object { $_.id -eq $AsgId }).Count -gt 0) { return $true }
        # Named a different ASG explicitly, so it does not cover this one.
        return $false
    }
    $all = @()
    if ($Prefix) { $all += $Prefix }
    if ($Prefixes) { $all += @($Prefixes) }
    return (@($all | Where-Object { $_ -in @('*', '0.0.0.0/0', 'VirtualNetwork') }).Count -gt 0)
}

function Test-PortCovered {
    param($Rule, [string]$Port)
    $ranges = @()
    if ($Rule.destinationPortRange) { $ranges += $Rule.destinationPortRange }
    if ($Rule.destinationPortRanges) { $ranges += @($Rule.destinationPortRanges) }
    foreach ($r in $ranges) {
        if ($r -eq '*' -or $r -eq $Port) { return $true }
        if ($r -match '^(\d+)-(\d+)$') {
            if ([int]$Port -ge [int]$Matches[1] -and [int]$Port -le [int]$Matches[2]) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Lab 04 - Three-Tier Segmentation with Application Security Groups' -ForegroundColor Cyan
Write-Host '=================================================================' -ForegroundColor Cyan
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
Write-Host ''

if (-not (Invoke-Az group show -n $ResourceGroup)) {
    Write-Host "Resource group '$ResourceGroup' not found in this subscription." -ForegroundColor Red
    exit 1
}

$vnet = Invoke-Az network vnet show -g $ResourceGroup -n $VnetName
if (-not $vnet) {
    Write-Host "Virtual network '$VnetName' not found in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

$subnets = @{}
foreach ($n in @($WebSubnetName, $AppSubnetName, $DbSubnetName)) {
    $subnets[$n] = $vnet.subnets | Where-Object { $_.name -eq $n } | Select-Object -First 1
}
$tierPrefixes = @($subnets.Values | Where-Object { $_ } | ForEach-Object { $_.addressPrefix })

# ---------------------------------------------------------------------------
# Application security groups
# ---------------------------------------------------------------------------

Write-Host 'Application security groups' -ForegroundColor Cyan

$asgs = @{}
foreach ($n in @($WebAsgName, $AppAsgName, $DbAsgName)) {
    $asgs[$n] = Invoke-Az network asg show -g $ResourceGroup -n $n
}
$missingAsgs = @($asgs.Keys | Where-Object { -not $asgs[$_] })

Check 1 'All three application security groups exist' `
    ($missingAsgs.Count -eq 0) `
    $(if ($missingAsgs.Count -gt 0) { "not found in '$ResourceGroup': $($missingAsgs -join ', ')" }
      else { "$WebAsgName, $AppAsgName, $DbAsgName" })

if ($missingAsgs.Count -gt 0) {
    Write-Host ''
    Write-Host 'Cannot evaluate the rules without the ASGs. Stopping here.' -ForegroundColor Red
    exit 1
}

$webAsgId = $asgs[$WebAsgName].id
$appAsgId = $asgs[$AppAsgName].id
$dbAsgId  = $asgs[$DbAsgName].id

Write-Host ''

# ---------------------------------------------------------------------------
# The NSG and its rules
# ---------------------------------------------------------------------------

Write-Host 'Network security group' -ForegroundColor Cyan

$nsgIds = @($subnets.Values | Where-Object { $_ -and $_.networkSecurityGroup } | ForEach-Object { $_.networkSecurityGroup.id } | Sort-Object -Unique)
$unprotected = @($subnets.Keys | Where-Object { -not $subnets[$_] -or -not $subnets[$_].networkSecurityGroup })

Check 2 'One NSG is associated with the web, app and database subnets' `
    ($unprotected.Count -eq 0 -and $nsgIds.Count -eq 1) `
    $(if ($unprotected.Count -gt 0) { "no NSG on: $($unprotected -join ', ')" }
      elseif ($nsgIds.Count -gt 1) { "$($nsgIds.Count) different NSGs across the three subnets - they will drift apart" }
      else { "$(Split-Path $nsgIds[0] -Leaf) on all three tier subnets" })

$nsg = if ($nsgIds.Count -ge 1) { Invoke-Az network nsg show --ids $nsgIds[0] } else { $null }
$inbound = @()
if ($nsg) { $inbound = @($nsg.securityRules | Where-Object { $_.direction -eq 'Inbound' } | Sort-Object priority) }

function Find-FirstMatch {
    param([string]$SrcAsgId, [string]$DstAsgId, [string]$Port)
    foreach ($r in $inbound) {
        $srcOk = Test-SideMatches $r.sourceApplicationSecurityGroups $r.sourceAddressPrefix $r.sourceAddressPrefixes $SrcAsgId
        $dstOk = Test-SideMatches $r.destinationApplicationSecurityGroups $r.destinationAddressPrefix $r.destinationAddressPrefixes $DstAsgId
        if ($srcOk -and $dstOk -and (Test-PortCovered $r $Port)) { return $r }
    }
    return $null
}

$webToApp = Find-FirstMatch $webAsgId $appAsgId '443'
$webToAppUsesAsgs = $webToApp -and $webToApp.sourceApplicationSecurityGroups -and $webToApp.destinationApplicationSecurityGroups

Check 3 'A rule allows web ASG -> app ASG, expressed with ASGs on both sides' `
    ($null -ne $webToApp -and $webToApp.access -eq 'Allow' -and $webToAppUsesAsgs) `
    $(if (-not $webToApp) { 'no inbound rule matches web -> app on 443' }
      elseif ($webToApp.access -ne 'Allow') { "first match is '$($webToApp.name)' priority $($webToApp.priority) which is a $($webToApp.access)" }
      elseif (-not $webToAppUsesAsgs) { "'$($webToApp.name)' matches, but uses address prefixes rather than ASGs on at least one side" }
      else { "'$($webToApp.name)' priority $($webToApp.priority)" })

$appToDb = Find-FirstMatch $appAsgId $dbAsgId '1433'
$appToDbUsesAsgs = $appToDb -and $appToDb.sourceApplicationSecurityGroups -and $appToDb.destinationApplicationSecurityGroups

Check 4 'A rule allows app ASG -> database ASG, expressed with ASGs on both sides' `
    ($null -ne $appToDb -and $appToDb.access -eq 'Allow' -and $appToDbUsesAsgs) `
    $(if (-not $appToDb) { 'no inbound rule matches app -> db on 1433' }
      elseif ($appToDb.access -ne 'Allow') { "first match is '$($appToDb.name)' priority $($appToDb.priority) which is a $($appToDb.access)" }
      elseif (-not $appToDbUsesAsgs) { "'$($appToDb.name)' matches, but uses address prefixes rather than ASGs on at least one side" }
      else { "'$($appToDb.name)' priority $($appToDb.priority)" })

$webToDb = Find-FirstMatch $webAsgId $dbAsgId '1433'

Check 5 'No rule permits the web ASG to reach the database ASG' `
    ($null -ne $webToDb -and $webToDb.access -eq 'Deny') `
    $(if (-not $webToDb) { 'nothing in your rules matches web -> db on 1433, so the built-in AllowVnetInBound at 65000 permits it' }
      elseif ($webToDb.access -eq 'Allow') { "'$($webToDb.name)' priority $($webToDb.priority) explicitly allows it" }
      else { "blocked by '$($webToDb.name)' priority $($webToDb.priority)" })

$denyToDb = $inbound | Where-Object {
    $_.access -eq 'Deny' -and $_.priority -lt 65000 -and
    (Test-SideMatches $_.destinationApplicationSecurityGroups $_.destinationAddressPrefix $_.destinationAddressPrefixes $dbAsgId) -and
    $_.destinationApplicationSecurityGroups
} | Select-Object -First 1

Check 6 'A deny rule protects the database ASG at a priority below 65000' `
    ($null -ne $denyToDb) `
    $(if ($denyToDb) { "'$($denyToDb.name)' priority $($denyToDb.priority)" }
      else { 'no ASG-targeted deny rule for the database tier - AllowVnetInBound at 65000 wins' })

$denyToApp = $inbound | Where-Object {
    $_.access -eq 'Deny' -and $_.priority -lt 65000 -and
    (Test-SideMatches $_.destinationApplicationSecurityGroups $_.destinationAddressPrefix $_.destinationAddressPrefixes $appAsgId) -and
    $_.destinationApplicationSecurityGroups
} | Select-Object -First 1

Check 7 'A deny rule protects the app ASG at a priority below 65000' `
    ($null -ne $denyToApp) `
    $(if ($denyToApp) { "'$($denyToApp.name)' priority $($denyToApp.priority)" }
      else { 'no ASG-targeted deny rule for the app tier' })

$internetAllows = @($inbound | Where-Object {
    $_.access -eq 'Allow' -and
    (@(@($_.sourceAddressPrefix) + @($_.sourceAddressPrefixes) | Where-Object { $_ -in @('Internet', '*', '0.0.0.0/0') }).Count -gt 0)
})

Check 8 'No inbound rule allows the Internet service tag as a source' `
    ($internetAllows.Count -eq 0) `
    $(if ($internetAllows.Count -gt 0) { "exposed by: $(($internetAllows | ForEach-Object { "$($_.name) (priority $($_.priority))" }) -join ', ')" }
      else { 'nothing inbound is allowed from outside the virtual network' })

$prefixRules = @()
foreach ($r in $inbound) {
    $used = @()
    if ($r.sourceAddressPrefix) { $used += $r.sourceAddressPrefix }
    if ($r.sourceAddressPrefixes) { $used += @($r.sourceAddressPrefixes) }
    if ($r.destinationAddressPrefix) { $used += $r.destinationAddressPrefix }
    if ($r.destinationAddressPrefixes) { $used += @($r.destinationAddressPrefixes) }
    if (@($used | Where-Object { $_ -in $tierPrefixes }).Count -gt 0) { $prefixRules += $r.name }
}

Check 9 'No tier-identity rule uses a subnet address prefix where an ASG should be used' `
    ($prefixRules.Count -eq 0) `
    $(if ($prefixRules.Count -gt 0) { "these name a tier subnet range directly: $($prefixRules -join ', ') - the rules stop being true as soon as a tier moves" }
      else { "tier identity comes from ASGs, not from $($tierPrefixes -join ', ')" })

Write-Host ''

# ---------------------------------------------------------------------------
# Membership
# ---------------------------------------------------------------------------

Write-Host 'ASG membership' -ForegroundColor Cyan

$expectedAsgForSubnet = @{
    $WebSubnetName = $webAsgId
    $AppSubnetName = $appAsgId
    $DbSubnetName  = $dbAsgId
}

$nics = @(Invoke-Az network nic list -g $ResourceGroup)
$membershipProblems = @()
$asgCounts = @{ $webAsgId = 0; $appAsgId = 0; $dbAsgId = 0 }

foreach ($nic in $nics) {
    foreach ($ipc in @($nic.ipConfigurations)) {
        if (-not $ipc.subnet) { continue }
        $subnetName = Split-Path $ipc.subnet.id -Leaf
        if (-not $expectedAsgForSubnet.ContainsKey($subnetName)) { continue }

        $memberIds = @()
        if ($ipc.applicationSecurityGroups) { $memberIds = @($ipc.applicationSecurityGroups | ForEach-Object { $_.id }) }
        foreach ($id in $memberIds) { if ($asgCounts.ContainsKey($id)) { $asgCounts[$id]++ } }

        $expected = $expectedAsgForSubnet[$subnetName]
        if ($memberIds.Count -eq 0) {
            $membershipProblems += "$($nic.name) in $subnetName is in no ASG at all"
        }
        elseif ($memberIds.Count -gt 1) {
            $membershipProblems += "$($nic.name) is in $($memberIds.Count) ASGs"
        }
        elseif ($memberIds[0] -ne $expected) {
            $membershipProblems += "$($nic.name) in $subnetName is in $(Split-Path $memberIds[0] -Leaf), expected $(Split-Path $expected -Leaf)"
        }
    }
}

Check 10 'Every workload NIC belongs to exactly one tier ASG matching its subnet' `
    ($membershipProblems.Count -eq 0 -and ($asgCounts.Values | Measure-Object -Sum).Sum -gt 0) `
    $(if ($membershipProblems.Count -gt 0) { $membershipProblems -join '; ' }
      elseif (($asgCounts.Values | Measure-Object -Sum).Sum -eq 0) { 'no NICs found in the tier subnets' }
      else { "$WebAsgName $($asgCounts[$webAsgId]), $AppAsgName $($asgCounts[$appAsgId]), $DbAsgName $($asgCounts[$dbAsgId])" })

Check 11 'The web ASG contains more than one NIC, proving the rules scale out' `
    ($asgCounts[$webAsgId] -gt 1) `
    $(if ($asgCounts[$webAsgId] -gt 1) { "$($asgCounts[$webAsgId]) NICs in $WebAsgName, and not one rule mentions any of their addresses" }
      else { "only $($asgCounts[$webAsgId]) NIC in $WebAsgName - add a second web server and re-run, changing no rules" })

Write-Host ''

# ---------------------------------------------------------------------------
# IP flow verify
# ---------------------------------------------------------------------------

Write-Host 'Effective decisions' -ForegroundColor Cyan

function Get-VmNicIp {
    param([string]$VmName)
    $vm = Invoke-Az vm show -g $ResourceGroup -n $VmName
    if (-not $vm) { return $null }
    $nicId = $vm.networkProfile.networkInterfaces[0].id
    $nic = Invoke-Az network nic show --ids $nicId
    if (-not $nic) { return $null }
    return [pscustomobject]@{ NicId = $nicId; Ip = ($nic.ipConfigurations | Select-Object -First 1).privateIPAddress }
}

if (-not $WebVmName -or -not $AppVmName -or -not $DbVmName) {
    Skip 12 'IP flow verify: app tier inbound from web on 443 is allowed by your rule' 'pass -WebVmName, -AppVmName and -DbVmName to run the Network Watcher checks'
    Skip 13 'IP flow verify: database tier inbound from web on 1433 is denied by your rule' 'pass -WebVmName, -AppVmName and -DbVmName to run the Network Watcher checks'
}
else {
    $web = Get-VmNicIp $WebVmName
    $app = Get-VmNicIp $AppVmName
    $db  = Get-VmNicIp $DbVmName

    if (-not $web -or -not $app -or -not $db) {
        Check 12 'IP flow verify: app tier inbound from web on 443 is allowed by your rule' $false 'could not resolve one of the VMs or its NIC'
        Check 13 'IP flow verify: database tier inbound from web on 1433 is denied by your rule' $false 'see above'
    }
    else {
        $flowApp = Invoke-Az network watcher test-ip-flow -g $ResourceGroup --vm $AppVmName --nic $app.NicId `
            --direction Inbound --protocol TCP --local "$($app.Ip):443" --remote "$($web.Ip):51000"

        Check 12 'IP flow verify: app tier inbound from web on 443 is allowed by your rule' `
            ($null -ne $flowApp -and $flowApp.access -eq 'Allow') `
            $(if (-not $flowApp) { 'Network Watcher returned nothing - it may not be enabled in this region' }
              else { "access $($flowApp.access), decided by rule '$($flowApp.ruleName)'" })

        $flowDb = Invoke-Az network watcher test-ip-flow -g $ResourceGroup --vm $DbVmName --nic $db.NicId `
            --direction Inbound --protocol TCP --local "$($db.Ip):1433" --remote "$($web.Ip):51000"

        $deniedByOwnRule = $flowDb -and $flowDb.access -eq 'Deny' -and $flowDb.ruleName -notmatch 'DefaultRule|DenyAllInBound'

        Check 13 'IP flow verify: database tier inbound from web on 1433 is denied by your rule' `
            ([bool]$deniedByOwnRule) `
            $(if (-not $flowDb) { 'Network Watcher returned nothing - it may not be enabled in this region' }
              elseif ($flowDb.access -ne 'Deny') { "access $($flowDb.access) via rule '$($flowDb.ruleName)' - the web tier can reach the database" }
              elseif (-not $deniedByOwnRule) { "denied, but by '$($flowDb.ruleName)' rather than a rule you wrote - correct by luck, not by design" }
              else { "access Deny, decided by rule '$($flowDb.ruleName)'" })
    }
}

Write-Host ''

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host '-----------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 04 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 04 acceptance criteria met.' -ForegroundColor Green
exit 0
