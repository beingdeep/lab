#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 10 - Secretless Pipelines with Workload Identity Federation.

.DESCRIPTION
    Read-only. Criteria 1-8 query Azure; criterion 9 scans workflow files for a
    stored credential.

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab10 -IdentityName id-deploy-lab10
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$IdentityName,
    [string]$ScanPath
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

Write-Host ''
Write-Host 'Lab 10 - Secretless Pipelines with Workload Identity Federation' -ForegroundColor Cyan
Write-Host '===============================================================' -ForegroundColor Cyan
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
$IdentityName  = Ask 'Pipeline identity name' $IdentityName
if (-not $ScanPath) { $ScanPath = Split-Path $PSScriptRoot -Parent }
Write-Host ''

# ---------------------------------------------------------------------------
# The identity
# ---------------------------------------------------------------------------

Write-Host 'Identity' -ForegroundColor Cyan

$identity = Invoke-Az identity show -g $ResourceGroup -n $IdentityName

Check 1 'A user-assigned managed identity exists for the pipeline' `
    ($null -ne $identity) `
    $(if ($identity) { "clientId $($identity.clientId) - a managed identity cannot hold a client secret, so nobody can undo this lab by adding one" }
      else { "managed identity '$IdentityName' not found in '$ResourceGroup'" })

if (-not $identity) {
    Write-Host ''
    Write-Host 'Cannot continue without the identity.' -ForegroundColor Red
    exit 1
}

$creds = @(Invoke-Az identity federated-credential list -g $ResourceGroup --identity-name $IdentityName)

Check 2 'At least one federated identity credential is configured' `
    ($creds.Count -gt 0) `
    $(if ($creds.Count -gt 0) { "$($creds.Count) credential(s): $(($creds | ForEach-Object { $_.name }) -join ', ')" }
      else { 'none configured - nothing can authenticate as this identity from outside Azure' })

Write-Host ''

# ---------------------------------------------------------------------------
# Federation configuration
# ---------------------------------------------------------------------------

Write-Host 'Federation' -ForegroundColor Cyan

$knownIssuers = @(
    'https://token.actions.githubusercontent.com',
    'https://vstoken.dev.azure.com'
)

$badIssuers = @($creds | Where-Object {
    $iss = $_.issuer
    @($knownIssuers | Where-Object { $iss -like "$_*" }).Count -eq 0
})

Check 3 'Every federated credential uses a recognised OIDC issuer' `
    ($creds.Count -gt 0 -and $badIssuers.Count -eq 0) `
    $(if ($creds.Count -eq 0) { 'no credentials to check' }
      elseif ($badIssuers.Count -gt 0) { "unrecognised issuer on: $(($badIssuers | ForEach-Object { "$($_.name) -> $($_.issuer)" }) -join '; ')" }
      else { (($creds | ForEach-Object { $_.issuer } | Sort-Object -Unique) -join ', ') })

$badAudience = @($creds | Where-Object { $_.audiences -notcontains 'api://AzureADTokenExchange' })

Check 4 'Every federated credential audience is api://AzureADTokenExchange' `
    ($creds.Count -gt 0 -and $badAudience.Count -eq 0) `
    $(if ($badAudience.Count -gt 0) { "wrong audience on: $(($badAudience | ForEach-Object { "$($_.name) -> $($_.audiences -join ',')" }) -join '; ')" }
      else { 'the audience is what stops a token minted for another service being replayed at Entra' })

# Entra has no wildcards, but these subject shapes are the practical equivalents.
$looseSubjects = @($creds | Where-Object {
    $s = $_.subject
    $s -match '\*' -or
    $s -match ':pull_request$' -or
    $s -match ':ref:refs/heads/\*' -or
    ($s -match '^repo:[^:]+/[^:]+$')
})

Check 5 'No federated credential subject is broader than a specific branch or environment' `
    ($creds.Count -gt 0 -and $looseSubjects.Count -eq 0) `
    $(if ($looseSubjects.Count -gt 0) { "too broad: $(($looseSubjects | ForEach-Object { "$($_.name) -> $($_.subject)" }) -join '; ')" }
      else { (($creds | ForEach-Object { $_.subject }) -join '; ') })

$branchCred = @($creds | Where-Object { $_.subject -match ':ref:refs/heads/[^*]+$' })
$envCred    = @($creds | Where-Object { $_.subject -match ':environment:[^*]+$' })

