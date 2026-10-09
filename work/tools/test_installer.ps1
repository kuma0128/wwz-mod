# End-to-end test of the shipped installer against a stand-in pak:
#   phase A: fresh install  (Original -> Mod), byte-validate, uninstall
#   phase B: upgrade path   (stage an older mod state + backups -> Mod), uninstall
#          phase B is skipped unless -OldPayloadDir is supplied.
#
# Drives the shipped installer's own functions, so it tests the real code
# rather than a copy. No admin rights are needed: this build creates no
# firewall rule, and the elevation branch is never reached.
#
# The stand-in pak is modified in place, so point -PakPath at a COPY of
# en_us\client\preload\paks\initial.pak, never at the live game file.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PakPath,
    [string]$PackageRoot,
    [string]$PayloadDir,
    [string]$OldPayloadDir,
    [string]$OldStateName = 'V4x30',
    [string]$Python = "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolsDir = $PSScriptRoot
$workDir = Split-Path $toolsDir -Parent

if (-not $PackageRoot) { $PackageRoot = Join-Path $workDir 'package' }
if (-not $PayloadDir) { $PayloadDir = Join-Path $workDir 'payloads' }
$validator = Join-Path $toolsDir 'validate_installed_pak.py'

$installer = Get-ChildItem -LiteralPath $PackageRoot -Filter '*.ps1' -File |
    Where-Object Name -notlike 'test_*' |
    Select-Object -First 1
if (-not $installer) { throw "no installer .ps1 found in $PackageRoot" }

foreach ($required in @($PakPath, $PayloadDir, $validator)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "missing required path: $required" }
}
if (-not (Test-Path -LiteralPath $Python)) { throw "python not found: $Python (pass -Python)" }

Write-Host "[INFO] installer : $($installer.FullName)"
Write-Host "[INFO] test pak  : $PakPath"

# ---- load the installer's functions and $script: tables without running it ----
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer.FullName, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw "installer failed to parse: $($errors[0].Message)"
}
Write-Host '[ OK ] installer parses cleanly' -ForegroundColor Green

foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $fn.Extent.Text
}
foreach ($stmt in $ast.EndBlock.Statements) {
    if ($stmt -is [Management.Automation.Language.AssignmentStatementAst] -and
        $stmt.Left.Extent.Text -like '$script:*') {
        Invoke-Expression ($stmt.Extent.Text -replace '\$PSScriptRoot', "'$PackageRoot'")
    }
}
Write-Host "[ OK ] loaded installer table: version $($script:ModVersion), multiplier x$($script:Multiplier)" -ForegroundColor Green

# Validate exactly the entries this package patches. The slim package touches
# 'release' only; checking all three would compare untouched entries against
# modded build output and fail for the wrong reason.
$configKeys = @($script:Targets | ForEach-Object { $_.Key })
Write-Host "[INFO] patched entries: $($configKeys -join ', ')"

function Get-Summary { Get-StateSummary (Get-TargetStates $PakPath) }

function Invoke-Validator {
    & $Python $validator $PakPath $PayloadDir --configs @configKeys
    if ($LASTEXITCODE -ne 0) { throw 'python validation of installed pak failed' }
}

