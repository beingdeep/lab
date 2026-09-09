#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 11 - Gated Infrastructure Deployment with Preview.

.DESCRIPTION
    Read-only. Criterion 1 queries Azure. Criteria 2-6 inspect workflow files.
    Criteria 7 and 8 use the GitHub CLI to read the environment's protection
    rules, and are skipped if gh is unavailable or -GitHubRepo is not supplied.

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab11 -GitHubRepo myorg/my-infra
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$ScanPath,
    [string]$GitHubRepo,
    [string]$EnvironmentName = 'production'
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

function Invoke-Gh {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GhArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = & gh @GhArgs 2>$null
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
Write-Host 'Lab 11 - Gated Infrastructure Deployment with Preview' -ForegroundColor Cyan
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

$ResourceGroup = Ask 'Resource group the pipeline manages' $ResourceGroup
if (-not $ScanPath) { $ScanPath = Split-Path $PSScriptRoot -Parent }
Write-Host ''

# ---------------------------------------------------------------------------
# Something to plan against
# ---------------------------------------------------------------------------

Write-Host 'Target' -ForegroundColor Cyan

$rg = Invoke-Az group show -n $ResourceGroup
$resources = if ($rg) { @(Invoke-Az resource list -g $ResourceGroup) } else { @() }

Check 1 'The target resource group exists with something in it to plan against' `
    ($null -ne $rg -and $resources.Count -gt 0) `
    $(if (-not $rg) { "resource group '$ResourceGroup' not found" }
      elseif ($resources.Count -eq 0) { 'the group is empty - a plan against nothing shows everything as new, which is the easy case' }
      else { "$($resources.Count) resource(s): $(($resources | ForEach-Object { $_.name }) -join ', ')" })

Write-Host ''

# ---------------------------------------------------------------------------
# The pipeline
# ---------------------------------------------------------------------------

Write-Host 'Pipeline' -ForegroundColor Cyan

$files = @()
if (Test-Path $ScanPath) {
    $files = @(Get-ChildItem -Path $ScanPath -Recurse -File -Include '*.yml', '*.yaml' -ErrorAction SilentlyContinue)
}

$workflows = @()
foreach ($f in $files) {
    $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    if ($content -notmatch '(?i)terraform|bicep|what-if') { continue }
    $workflows += [pscustomobject]@{
        Path    = $f.FullName.Replace($ScanPath, '.')
        Content = $content
    }
}

if ($workflows.Count -eq 0) {
    foreach ($n in 2..6) {
        Check $n 'Pipeline check' $false "no infrastructure pipeline files found under $ScanPath - point -ScanPath at your repository"
    }
}
else {
    Write-Host "              found $($workflows.Count) pipeline file(s): $(($workflows | ForEach-Object { $_.Path }) -join ', ')" -ForegroundColor DarkGray

    $withPlan = @($workflows | Where-Object { $_.Content -match '(?i)terraform\s+plan|az\s+deployment\s+\S+\s+what-if' })
    Check 2 'A pipeline runs a plan or what-if step' `
        ($withPlan.Count -gt 0) `
        $(if ($withPlan.Count -gt 0) { (($withPlan | ForEach-Object { $_.Path }) -join ', ') }
          else { 'no plan or what-if step found - nothing is being previewed before it runs' })

    $withArtifact = @($workflows | Where-Object {
        $_.Content -match '(?i)-out\s*=\s*\S+' -and
        $_.Content -match '(?i)upload-artifact|publish:|PublishPipelineArtifact'
    })
    Check 3 'The plan is written to a file and published as an artefact' `
        ($withArtifact.Count -gt 0) `
        $(if ($withArtifact.Count -gt 0) { "$(($withArtifact | ForEach-Object { $_.Path }) -join ', ') - this is the evidence you can produce a year later" }
          else { 'no saved plan published - "we reviewed it" is an assertion, an attached artefact is a record' })

    $appliesSaved = @($workflows | Where-Object {
        $_.Content -match '(?i)(download-artifact|download:)' -and
        $_.Content -match '(?i)terraform\s+apply[^\r\n]*tfplan'
    })
    $appliesFresh = @($workflows | Where-Object {
        $_.Content -match '(?i)terraform\s+apply[^\r\n]*-auto-approve' -and
        $_.Content -notmatch '(?i)terraform\s+apply[^\r\n]*tfplan'
    })

    Check 4 'The apply consumes the published artefact and applies the saved plan' `
        ($appliesSaved.Count -gt 0 -and $appliesFresh.Count -eq 0) `
        $(if ($appliesFresh.Count -gt 0) { "$(($appliesFresh | ForEach-Object { $_.Path }) -join ', ') runs apply with -auto-approve and no saved plan - it plans again, so the approval refers to a plan nobody ran" }
          elseif ($appliesSaved.Count -eq 0) { 'no apply step applies a saved plan file' }
          else { (($appliesSaved | ForEach-Object { $_.Path }) -join ', ') })

    $withEnvironment = @($workflows | Where-Object { $_.Content -match '(?im)^\s*environment\s*:' })
    Check 5 'The apply job is bound to a deployment environment' `
        ($withEnvironment.Count -gt 0) `
        $(if ($withEnvironment.Count -gt 0) { "$(($withEnvironment | ForEach-Object { $_.Path }) -join ', ') - protection rules live on the environment, where a pull request cannot edit them" }
          else { 'no environment binding found - a gate written inside the workflow can be removed by the same commit it is gating' })

    $ungated = @()
    foreach ($w in $workflows) {
        if ($w.Content -match '(?i)terraform\s+apply' -and $w.Content -notmatch '(?im)^\s*environment\s*:') {
            $ungated += $w.Path
        }
    }
    Check 6 'No pipeline runs an apply outside an environment binding' `
        ($ungated.Count -eq 0) `
        $(if ($ungated.Count -gt 0) { "ungated apply in: $($ungated -join ', ')" }
          else { 'every apply sits behind an environment' })
}

Write-Host ''

# ---------------------------------------------------------------------------
# The gate itself
# ---------------------------------------------------------------------------

Write-Host 'Approval gate' -ForegroundColor Cyan

$ghAvailable = [bool](Get-Command gh -ErrorAction SilentlyContinue)

if (-not $GitHubRepo -or -not $ghAvailable) {
    $reason = if (-not $ghAvailable) { 'the GitHub CLI (gh) was not found on PATH' } else { 'pass -GitHubRepo owner/repo to read the environment protection rules' }
    Skip 7 'The environment has required reviewers' $reason
    Skip 8 'The environment prevents self-review' $reason
}
else {
    $env = Invoke-Gh api "repos/$GitHubRepo/environments/$EnvironmentName"

    if (-not $env) {
        Check 7 'The environment has required reviewers' $false "could not read environment '$EnvironmentName' in $GitHubRepo - is gh signed in with access?"
        Check 8 'The environment prevents self-review' $false 'environment not readable'
    }
    else {
        $reviewerRule = @($env.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }) | Select-Object -First 1
        $reviewers = if ($reviewerRule) { @($reviewerRule.reviewers) } else { @() }

        Check 7 'The environment has required reviewers' `
            ($reviewers.Count -gt 0) `
            $(if ($reviewers.Count -gt 0) { "$($reviewers.Count) reviewer(s) configured on '$EnvironmentName'" }
              else { "no required reviewers on '$EnvironmentName' - the environment exists but gates nothing" })

        $preventSelfReview = if ($reviewerRule) { $reviewerRule.prevent_self_review } else { $null }

        Check 8 'The environment prevents self-review' `
            ($preventSelfReview -eq $true) `
            $(if ($preventSelfReview -eq $true) { 'prevent_self_review = true' }
              else { 'prevent_self_review is off - the author clicks approve on their own change and the control has achieved a delay and nothing else. It is one checkbox, and it is off by default' })
    }
}

Write-Host ''
Write-Host '-----------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 11 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 11 acceptance criteria met.' -ForegroundColor Green
exit 0
