[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Verify')]
    [string]$Action = 'Install',
    [string]$GamePath
)

# All runtime messages are plain ASCII on purpose: Windows PowerShell 5.1
# reads BOM-less scripts in the ANSI codepage, so non-ASCII literals are not
# portable.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ModVersion = '4.1'
$script:Multiplier = 90
$script:ExpectedBuildId = '23892411'
# Kept only so an old rule created by 4.1 or earlier can be found and removed.
$script:LegacyFirewallRuleName = 'Codex WWZ x10 Offline Mod - Block Online Access'

# Slim build: patch only the retail release bundle to keep the ZIP under 10 MB.
# 'Mod' is this version (x90). V4x30/V3/V2/V1 are earlier release payloads.
$script:Targets = @(
    [pscustomobject]@{
        Key = 'release'
        EntryName = '[ssl_cache]/initial_release.sslbundle'
        BackupSuffix = 'wwz_x10_release_entry.bak'
        PayloadPath = Join-Path $PSScriptRoot 'payload\initial_release.sslbundle.deflate'
        OriginalCrc = [Convert]::ToUInt32('5EE2D88B', 16)
        OriginalCompressedSize = [uint32]3816685
        OriginalUncompressedSize = [uint32]14452135
        OriginalCompressedSha256 = '402A2BC4C421B0B5CE9AA81217CCBB102ED6F386BE42D77E98CD9D7F4D66719A'
        ModCrc = [Convert]::ToUInt32('7C67602D', 16)
        ModCompressedSize = [uint32]3816227
        ModUncompressedSize = [uint32]14452153
        ModCompressedSha256 = 'FF77BF19EA1BECF3D9F6872AC460EDB40C01EA94AB928D8DC4B8311F98DC9F1A'
        OldStates = @(
            [pscustomobject]@{ Name = 'V4x30'; Crc = [Convert]::ToUInt32('EAC09A21', 16); CompressedSize = [uint32]3816227; UncompressedSize = [uint32]14452153; CompressedSha256 = 'DD5BB1AD1F894B6A5EC9044BAD00EC54758166F8318C59C5B63BDF64FEC70043' }
            [pscustomobject]@{ Name = 'V3'; Crc = [Convert]::ToUInt32('4C27F0CB', 16); CompressedSize = [uint32]3816225; UncompressedSize = [uint32]14452153; CompressedSha256 = '7BCE68BA8FC0DE55EC99747290310B867ADAE93D54115396D3FFC9BC0AD6EB80' }
            [pscustomobject]@{ Name = 'V2'; Crc = [Convert]::ToUInt32('AA33C6D3', 16); CompressedSize = [uint32]3816228; UncompressedSize = [uint32]14452135; CompressedSha256 = '20CB667D88B2B9C269B4EAC131D50749CD6CA700BA9FABBECF70884C27F8FCB4' }
            [pscustomobject]@{ Name = 'V1'; Crc = [Convert]::ToUInt32('C1B7A02A', 16); CompressedSize = [uint32]3816221; UncompressedSize = [uint32]14452135; CompressedSha256 = 'E709B703B539D46D3ACCDFF6C7A7C37FC69B01E7E71CB74DBA444E1D29B159CA' }
        )
    }
)

# In the slim build the legacy check only sees the retail release bundle.
$script:LegacyV1Layout = @{ release = 'V1' }

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ByteArraySha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Find-GamePath([string]$RequestedPath) {
    $candidates = [Collections.Generic.List[string]]::new()
    if ($RequestedPath) {
        $candidates.Add($RequestedPath)
    }

    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        if ($drive.Root -match '^[A-Za-z]:\\$') {
            $candidates.Add((Join-Path $drive.Root 'SteamLibrary\steamapps\common\WWZ'))
        }
    }

    $steamRoots = [Collections.Generic.List[string]]::new()
    foreach ($root in @('C:\Program Files (x86)\Steam', 'C:\Program Files\Steam')) {
        if (Test-Path -LiteralPath $root) {
            $steamRoots.Add($root)
        }
    }
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            foreach ($propertyName in @('SteamPath', 'InstallPath')) {
                $property = $props.PSObject.Properties[$propertyName]
                $value = if ($property) { $property.Value } else { $null }
                if ($value) {
                    $steamRoots.Add([string]$value)
                }
            }
        }
    }

    foreach ($steamRoot in $steamRoots) {
        $candidates.Add((Join-Path $steamRoot 'steamapps\common\WWZ'))
        $libraryFile = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile) {
            $text = Get-Content -LiteralPath $libraryFile -Raw
            foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $libraryRoot = $match.Groups[1].Value -replace '\\\\', '\'
                $candidates.Add((Join-Path $libraryRoot 'steamapps\common\WWZ'))
            }
        }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        $resolvedCandidate = [IO.Path]::GetFullPath($candidate)
        $exe = Join-Path $resolvedCandidate 'en_us\client\bin\pc\wwzRetail.exe'
        $pak = Join-Path $resolvedCandidate 'en_us\client\preload\paks\initial.pak'
        if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $pak)) {
            return $resolvedCandidate.TrimEnd('\')
        }
    }
    throw 'Could not locate the Steam installation of World War Z. Specify the WWZ folder with -GamePath.'
}

