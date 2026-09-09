#Requires -Version 7.0
<#
.SYNOPSIS
    Validates Lab 09 - Terraform Remote State Done Properly.

.DESCRIPTION
    Read-only. Criteria 1-8 query Azure; criterion 9 scans local files for
    credentials that should not be there.

.EXAMPLE
    pwsh ./validate.ps1 -ResourceGroup rg-lab09-tfstate `
        -StorageAccountName stgtfstate09abc123 -IdentityName id-tfstate-pipeline
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$StorageAccountName,
    [string]$ContainerName = 'tfstate',
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
Write-Host 'Lab 09 - Terraform Remote State Done Properly' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
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
$ResourceGroup      = Ask 'State resource group' $ResourceGroup
$StorageAccountName = Ask 'Storage account name' $StorageAccountName
$IdentityName       = Ask 'Pipeline identity name' $IdentityName
if (-not $ScanPath) { $ScanPath = Split-Path $PSScriptRoot -Parent }
Write-Host ''

$sa = Invoke-Az storage account show -g $ResourceGroup -n $StorageAccountName
if (-not $sa) {
    Write-Host "Storage account '$StorageAccountName' not found in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

$blobProps = Invoke-Az storage account blob-service-properties show -g $ResourceGroup -n $StorageAccountName

# ---------------------------------------------------------------------------
# Durability
# ---------------------------------------------------------------------------

Write-Host 'Durability' -ForegroundColor Cyan

Check 1 'Blob versioning is enabled' `
    ($blobProps.isVersioningEnabled -eq $true) `
    $(if ($blobProps.isVersioningEnabled -eq $true) { 'isVersioningEnabled = true - an interrupted apply is recoverable' }
      else { 'versioning is off. Terraform rewrites the whole state file on every apply, so a bad write is unrecoverable' })

$blobDelete = $blobProps.deleteRetentionPolicy
Check 2 'Blob soft delete is enabled with at least 7 days retention' `
    ($blobDelete.enabled -eq $true -and [int]$blobDelete.days -ge 7) `
    "enabled = $($blobDelete.enabled), days = $($blobDelete.days)"

$containerDelete = $blobProps.containerDeleteRetentionPolicy
Check 3 'Container soft delete is enabled with at least 7 days retention' `
    ($containerDelete.enabled -eq $true -and [int]$containerDelete.days -ge 7) `
    $(if ($containerDelete.enabled -eq $true) { "enabled = true, days = $($containerDelete.days)" }
      else { 'container soft delete is off - versioning does not help if somebody deletes the whole container' })

Write-Host ''

# ---------------------------------------------------------------------------
# Credentials and transport
# ---------------------------------------------------------------------------

Write-Host 'Credentials and transport' -ForegroundColor Cyan

Check 4 'Shared key access is disabled' `
    ($sa.allowSharedKeyAccess -eq $false) `
    $(if ($sa.allowSharedKeyAccess -eq $false) { 'allowSharedKeyAccess = false, so the role assignment below is the thing controlling access' }
      else { 'account keys still work - they grant everything, identify nobody, and make least privilege on this account meaningless' })

$httpsOnly = ($sa.enableHttpsTrafficOnly -eq $true -or $sa.httpsTrafficOnlyEnabled -eq $true)
Check 5 'HTTPS-only traffic is enforced and minimum TLS is 1.2' `
    ($httpsOnly -and $sa.minimumTlsVersion -eq 'TLS1_2') `
    "httpsOnly = $httpsOnly, minimumTlsVersion = $($sa.minimumTlsVersion)"

$containerList = Invoke-Az rest --method get --url "https://management.azure.com$($sa.id)/blobServices/default/containers?api-version=2023-01-01"
$container = @($containerList.value) | Where-Object { $_.name -eq $ContainerName } | Select-Object -First 1

Check 6 "The state container '$ContainerName' exists" `
    ($null -ne $container) `
    $(if ($container) { $container.id } else { "not found. Containers present: $((@($containerList.value) | ForEach-Object { $_.name }) -join ', ')" })

Write-Host ''

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

Write-Host 'Permissions' -ForegroundColor Cyan

$identity = Invoke-Az identity show -g $ResourceGroup -n $IdentityName
if (-not $identity) {
    Check 7 'The pipeline identity holds Storage Blob Data Contributor scoped to the container' $false "managed identity '$IdentityName' not found in '$ResourceGroup'"
    Check 8 'The pipeline identity holds no key-reading role at a wider scope' $false 'identity not found'
}
else {
    $principalId = $identity.principalId
    $allForPrincipal = @(Invoke-Az role assignment list --assignee $principalId --all)

    $containerScope = if ($container) { $container.id } else { "$($sa.id)/blobServices/default/containers/$ContainerName" }
    $stateRole = @($allForPrincipal | Where-Object {
        $_.roleDefinitionName -eq 'Storage Blob Data Contributor' -and $_.scope -eq $containerScope
    }) | Select-Object -First 1

    $accountScopeRole = @($allForPrincipal | Where-Object {
        $_.roleDefinitionName -like 'Storage Blob Data*' -and $_.scope -eq $sa.id
    }) | Select-Object -First 1

    Check 7 'The pipeline identity holds Storage Blob Data Contributor scoped to the container' `
        ($null -ne $stateRole) `
        $(if ($stateRole) { "scoped to $ContainerName, which is the natural boundary and costs nothing extra" }
          elseif ($accountScopeRole) { "$($accountScopeRole.roleDefinitionName) is assigned at ACCOUNT scope - that covers every container that will ever exist here, including other teams' state" }
          else { "no Storage Blob Data Contributor assignment found for $IdentityName" })

    $keyReaderRoles = @('Owner', 'Contributor', 'Storage Account Contributor', 'User Access Administrator')
    $widerScopes = @($sa.id, "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup", "/subscriptions/$($account.id)")
    $keyReaders = @($allForPrincipal | Where-Object {
        $_.roleDefinitionName -in $keyReaderRoles -and $_.scope -in $widerScopes
    })

    Check 8 'The pipeline identity holds no key-reading role at a wider scope' `
        ($keyReaders.Count -eq 0) `
        $(if ($keyReaders.Count -gt 0) { "over-granted: $(($keyReaders | ForEach-Object { "$($_.roleDefinitionName) at $($_.scope)" }) -join '; ')" }
          else { "$($allForPrincipal.Count) assignment(s) in total, none of them able to read account keys" })
}

Write-Host ''

# ---------------------------------------------------------------------------
# No secrets in the configuration
# ---------------------------------------------------------------------------

Write-Host 'Configuration hygiene' -ForegroundColor Cyan

$patterns = @(
    @{ Name = 'access_key';          Regex = '(?im)^\s*access_key\s*=' },
    @{ Name = 'sas_token';           Regex = '(?im)^\s*sas_token\s*=' },
    @{ Name = 'ARM_ACCESS_KEY';      Regex = 'ARM_ACCESS_KEY' },
    @{ Name = 'connection string';   Regex = '(?i)AccountKey\s*=' },
    @{ Name = 'storage key literal'; Regex = '(?i)DefaultEndpointsProtocol\s*=' }
)

$files = @()
if (Test-Path $ScanPath) {
    $files = @(Get-ChildItem -Path $ScanPath -Recurse -File -Include '*.tf', '*.tfvars', '*.yml', '*.yaml' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.terraform\\' })
}

$hits = @()
foreach ($f in $files) {
    $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    foreach ($p in $patterns) {
        if ($content -match $p.Regex) {
            $hits += "$($p.Name) in $($f.FullName.Replace($ScanPath, '.'))"
        }
    }
}

Check 9 'No account key, SAS token or connection string appears in the configuration' `
    ($hits.Count -eq 0) `
    $(if ($hits.Count -gt 0) { $hits -join '; ' }
      else { "scanned $($files.Count) file(s) under $ScanPath" })

Write-Host ''
Write-Host '---------------------------------------------' -ForegroundColor Cyan
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)
Write-Host ''

if ($script:Failed -gt 0) {
    Write-Host 'Lab 09 acceptance criteria NOT met.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lab 09 acceptance criteria met.' -ForegroundColor Green
exit 0
