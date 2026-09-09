#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 14 - Diagnostics Enforced by Policy.

.DESCRIPTION
    Read-only. Reports a PASS or FAIL line for each acceptance criterion in
    README.md and exits 0 if everything passed, 1 otherwise.

.EXAMPLE
    pwsh ./validate.ps1 -WorkspaceResourceGroup rg-lab14 `
        -WorkspaceName law-lab14-abc123 -AssignmentName enforce-nsg-diagnostics `
        -TestResourceGroup rg-lab14
#>
[CmdletBinding()]
param(
    [string]$WorkspaceResourceGroup,
    [string]$WorkspaceName,
    [string]$PolicyDefinitionName = 'deploy-nsg-diagnostics',
    [string]$AssignmentName,
    [string]$TestResourceGroup
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
Write-Host 'Lab 14 - Diagnostics Enforced by Policy' -ForegroundColor Cyan
Write-Host '=======================================' -ForegroundColor Cyan
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
$WorkspaceResourceGroup = Ask 'Resource group holding the Log Analytics workspace' $WorkspaceResourceGroup
$WorkspaceName          = Ask 'Log Analytics workspace name' $WorkspaceName
$AssignmentName         = Ask 'Policy assignment name' $AssignmentName
Write-Host ''

$subscriptionScope = "/subscriptions/$($account.id)"

# ---------------------------------------------------------------------------
# Workspace and definition
# ---------------------------------------------------------------------------

Write-Host 'Workspace and definition' -ForegroundColor Cyan

$law = Invoke-Az monitor log-analytics workspace show -g $WorkspaceResourceGroup -n $WorkspaceName

Check 1 'A Log Analytics workspace exists' `
    ($null -ne $law) `
    $(if ($law) { "$($law.name), retention $($law.retentionInDays) days" }
      else { "workspace '$WorkspaceName' not found in '$WorkspaceResourceGroup'" })

$definition = Invoke-Az policy definition show -n $PolicyDefinitionName

$effect = $null
$hasExistenceCondition = $false
if ($definition) {
    $rule = $definition.policyRule
    $details = $rule.then.details
    $rawEffect = $rule.then.effect

    # The effect is often parameterised, in which case read the default.
    if ($rawEffect -match "^\[parameters\('(.+)'\)\]$") {
        $paramName = $Matches[1]
        $effect = $definition.parameters.$paramName.defaultValue
    }
    else {
        $effect = $rawEffect
    }

    $hasExistenceCondition = ($null -ne $details -and $null -ne $details.existenceCondition)
}

Check 2 'A custom policy definition exists with the deployIfNotExists effect' `
    ($null -ne $definition -and $effect -match '(?i)^deployIfNotExists$') `
    $(if (-not $definition) { "policy definition '$PolicyDefinitionName' not found" }
      elseif ($effect -match '(?i)auditIfNotExists') { "effect is $effect - it reports non-compliance and deploys nothing" }
      else { "effect = $effect, mode = $($definition.mode)" })

Check 3 'The definition has an existence condition, so it is idempotent' `
    $hasExistenceCondition `
    $(if (-not $definition) { 'no definition' }
      elseif (-not $hasExistenceCondition) { 'no existenceCondition - the policy cannot tell "already correct" from "needs deploying" and will either never fire or redeploy constantly' }
      else { 'existenceCondition present' })

Write-Host ''

# ---------------------------------------------------------------------------
# Assignment
# ---------------------------------------------------------------------------

Write-Host 'Assignment' -ForegroundColor Cyan

$assignment = Invoke-Az policy assignment show -n $AssignmentName --scope $subscriptionScope

Check 4 'The policy is assigned at subscription scope' `
    ($null -ne $assignment -and $assignment.scope -eq $subscriptionScope) `
    $(if (-not $assignment) { "assignment '$AssignmentName' not found at subscription scope" }
      else { "scope $($assignment.scope)" })

$principalId = if ($assignment -and $assignment.identity) { $assignment.identity.principalId } else { $null }

Check 5 'The assignment has a managed identity' `
    ($null -ne $principalId) `
    $(if ($principalId) { "$($assignment.identity.type), principalId $principalId, location $($assignment.location)" }
      else { 'no identity - a deployIfNotExists assignment with no identity cannot deploy anything' })

if (-not $principalId) {
    Check 6 'The identity holds Monitoring Contributor and Log Analytics Contributor' $false 'no identity'
    Check 7 'The identity does not hold Owner or Contributor at subscription scope' $false 'no identity'
}
else {
    $assignments = @(Invoke-Az role assignment list --assignee $principalId --all)
    $roleNames = @($assignments | ForEach-Object { $_.roleDefinitionName })

    $hasMonitoring = $roleNames -contains 'Monitoring Contributor'
    $hasLaw = $roleNames -contains 'Log Analytics Contributor'

    Check 6 'The identity holds Monitoring Contributor and Log Analytics Contributor' `
        ($hasMonitoring -and $hasLaw) `
        $(if ($assignments.Count -eq 0) { 'the identity has no roles at all. The policy will evaluate happily, report resources as non-compliant, and silently fail every deployment' }
          else { "roles: $(($roleNames | Sort-Object -Unique) -join ', ')$(if (-not $hasMonitoring) { ' - Monitoring Contributor missing' })$(if (-not $hasLaw) { ' - Log Analytics Contributor missing' })" })

    $overGranted = @($assignments | Where-Object {
        $_.roleDefinitionName -in @('Owner', 'Contributor', 'User Access Administrator') -and $_.scope -eq $subscriptionScope
    })

    Check 7 'The identity does not hold Owner or Contributor at subscription scope' `
        ($overGranted.Count -eq 0) `
        $(if ($overGranted.Count -gt 0) { "$(($overGranted | ForEach-Object { $_.roleDefinitionName }) -join ', ') - this is a standing, unattended, fully privileged principal" }
          else { 'only the two roles the deployment template actually needs' })
}

$workspaceParam = $null
if ($assignment -and $assignment.parameters) {
    foreach ($p in $assignment.parameters.PSObject.Properties) {
        if ($p.Value.value -is [string] -and $p.Value.value -match '(?i)/workspaces/') {
            $workspaceParam = $p.Value.value
            break
        }
    }
}

Check 8 "The assignment's workspace parameter points at the workspace" `
    ($null -ne $law -and $workspaceParam -eq $law.id) `
    $(if (-not $workspaceParam) { 'no workspace parameter found on the assignment' }
      elseif ($law -and $workspaceParam -ne $law.id) { "points at $(Split-Path $workspaceParam -Leaf), not $WorkspaceName" }
      else { "-> $WorkspaceName" })

$enforcement = if ($assignment) { $assignment.enforcementMode } else { $null }

Check 9 'Enforcement mode is Default, not DoNotEnforce' `
    ($enforcement -eq 'Default') `
    $(if ($enforcement -eq 'DoNotEnforce') { 'DoNotEnforce - the policy reports compliance and deploys nothing' }
      else { "enforcementMode = $enforcement" })

Write-Host ''

# ---------------------------------------------------------------------------
# Remediation
# ---------------------------------------------------------------------------

Write-Host 'Remediation' -ForegroundColor Cyan

$remediations = @(Invoke-Az policy remediation list)
$mine = @($remediations | Where-Object { $assignment -and $_.policyAssignmentId -eq $assignment.id })

Check 10 'A remediation task exists for the assignment' `
    ($mine.Count -gt 0) `
    $(if ($mine.Count -gt 0) { (($mine | ForEach-Object { "$($_.name): $($_.provisioningState)" }) -join '; ') }
      else { 'no remediation task. Policy fires on create and update, so everything that existed before the assignment stays non-compliant forever - it is never going to be created again' })

Write-Host ''

# ---------------------------------------------------------------------------
# Did it actually work
# ---------------------------------------------------------------------------

Write-Host 'Effect on real resources' -ForegroundColor Cyan

if (-not $TestResourceGroup) {
    Skip 11 'Network security groups have a diagnostic setting pointing at the workspace' 'pass -TestResourceGroup to check that the policy did its job'
}
elseif (-not $law) {
    Skip 11 'Network security groups have a diagnostic setting pointing at the workspace' 'the workspace could not be resolved'
}
else {
    $nsgs = @(Invoke-Az network nsg list -g $TestResourceGroup)

    if ($nsgs.Count -eq 0) {
        Skip 11 'Network security groups have a diagnostic setting pointing at the workspace' "no network security groups in '$TestResourceGroup' to check"
    }
    else {
        $missing = @()
        $configured = @()
        foreach ($nsg in $nsgs) {
            $result = Invoke-Az monitor diagnostic-settings list --resource $nsg.id
            $settings = if ($result -and $result.PSObject.Properties.Name -contains 'value') { @($result.value) } else { @($result) }
            $match = @($settings | Where-Object { $_ -and $_.workspaceId -eq $law.id }) | Select-Object -First 1
            if ($match) { $configured += "$($nsg.name) -> $($match.name)" } else { $missing += $nsg.name }
        }

        Check 11 'Network security groups have a diagnostic setting pointing at the workspace' `
            ($missing.Count -eq 0) `
            $(if ($missing.Count -gt 0) { "no setting on: $($missing -join ', '). Give it a few minutes after creation - the deployment is quick, but do not judge this by the compliance dashboard, which lags by up to half an hour" }
              else { "$($configured.Count) NSG(s) configured by policy: $($configured -join '; ')" })
    }
}

Write-Host ''
Write-Host '---------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 14 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 14 acceptance criteria met.' -ForegroundColor Green
exit 0