function Get-BuildId([string]$ResolvedGamePath) {
    $commonPath = Split-Path $ResolvedGamePath -Parent
    $steamAppsPath = Split-Path $commonPath -Parent
    $manifestPath = Join-Path $steamAppsPath 'appmanifest_699130.acf'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Steam manifest not found: $manifestPath"
    }
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    $match = [regex]::Match($manifestText, '"buildid"\s+"(\d+)"')
    if (-not $match.Success) {
        throw 'Could not read the build ID from the Steam manifest.'
    }
    return $match.Groups[1].Value
}

function Get-ZipEntryInfo([string]$ArchivePath, [string]$WantedName) {
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $tailLength = [int][Math]::Min(65557L, $stream.Length)
        $tailStart = $stream.Length - $tailLength
        $stream.Position = $tailStart
        $tail = $reader.ReadBytes($tailLength)
        $eocdIndex = -1
        for ($index = $tail.Length - 22; $index -ge 0; $index--) {
            if ([BitConverter]::ToUInt32($tail, $index) -eq [uint32]0x06054B50) {
                $eocdIndex = $index
                break
            }
        }
        if ($eocdIndex -lt 0) {
            throw 'Could not find the ZIP central directory.'
        }

        $entryCount = [BitConverter]::ToUInt16($tail, $eocdIndex + 10)
        $centralOffset = [BitConverter]::ToUInt32($tail, $eocdIndex + 16)
        $stream.Position = $centralOffset
        for ($entryIndex = 0; $entryIndex -lt $entryCount; $entryIndex++) {
            $centralHeaderOffset = $stream.Position
            if ($reader.ReadUInt32() -ne [uint32]0x02014B50) {
                throw "ZIP central directory is corrupted (entry $entryIndex)."
            }
            $null = $reader.ReadUInt16()
            $null = $reader.ReadUInt16()
            $flags = $reader.ReadUInt16()
            $compressionMethod = $reader.ReadUInt16()
            $null = $reader.ReadUInt16()
            $null = $reader.ReadUInt16()
            $crc = $reader.ReadUInt32()
            $compressedSize = $reader.ReadUInt32()
            $uncompressedSize = $reader.ReadUInt32()
            $fileNameLength = $reader.ReadUInt16()
            $extraLength = $reader.ReadUInt16()
            $commentLength = $reader.ReadUInt16()
            $null = $reader.ReadUInt16()
            $null = $reader.ReadUInt16()
            $null = $reader.ReadUInt32()
            $localHeaderOffset = $reader.ReadUInt32()
            $fileNameBytes = $reader.ReadBytes($fileNameLength)
            $fileName = [Text.Encoding]::UTF8.GetString($fileNameBytes).Replace('\', '/')
            $stream.Position += $extraLength + $commentLength

            if ($fileName -eq $WantedName) {
                $returnPosition = $stream.Position
                $stream.Position = $localHeaderOffset
                if ($reader.ReadUInt32() -ne [uint32]0x04034B50) {
                    throw 'Local header of the target entry is corrupted.'
                }
                $null = $reader.ReadUInt16()
                $localFlags = $reader.ReadUInt16()
                $localMethod = $reader.ReadUInt16()
                $stream.Position = $localHeaderOffset + 26
                $localFileNameLength = $reader.ReadUInt16()
                $localExtraLength = $reader.ReadUInt16()
                $dataOffset = $localHeaderOffset + 30L + $localFileNameLength + $localExtraLength
                $stream.Position = $returnPosition
                return [pscustomobject]@{
                    Name = $fileName
                    Flags = [uint16]$flags
                    LocalFlags = [uint16]$localFlags
                    CompressionMethod = [uint16]$compressionMethod
                    LocalCompressionMethod = [uint16]$localMethod
                    Crc32 = [uint32]$crc
                    CompressedSize = [uint32]$compressedSize
                    UncompressedSize = [uint32]$uncompressedSize
                    CentralHeaderOffset = [int64]$centralHeaderOffset
                    LocalHeaderOffset = [int64]$localHeaderOffset
                    DataOffset = [int64]$dataOffset
                }
            }
        }
        throw "Target entry not found: $WantedName"
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Read-ArchiveEntryCompressedBytes([string]$ArchivePath, $Entry) {
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $stream.Position = $Entry.DataOffset
        $bytes = [byte[]]::new([int]$Entry.CompressedSize)
        $readTotal = 0
        while ($readTotal -lt $bytes.Length) {
            $read = $stream.Read($bytes, $readTotal, $bytes.Length - $readTotal)
            if ($read -le 0) {
                throw 'Could not read the target entry to the end.'
            }
            $readTotal += $read
        }
        return $bytes
    }
    finally {
        $stream.Dispose()
    }
}

function Write-ArchiveEntry([string]$ArchivePath, $Entry, [byte[]]$CompressedBytes, [uint32]$Crc, [uint32]$UncompressedSize, [uint32]$ReservedSpanSize) {
    if ($CompressedBytes.Length -gt $ReservedSpanSize) {
        throw 'Replacement data is larger than the original entry span; refusing to write.'
    }
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $stream.Position = $Entry.DataOffset
        $stream.Write($CompressedBytes, 0, $CompressedBytes.Length)
        $remaining = [int]($ReservedSpanSize - $CompressedBytes.Length)
        if ($remaining -gt 0) {
            $stream.Write([byte[]]::new($remaining), 0, $remaining)
        }

        $stream.Position = $Entry.LocalHeaderOffset + 14
        $writer.Write([uint32]$Crc)
        $writer.Write([uint32]$CompressedBytes.Length)
        $writer.Write([uint32]$UncompressedSize)

        $stream.Position = $Entry.CentralHeaderOffset + 16
        $writer.Write([uint32]$Crc)
        $writer.Write([uint32]$CompressedBytes.Length)
        $writer.Write([uint32]$UncompressedSize)
        $writer.Flush()
        $stream.Flush($true)
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Assert-ZipEntryShape($Entry) {
    if ($Entry.CompressionMethod -ne 8 -or $Entry.LocalCompressionMethod -ne 8) {
        throw 'Target entry uses an unexpected compression method.'
    }
    if (($Entry.Flags -band 8) -ne 0 -or ($Entry.LocalFlags -band 8) -ne 0) {
        throw 'Target entry uses a data descriptor; this mod cannot handle it.'
    }
}

function Get-EntryState($Entry, [string]$Hash, $Target) {
    if ($Entry.Crc32 -eq $Target.OriginalCrc -and
        $Entry.CompressedSize -eq $Target.OriginalCompressedSize -and
        $Entry.UncompressedSize -eq $Target.OriginalUncompressedSize -and
        $Hash -eq $Target.OriginalCompressedSha256) {
        return 'Original'
    }
    if ($Entry.Crc32 -eq $Target.ModCrc -and
        $Entry.CompressedSize -eq $Target.ModCompressedSize -and
        $Entry.UncompressedSize -eq $Target.ModUncompressedSize -and
        $Hash -eq $Target.ModCompressedSha256) {
        return 'Mod'
    }
    foreach ($old in $Target.OldStates) {
        if ($Entry.Crc32 -eq $old.Crc -and
            $Entry.CompressedSize -eq $old.CompressedSize -and
            $Entry.UncompressedSize -eq $old.UncompressedSize -and
            $Hash -eq $old.CompressedSha256) {
            return $old.Name
        }
    }
    return 'Unknown'
}

function Get-TargetStates([string]$PakPath) {
    $states = [Collections.Generic.List[object]]::new()
    foreach ($target in $script:Targets) {
        $entry = Get-ZipEntryInfo $PakPath $target.EntryName
        Assert-ZipEntryShape $entry
        $bytes = Read-ArchiveEntryCompressedBytes $PakPath $entry
        $hash = Get-ByteArraySha256 $bytes
        $states.Add([pscustomobject]@{
            Target = $target
            Entry = $entry
            Bytes = $bytes
            Hash = $hash
            State = Get-EntryState $entry $hash $target
            BackupPath = "$PakPath.$($target.BackupSuffix)"
        })
    }
    return $states.ToArray()
}

function Test-AllStates($States, [string]$WantedState) {
    return (@($States | Where-Object { $_.State -ne $WantedState }).Count -eq 0)
}

function Test-LegacyV1State($States) {
    foreach ($state in $States) {
        if ($state.State -ne $script:LegacyV1Layout[$state.Target.Key]) {
            return $false
        }
    }
    return $true
}

function Get-StateSummary($States) {
    return (($States | ForEach-Object { "$($_.Target.Key)=$($_.State)" }) -join ', ')
}

function Test-KnownLayout($States) {
    return ((Test-AllStates $States 'Original') -or
            (Test-AllStates $States 'Mod') -or
            (Test-AllStates $States 'V4x30') -or
            (Test-AllStates $States 'V3') -or
            (Test-AllStates $States 'V2') -or
            (Test-LegacyV1State $States))
}

# This build no longer creates any firewall rule. The function below only cleans
# up the outbound block rule left behind by 4.1 and earlier, so upgrading users
# are not left with the game silently blocked from the network.
function Remove-LegacyFirewallBlock {
    if (-not (Get-Command 'Get-NetFirewallRule' -ErrorAction SilentlyContinue)) {
        return
    }
    $existing = Get-NetFirewallRule -DisplayName $script:LegacyFirewallRuleName -ErrorAction SilentlyContinue
    if ($existing) {
        $existing | Remove-NetFirewallRule
        Write-Ok 'Removed the online-block firewall rule left over from an earlier mod version.'
    }
}

if ($Action -ne 'Verify' -and -not (Test-Administrator)) {
    $escapedScriptPath = $PSCommandPath.Replace("'", "''")
    $elevatedCommand = "& '$escapedScriptPath' -Action '$Action'"
    if ($GamePath) {
        $escapedGamePath = $GamePath.Replace("'", "''")
        $elevatedCommand += " -GamePath '$escapedGamePath'"
    }
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedCommand))
    $windowsPowerShell = (Get-Command 'powershell.exe').Source
    $process = Start-Process -FilePath $windowsPowerShell -Verb RunAs -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encodedCommand
    ) -Wait -PassThru
    exit $process.ExitCode
}