Check 6 'There is a credential for a specific branch and one for a specific environment' `
    ($branchCred.Count -gt 0 -and $envCred.Count -gt 0) `
    $(if ($branchCred.Count -eq 0) { 'no branch-scoped credential - nothing ties deployment to reviewed code' }
      elseif ($envCred.Count -eq 0) { 'no environment-scoped credential - nothing ties deployment to an approval gate' }
      else { "branch: $($branchCred[0].subject) | environment: $($envCred[0].subject)" })

Write-Host ''

# ---------------------------------------------------------------------------
# What the token can do
# ---------------------------------------------------------------------------

Write-Host 'Authorisation' -ForegroundColor Cyan

$assignments = @(Invoke-Az role assignment list --assignee $identity.principalId --all)

# A resource group scope has 5 segments after the leading slash split; anything
# shorter is a subscription or management group.
$tooWide = @($assignments | Where-Object {
    $_.scope -match '^/subscriptions/[^/]+$' -or $_.scope -match '^/providers/Microsoft\.Management/managementGroups/' -or $_.scope -eq '/'
})

Check 7 'Role assignments are scoped no wider than a resource group' `
    ($assignments.Count -gt 0 -and $tooWide.Count -eq 0) `
    $(if ($assignments.Count -eq 0) { 'no role assignments at all - the pipeline can authenticate but cannot do anything' }
      elseif ($tooWide.Count -gt 0) { "too wide: $(($tooWide | ForEach-Object { "$($_.roleDefinitionName) at $($_.scope)" }) -join '; ') - federation controls who gets a token, RBAC controls what it can do" }
      else { (($assignments | ForEach-Object { "$($_.roleDefinitionName) at $(Split-Path $_.scope -Leaf)" }) -join '; ') })

$dangerousRoles = @($assignments | Where-Object { $_.roleDefinitionName -in @('Owner', 'User Access Administrator', 'Role Based Access Control Administrator') })

Check 8 'The identity holds neither Owner nor User Access Administrator' `
    ($dangerousRoles.Count -eq 0) `
    $(if ($dangerousRoles.Count -gt 0) { "$(($dangerousRoles | ForEach-Object { "$($_.roleDefinitionName) at $($_.scope)" }) -join '; ') - these can create role assignments, so the pipeline can grant itself anything" }
      else { 'no role that can hand out permissions' })

Write-Host ''

# ---------------------------------------------------------------------------
# Workflow files
# ---------------------------------------------------------------------------

Write-Host 'Workflow files' -ForegroundColor Cyan

$files = @()
if (Test-Path $ScanPath) {
    $files = @(Get-ChildItem -Path $ScanPath -Recurse -File -Include '*.yml', '*.yaml' -ErrorAction SilentlyContinue)
}

$secretHits = @()
$oidcFiles = @()
foreach ($f in $files) {
    $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    $rel = $f.FullName.Replace($ScanPath, '.')

    if ($content -match '(?im)^\s*client-secret\s*:') { $secretHits += "client-secret in $rel" }
    if ($content -match '(?im)^\s*creds\s*:')         { $secretHits += "creds blob in $rel" }
    if ($content -match 'AZURE_CREDENTIALS')          { $secretHits += "AZURE_CREDENTIALS in $rel" }
    if ($content -match 'secrets\.AZURE_CLIENT_SECRET') { $secretHits += "AZURE_CLIENT_SECRET in $rel" }

    if ($content -match '(?im)id-token\s*:\s*write') { $oidcFiles += $rel }
}

Check 9 'Workflow files request an OIDC token and contain no client secret' `
    ($secretHits.Count -eq 0 -and $oidcFiles.Count -gt 0) `
    $(if ($secretHits.Count -gt 0) { $secretHits -join '; ' }
      elseif ($files.Count -eq 0) { "no workflow files found under $ScanPath - point -ScanPath at your repository" }
      elseif ($oidcFiles.Count -eq 0) { "no workflow requests 'id-token: write', so GitHub will not mint a token at all" }
      else { "$($oidcFiles.Count) workflow file(s) using OIDC, none with a stored credential" })

Write-Host ''
Write-Host '---------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 10 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 10 acceptance criteria met.' -ForegroundColor Green
exit 0
