#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 01 - Fully Private Web App with a Locked-Down Jump VM.

.DESCRIPTION
    Read-only. Queries Azure with the Azure CLI and reports a PASS or FAIL line
    for each acceptance criterion in README.md. Exits 0 if everything passed,
    1 otherwise.

    Assumes you are already signed in ("az login") and that the correct
    subscription is selected ("az account set --subscription <id>").

.EXAMPLE
    pwsh ./validate.ps1

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab01 -VnetName vnet-lab01 `
        -WebAppName app-lab01-1234 -SqlServerName sql-lab01-1234 -JumpVmName vm-jump
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$VnetName,
    [string]$WebAppName,
    [string]$SqlServerName,
    [string]$JumpVmName,
    [string]$DnsResourceGroup,
    [switch]$PublicProbe
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
    if ($Ok) {
        $script:Passed++
        Write-Host "  [PASS] $tag  $Name" -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host "  [FAIL] $tag  $Name" -ForegroundColor Red
    }
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
Write-Host 'Lab 01 - Fully Private Web App with a Locked-Down Jump VM' -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan
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
$WebAppName    = Ask 'Web app name' $WebAppName
$SqlServerName = Ask 'SQL logical server name' $SqlServerName
$JumpVmName    = Ask 'Jump VM name' $JumpVmName
if (-not $DnsResourceGroup) { $DnsResourceGroup = $ResourceGroup }
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

# ---------------------------------------------------------------------------
# The web app
# ---------------------------------------------------------------------------

Write-Host 'Web app' -ForegroundColor Cyan

$app = Invoke-Az webapp show -g $ResourceGroup -n $WebAppName
if (-not $app) {
    Write-Host "  Web app '$WebAppName' not found in '$ResourceGroup'. Cannot continue." -ForegroundColor Red
    exit 1
}
$pna = $app.publicNetworkAccess
if (-not $pna) {
    # Older CLI versions do not surface it on "az webapp show".
    $appProps = Invoke-Az resource show --ids $app.id --query properties
    if ($appProps) { $pna = $appProps.publicNetworkAccess }
}

Check 1 'Web app public network access is Disabled' `
    ($pna -eq 'Disabled') `
    "publicNetworkAccess = $(if ($pna) { $pna } else { '<not set>' })"

$endpoints = Invoke-Az network private-endpoint list -g $ResourceGroup
if (-not $endpoints) { $endpoints = @() }

$webPe = $endpoints | Where-Object {
    $_.privateLinkServiceConnections | Where-Object {
        $_.privateLinkServiceId -eq $app.id -and $_.groupIds -contains 'sites'
    }
} | Select-Object -First 1

$webPeState = $null
$webPeIp = $null
if ($webPe) {
    $conn = $webPe.privateLinkServiceConnections | Where-Object { $_.privateLinkServiceId -eq $app.id } | Select-Object -First 1
    $webPeState = $conn.privateLinkServiceConnectionState.status
    $webPeIp = ($webPe.customDnsConfigs | Select-Object -First 1).ipAddresses | Select-Object -First 1
    if (-not $webPeIp) {
        $webPeIp = ($webPe.networkInterfaces | ForEach-Object {
            (Invoke-Az network nic show --ids $_.id).ipConfigurations.privateIPAddress
        } | Select-Object -First 1)
    }
}

Check 2 'Web app has an approved private endpoint (group sites)' `
    ($null -ne $webPe -and $webPeState -eq 'Approved') `
    $(if ($webPe) { "$($webPe.name), connection state $webPeState, IP $webPeIp" } else { 'no private endpoint found targeting this app' })

$webZone = Invoke-Az network private-dns zone show -g $DnsResourceGroup -n 'privatelink.azurewebsites.net'
$webZoneLinks = @()
$webZoneRecord = $null
if ($webZone) {
    $webZoneLinks = @(Invoke-Az network private-dns link vnet list -g $DnsResourceGroup -z 'privatelink.azurewebsites.net')
    $records = @(Invoke-Az network private-dns record-set a list -g $DnsResourceGroup -z 'privatelink.azurewebsites.net')
    $webZoneRecord = $records | Where-Object { $_.name -eq $WebAppName } | Select-Object -First 1
}
$webLinked = @($webZoneLinks | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
$webRecordIp = if ($webZoneRecord) { ($webZoneRecord.aRecords | Select-Object -First 1).ipv4Address } else { $null }

Check 3 'privatelink.azurewebsites.net exists, is linked to the VNet, and resolves the app to a private address' `
    ($null -ne $webZone -and $webLinked -and (Test-PrivateIp $webRecordIp)) `
    $(if (-not $webZone) { "zone not found in resource group '$DnsResourceGroup'" }
      elseif (-not $webLinked) { "zone exists but has no vnet link to $VnetName" }
      elseif (-not $webRecordIp) { "zone linked but no A record named '$WebAppName' - the private endpoint has no DNS zone group" }
      else { "$WebAppName -> $webRecordIp" })

$integratedSubnetId = $app.virtualNetworkSubnetId
$integratedSubnet = $null
if ($integratedSubnetId) { $integratedSubnet = Invoke-Az network vnet subnet show --ids $integratedSubnetId }
$delegated = $false
if ($integratedSubnet -and $integratedSubnet.delegations) {
    $delegated = @($integratedSubnet.delegations | Where-Object { $_.serviceName -eq 'Microsoft.Web/serverFarms' }).Count -gt 0
}

Check 4 'Web app has regional VNet integration into a delegated subnet' `
    ($null -ne $integratedSubnet -and $delegated) `
    $(if (-not $integratedSubnetId) { 'no virtualNetworkSubnetId on the app - VNet integration is not configured' }
      elseif (-not $delegated) { "integrated into $($integratedSubnet.name) but it is not delegated to Microsoft.Web/serverFarms" }
      else { "integrated into $($integratedSubnet.name) ($($integratedSubnet.addressPrefix))" })

$webConfig = Invoke-Az webapp config show -g $ResourceGroup -n $WebAppName
$routeAll = $webConfig.vnetRouteAllEnabled

Check 5 'vnetRouteAllEnabled is true (all outbound goes through the VNet)' `
    ($routeAll -eq $true) `
    "vnetRouteAllEnabled = $routeAll"

Check 6 'Web app has a system-assigned managed identity' `
    ($null -ne $app.identity -and $app.identity.type -match 'SystemAssigned') `
    $(if ($app.identity) { "principalId $($app.identity.principalId)" } else { 'no identity assigned' })

$appSettings = @(Invoke-Az webapp config appsettings list -g $ResourceGroup -n $WebAppName)
$connStrings = Invoke-Az webapp config connection-string list -g $ResourceGroup -n $WebAppName

$secretPattern = '(?i)(password\s*=|pwd\s*=|user id\s*=.*password)'
$leaky = @()
foreach ($s in $appSettings) {
    if ($s.value -and $s.value -match $secretPattern) { $leaky += "app setting '$($s.name)'" }
}
$connValues = @()
if ($connStrings) {
    foreach ($p in $connStrings.PSObject.Properties) {
        $v = $p.Value.value
        $connValues += [pscustomobject]@{ Name = $p.Name; Value = $v }
        if ($v -and $v -match $secretPattern) { $leaky += "connection string '$($p.Name)'" }
    }
}

Check 7 'No password appears in any app setting or connection string' `
    ($leaky.Count -eq 0) `
    $(if ($leaky.Count -gt 0) { "credential material found in: $($leaky -join ', ')" } else { "checked $($appSettings.Count) app settings and $($connValues.Count) connection strings" })

$entraConn = @($connValues | Where-Object { $_.Value -match '(?i)Authentication\s*=\s*Active Directory' })

Check 8 'A connection string uses Entra authentication' `
    ($entraConn.Count -gt 0) `
    $(if ($entraConn.Count -gt 0) { "'$($entraConn[0].Name)' uses Active Directory authentication" } else { 'no connection string with "Authentication=Active Directory ..." found' })

Write-Host ''

# ---------------------------------------------------------------------------
# Azure SQL
# ---------------------------------------------------------------------------

Write-Host 'Azure SQL' -ForegroundColor Cyan

$sql = Invoke-Az sql server show -g $ResourceGroup -n $SqlServerName
if (-not $sql) {
    Check 9  'SQL server public network access is Disabled' $false "SQL server '$SqlServerName' not found in '$ResourceGroup'"
    Check 10 'SQL server has Entra-only authentication enabled' $false 'server not found'
    Check 11 'SQL server has an approved private endpoint (group sqlServer)' $false 'server not found'
    Check 12 'privatelink.database.windows.net exists, is linked, and resolves the server privately' $false 'server not found'
}
else {
    Check 9 'SQL server public network access is Disabled' `
        ($sql.publicNetworkAccess -eq 'Disabled') `
        "publicNetworkAccess = $($sql.publicNetworkAccess)"

    $adOnly = Invoke-Az sql server ad-only-auth get -g $ResourceGroup -n $SqlServerName
    Check 10 'SQL server has Entra-only authentication enabled' `
        ($adOnly.azureAdOnlyAuthentication -eq $true) `
        "azureAdOnlyAuthentication = $($adOnly.azureAdOnlyAuthentication)"

    $sqlPe = $endpoints | Where-Object {
        $_.privateLinkServiceConnections | Where-Object {
            $_.privateLinkServiceId -eq $sql.id -and $_.groupIds -contains 'sqlServer'
        }
    } | Select-Object -First 1

    $sqlPeState = $null
    if ($sqlPe) {
        $conn = $sqlPe.privateLinkServiceConnections | Where-Object { $_.privateLinkServiceId -eq $sql.id } | Select-Object -First 1
        $sqlPeState = $conn.privateLinkServiceConnectionState.status
    }

    Check 11 'SQL server has an approved private endpoint (group sqlServer)' `
        ($null -ne $sqlPe -and $sqlPeState -eq 'Approved') `
        $(if ($sqlPe) { "$($sqlPe.name), connection state $sqlPeState" } else { 'no private endpoint found targeting this server' })

    $sqlZone = Invoke-Az network private-dns zone show -g $DnsResourceGroup -n 'privatelink.database.windows.net'
    $sqlLinked = $false
    $sqlRecordIp = $null
    if ($sqlZone) {
        $links = @(Invoke-Az network private-dns link vnet list -g $DnsResourceGroup -z 'privatelink.database.windows.net')
        $sqlLinked = @($links | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
        $rec = @(Invoke-Az network private-dns record-set a list -g $DnsResourceGroup -z 'privatelink.database.windows.net') |
            Where-Object { $_.name -eq $SqlServerName } | Select-Object -First 1
        if ($rec) { $sqlRecordIp = ($rec.aRecords | Select-Object -First 1).ipv4Address }
    }

    Check 12 'privatelink.database.windows.net exists, is linked, and resolves the server privately' `
        ($null -ne $sqlZone -and $sqlLinked -and (Test-PrivateIp $sqlRecordIp)) `
        $(if (-not $sqlZone) { "zone not found in resource group '$DnsResourceGroup'" }
          elseif (-not $sqlLinked) { "zone exists but has no vnet link to $VnetName" }
          elseif (-not $sqlRecordIp) { "zone linked but no A record named '$SqlServerName'" }
          else { "$SqlServerName -> $sqlRecordIp" })
}

Write-Host ''

# ---------------------------------------------------------------------------
# The jump VM
# ---------------------------------------------------------------------------

Write-Host 'Jump VM' -ForegroundColor Cyan

$vm = Invoke-Az vm show -g $ResourceGroup -n $JumpVmName
if (-not $vm) {
    Check 13 'Jump VM has no public IP address' $false "VM '$JumpVmName' not found in '$ResourceGroup'"
    Check 14 'Jump subnet routes 0.0.0.0/0 to next hop None' $false 'VM not found'
    Check 15 'Jump subnet NSG denies outbound to Internet ahead of any allow' $false 'VM not found'
    Check 16 'Jump subnet NSG allows outbound to the app private endpoint on 443' $false 'VM not found'
}
else {
    $publicIps = @()
    $vmSubnetId = $null
    $nicNsgId = $null
    foreach ($nicRef in $vm.networkProfile.networkInterfaces) {
        $nic = Invoke-Az network nic show --ids $nicRef.id
        if (-not $nic) { continue }
        if ($nic.networkSecurityGroup) { $nicNsgId = $nic.networkSecurityGroup.id }
        foreach ($ipc in $nic.ipConfigurations) {
            if ($ipc.publicIPAddress) { $publicIps += $ipc.publicIPAddress.id }
            if (-not $vmSubnetId -and $ipc.subnet) { $vmSubnetId = $ipc.subnet.id }
        }
    }

    Check 13 'Jump VM has no public IP address' `
        ($publicIps.Count -eq 0) `
        $(if ($publicIps.Count -gt 0) { "public IP attached: $(($publicIps | Split-Path -Leaf) -join ', ')" } else { 'no public IP on any NIC' })

    $vmSubnet = if ($vmSubnetId) { Invoke-Az network vnet subnet show --ids $vmSubnetId } else { $null }

    $defaultRoute = $null
    if ($vmSubnet -and $vmSubnet.routeTable) {
        $rt = Invoke-Az network route-table show --ids $vmSubnet.routeTable.id
        $routes = @($rt.routes)
        $defaultRoute = $routes | Where-Object { $_.addressPrefix -eq '0.0.0.0/0' } | Select-Object -First 1
    }

    Check 14 'Jump subnet routes 0.0.0.0/0 to next hop None' `
        ($null -ne $defaultRoute -and $defaultRoute.nextHopType -eq 'None') `
        $(if (-not $vmSubnet) { 'could not resolve the VM subnet' }
          elseif (-not $vmSubnet.routeTable) { "subnet '$($vmSubnet.name)' has no route table - the default internet route is still in place" }
          elseif (-not $defaultRoute) { 'route table attached but it has no 0.0.0.0/0 route' }
          else { "0.0.0.0/0 -> $($defaultRoute.nextHopType)" })

    $nsgId = if ($vmSubnet -and $vmSubnet.networkSecurityGroup) { $vmSubnet.networkSecurityGroup.id } else { $nicNsgId }
    $nsg = if ($nsgId) { Invoke-Az network nsg show --ids $nsgId } else { $null }

    if (-not $nsg) {
        Check 15 'Jump subnet NSG denies outbound to Internet ahead of any allow' $false 'no NSG on the jump subnet or the VM NIC'
        Check 16 'Jump subnet NSG allows outbound to the app private endpoint on 443' $false 'no NSG found'
    }
    else {
        $outbound = @($nsg.securityRules | Where-Object { $_.direction -eq 'Outbound' } | Sort-Object priority)

        function Test-TargetsInternet {
            param($Rule)
            $dests = @()
            if ($Rule.destinationAddressPrefix) { $dests += $Rule.destinationAddressPrefix }
            if ($Rule.destinationAddressPrefixes) { $dests += $Rule.destinationAddressPrefixes }
            return @($dests | Where-Object { $_ -in @('Internet', '0.0.0.0/0', '*') }).Count -gt 0
        }

        $firstInternetRule = $outbound | Where-Object { Test-TargetsInternet $_ } | Select-Object -First 1

        Check 15 'Jump subnet NSG denies outbound to Internet ahead of any allow' `
            ($null -ne $firstInternetRule -and $firstInternetRule.access -eq 'Deny') `
            $(if (-not $firstInternetRule) { "NSG '$($nsg.name)' has no explicit outbound rule for Internet - the default AllowInternetOutBound at 65001 still applies" }
              else { "first matching rule: '$($firstInternetRule.name)' priority $($firstInternetRule.priority) access $($firstInternetRule.access)" })

        $appAllow = $null
        if ($webPeIp) {
            $appAllow = $outbound | Where-Object {
                $_.access -eq 'Allow' -and
                (($_.destinationAddressPrefix -and $_.destinationAddressPrefix -like "$webPeIp*") -or
                 ($_.destinationAddressPrefixes -and (@($_.destinationAddressPrefixes | Where-Object { $_ -like "$webPeIp*" }).Count -gt 0))) -and
                (($_.destinationPortRange -in @('443', '*')) -or ($_.destinationPortRanges -contains '443'))
            } | Select-Object -First 1
        }

        if (-not $webPeIp) {
            Skip 16 'Jump subnet NSG allows outbound to the app private endpoint on 443' 'the app private endpoint IP could not be determined, so this rule cannot be matched'
        }
        else {
            Check 16 'Jump subnet NSG allows outbound to the app private endpoint on 443' `
                ($null -ne $appAllow) `
                $(if ($appAllow) { "'$($appAllow.name)' priority $($appAllow.priority) -> $webPeIp:443" } else { "no outbound Allow rule targeting $webPeIp on 443" })
        }
    }
}

Write-Host ''

# ---------------------------------------------------------------------------
# Optional public probe
# ---------------------------------------------------------------------------

if ($PublicProbe) {
    Write-Host 'Public reachability' -ForegroundColor Cyan
    $hostName = $app.defaultHostName
    $status = $null
    $probeError = $null
    try {
        $resp = Invoke-WebRequest -Uri "https://$hostName" -Method Head -TimeoutSec 15 -SkipHttpErrorCheck
        $status = $resp.StatusCode
    }
    catch {
        $probeError = $_.Exception.Message
    }

    Check 17 'The app does not serve traffic on its public hostname' `
        ($status -ne 200) `
        $(if ($probeError) { "https://$hostName -> request failed: $probeError" }
          else { "https://$hostName -> HTTP $status (403 is the expected result with public network access disabled)" })
    Write-Host ''
}
else {
    Write-Host 'Public reachability' -ForegroundColor Cyan
    Skip 17 'The app does not serve traffic on its public hostname' 'pass -PublicProbe to run this check, from a machine outside the virtual network'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host '---------------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 01 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 01 acceptance criteria met.' -ForegroundColor Green
exit 0