if (Get-Process -Name 'wwzRetail' -ErrorAction SilentlyContinue) {
    throw 'World War Z is running. Close the game and try again.'
}

$resolvedGamePath = Find-GamePath $GamePath
$buildId = Get-BuildId $resolvedGamePath
if ($buildId -ne $script:ExpectedBuildId) {
    throw "Unsupported game build. Found: $buildId / supported: $($script:ExpectedBuildId). After a Steam update a new mod build is required."
}

$pakPath = Join-Path $resolvedGamePath 'en_us\client\preload\paks\initial.pak'

Write-Info "Game: $resolvedGamePath"
Write-Info "Steam build: $buildId"

switch ($Action) {
    'Install' {
        $states = Get-TargetStates $pakPath
        if (-not (Test-KnownLayout $states)) {
            throw "initial.pak is in an unexpected state ($(Get-StateSummary $states)). Run Steam's 'Verify integrity of game files' first."
        }

        $payloads = @{}
        foreach ($state in $states) {
            $target = $state.Target
            if (-not (Test-Path -LiteralPath $target.PayloadPath)) {
                throw "Mod payload not found: $($target.PayloadPath)"
            }
            if ((Get-FileSha256 $target.PayloadPath) -ne $target.ModCompressedSha256) {
                throw "Mod payload SHA-256 mismatch ($($target.Key)). The distributed file is corrupted."
            }
            $payload = [IO.File]::ReadAllBytes($target.PayloadPath)
            if ($payload.Length -ne $target.ModCompressedSize) {
                throw "Mod payload size mismatch: $($target.Key)"
            }
            $payloads[$target.Key] = $payload
        }

        if (Test-AllStates $states 'Mod') {
            Remove-LegacyFirewallBlock
            Write-Ok "x$($script:Multiplier) mod $($script:ModVersion) is already installed."
            break
        }

        $createdBackups = [Collections.Generic.List[string]]::new()
        foreach ($state in $states) {
            if (Test-Path -LiteralPath $state.BackupPath) {
                if ((Get-FileSha256 $state.BackupPath) -ne $state.Target.OriginalCompressedSha256) {
                    throw "Existing backup does not match the expected original. Do not delete it; investigate first: $($state.BackupPath)"
                }
            }
            elseif ($state.State -ne 'Original') {
                throw "Backup of the original data (required to upgrade from an older mod) is missing: $($state.BackupPath)"
            }
            else {
                [IO.File]::WriteAllBytes($state.BackupPath, $state.Bytes)
                $createdBackups.Add($state.BackupPath)
                Write-Ok "Created restore backup: $($state.Target.Key)"
            }
        }

        try {
            foreach ($state in $states) {
                $target = $state.Target
                Write-ArchiveEntry $pakPath $state.Entry $payloads[$target.Key] $target.ModCrc $target.ModUncompressedSize $target.OriginalCompressedSize
            }
            $verifyStates = Get-TargetStates $pakPath
            if (-not (Test-AllStates $verifyStates 'Mod')) {
                throw "Post-write verification of the release bundle failed ($(Get-StateSummary $verifyStates))."
            }
        }
        catch {
            $failure = $_
            Write-Host '[ROLLBACK] Install failed; restoring original data.' -ForegroundColor Yellow
            foreach ($state in $states) {
                $rollbackEntry = Get-ZipEntryInfo $pakPath $state.Target.EntryName
                Write-ArchiveEntry $pakPath $rollbackEntry $state.Bytes $state.Entry.Crc32 $state.Entry.UncompressedSize $state.Target.OriginalCompressedSize
            }
            foreach ($path in $createdBackups) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Force
                }
            }
            throw $failure
        }

        Remove-LegacyFirewallBlock
        Write-Ok "Applied x$($script:Multiplier) mod $($script:ModVersion) (final-reward / weapon-XP instructions and module lengths verified)."
        Write-Host 'Always choose OFFLINE in the game menu and play with bots. This build does NOT block the game from going online, so make sure you never enter online play while the mod is installed.' -ForegroundColor Yellow
    }

    'Uninstall' {
        $states = Get-TargetStates $pakPath
        if (-not (Test-KnownLayout $states)) {
            throw "initial.pak is in an unexpected state ($(Get-StateSummary $states)). Run Steam's 'Verify integrity of game files' first."
        }
        if (Test-AllStates $states 'Original') {
            Remove-LegacyFirewallBlock
            Write-Ok 'Game data is already in its original state.'
            break
        }

        $restoreBytes = @{}
        foreach ($state in $states | Where-Object { $_.State -ne 'Original' }) {
            if (-not (Test-Path -LiteralPath $state.BackupPath)) {
                throw "Restore backup missing: $($state.BackupPath)"
            }
            if ((Get-FileSha256 $state.BackupPath) -ne $state.Target.OriginalCompressedSha256) {
                throw "Restore backup SHA-256 mismatch: $($state.Target.Key)"
            }
            $restoreBytes[$state.Target.Key] = [IO.File]::ReadAllBytes($state.BackupPath)
        }

        try {
            foreach ($state in $states | Where-Object { $_.State -ne 'Original' }) {
                $target = $state.Target
                Write-ArchiveEntry $pakPath $state.Entry $restoreBytes[$target.Key] $target.OriginalCrc $target.OriginalUncompressedSize $target.OriginalCompressedSize
            }
            $verifyStates = Get-TargetStates $pakPath
            if (-not (Test-AllStates $verifyStates 'Original')) {
                throw "Post-restore verification of the release bundle failed ($(Get-StateSummary $verifyStates))."
            }
        }
        catch {
            $failure = $_
            Write-Host '[ROLLBACK] Restore failed; returning to the pre-operation state.' -ForegroundColor Yellow
            foreach ($state in $states) {
                $rollbackEntry = Get-ZipEntryInfo $pakPath $state.Target.EntryName
                Write-ArchiveEntry $pakPath $rollbackEntry $state.Bytes $state.Entry.Crc32 $state.Entry.UncompressedSize $state.Target.OriginalCompressedSize
            }
            throw $failure
        }

        Remove-LegacyFirewallBlock
        foreach ($state in $states) {
            if (Test-Path -LiteralPath $state.BackupPath) {
                if ((Get-FileSha256 $state.BackupPath) -eq $state.Target.OriginalCompressedSha256) {
                    Remove-Item -LiteralPath $state.BackupPath -Force
                }
            }
        }
        Write-Ok 'Mod removed; game data restored to original. Temporary restore backups were deleted.'
    }

    'Verify' {
        $states = Get-TargetStates $pakPath
        if (Test-AllStates $states 'Mod') {
            Write-Ok "x$($script:Multiplier) mod $($script:ModVersion) slim: release bundle is valid (module lengths and reward instructions included)."
            Write-Info 'This build does not install a firewall rule. Always choose OFFLINE in the game menu.'
        }
        elseif (Test-AllStates $states 'Original') {
            Write-Info 'Game data is unmodified (mod not installed).'
        }
        elseif ((Test-AllStates $states 'V4x30') -or (Test-AllStates $states 'V3') -or (Test-AllStates $states 'V2') -or (Test-LegacyV1State $states)) {
            throw "Detected an older mod version ($(Get-StateSummary $states)). Run Install_Offline_Mod.cmd of $($script:ModVersion) to upgrade."
        }
        else {
            throw "initial.pak is in an unexpected state: $(Get-StateSummary $states)"
        }
    }
}