function Install-Payloads([hashtable]$PayloadByKey, [string]$ExpectState) {
    $states = Get-TargetStates $PakPath
    foreach ($state in $states) {
        $target = $state.Target
        Write-ArchiveEntry $PakPath $state.Entry $PayloadByKey[$target.Key].Bytes `
            $PayloadByKey[$target.Key].Crc $PayloadByKey[$target.Key].UncompressedSize $target.OriginalCompressedSize
    }
    $after = Get-TargetStates $PakPath
    if (-not (Test-AllStates $after $ExpectState)) {
        throw "expected all $ExpectState, got: $(Get-StateSummary $after)"
    }
}

function Get-ModPayloads {
    $result = @{}
    foreach ($target in $script:Targets) {
        $hash = (Get-FileHash -LiteralPath $target.PayloadPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($hash -ne $target.ModCompressedSha256) { throw "payload hash mismatch: $($target.Key)" }
        $result[$target.Key] = @{
            Bytes = [IO.File]::ReadAllBytes($target.PayloadPath)
            Crc = $target.ModCrc
            UncompressedSize = $target.ModUncompressedSize
        }
    }
    return $result
}

function Get-OldPayloads {
    $result = @{}
    foreach ($target in $script:Targets) {
        $old = $target.OldStates | Where-Object { $_.Name -eq $OldStateName }
        if (-not $old) { throw "installer has no old state named $OldStateName" }
        $path = Join-Path $OldPayloadDir (Split-Path $target.PayloadPath -Leaf)
        $bytes = [IO.File]::ReadAllBytes($path)
        if ((Get-ByteArraySha256 $bytes) -ne $old.CompressedSha256) { throw "$OldStateName payload mismatch: $($target.Key)" }
        $result[$target.Key] = @{
            Bytes = $bytes
            Crc = $old.Crc
            UncompressedSize = $old.UncompressedSize
        }
    }
    return $result
}

function Restore-Original {
    $states = Get-TargetStates $PakPath
    foreach ($state in $states | Where-Object { $_.State -ne 'Original' }) {
        $target = $state.Target
        if (-not (Test-Path -LiteralPath $state.BackupPath)) { throw "missing backup: $($state.BackupPath)" }
        if ((Get-FileSha256 $state.BackupPath) -ne $target.OriginalCompressedSha256) { throw "backup sha mismatch: $($target.Key)" }
        Write-ArchiveEntry $PakPath $state.Entry ([IO.File]::ReadAllBytes($state.BackupPath)) `
            $target.OriginalCrc $target.OriginalUncompressedSize $target.OriginalCompressedSize
    }
    $after = Get-TargetStates $PakPath
    if (-not (Test-AllStates $after 'Original')) { throw "restore failed: $(Get-StateSummary $after)" }
}

# ---- phase A: fresh install ----
Write-Host "`n--- phase A: fresh install ---"
Write-Host "[INFO] start: $(Get-Summary)"
$states = Get-TargetStates $PakPath
if (-not (Test-AllStates $states 'Original')) { throw 'test pak must start Original' }
if (-not (Test-KnownLayout $states)) { throw 'Original layout not recognised' }

# simulate the installer's backup step
foreach ($state in $states) {
    [IO.File]::WriteAllBytes($state.BackupPath, $state.Bytes)
}
Install-Payloads (Get-ModPayloads) 'Mod'
Write-Host "[ OK ] fresh install -> $(Get-Summary)" -ForegroundColor Green

Invoke-Validator
Write-Host "[ OK ] installed entries byte-match the x$($script:Multiplier) build output" -ForegroundColor Green

Restore-Original
Write-Host "[ OK ] uninstall -> $(Get-Summary)" -ForegroundColor Green

# ---- phase B: upgrade from an older mod state ----
if (-not $OldPayloadDir) {
    Write-Host "`n[SKIP] phase B: pass -OldPayloadDir with the $OldStateName payloads to exercise the upgrade path." -ForegroundColor Yellow
}
elseif (-not (Test-Path -LiteralPath $OldPayloadDir)) {
    throw "-OldPayloadDir does not exist: $OldPayloadDir"
}
else {
    Write-Host "`n--- phase B: upgrade from $OldStateName ---"
    Install-Payloads (Get-OldPayloads) $OldStateName
    Write-Host "[ OK ] staged $OldStateName state -> $(Get-Summary)" -ForegroundColor Green

    $states = Get-TargetStates $PakPath
    if (-not (Test-KnownLayout $states)) { throw "$OldStateName layout not recognised by Test-KnownLayout" }
    foreach ($state in $states) {
        # Install flow for a non-Original state: backups must already exist and match
        if (-not (Test-Path -LiteralPath $state.BackupPath)) { throw "upgrade requires backup: $($state.BackupPath)" }
        if ((Get-FileSha256 $state.BackupPath) -ne $state.Target.OriginalCompressedSha256) { throw 'backup sha mismatch during upgrade' }
    }
    Install-Payloads (Get-ModPayloads) 'Mod'
    Write-Host "[ OK ] upgrade $OldStateName -> x$($script:Multiplier) -> $(Get-Summary)" -ForegroundColor Green

    Invoke-Validator
    Write-Host "[ OK ] upgraded entries byte-match the x$($script:Multiplier) build output" -ForegroundColor Green

    Restore-Original
}

foreach ($state in Get-TargetStates $PakPath) {
    if (Test-Path -LiteralPath $state.BackupPath) { Remove-Item -LiteralPath $state.BackupPath -Force }
}
Write-Host "[ OK ] final state -> $(Get-Summary)" -ForegroundColor Green

Write-Host "`nALL $($script:ModVersion) INSTALLER TESTS PASSED" -ForegroundColor Green
