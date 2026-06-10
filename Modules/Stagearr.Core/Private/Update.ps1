#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-update helpers for Stagearr
.DESCRIPTION
    Checks GitHub Releases for new versions, optionally applies updates via ZIP download.
    Stores check timestamps in a JSON file to respect the configured interval.

    Depends on: Constants.ps1, Http.ps1
#>

#region Module State

$script:SAUpdateState = @{
    CheckPerformed  = $false
    UpdateAvailable = $false
    UpdateApplied   = $false
    OldVersion      = ''
    NewVersion      = ''
    ReleaseUrl      = ''
    ErrorMessage    = ''
}

#endregion

#region Timestamp Management

function Get-SAUpdateTimestamp {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )

    $path = Join-Path $QueueRoot $script:SAConstants.UpdateTimestampFile
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $data = ConvertFrom-Json $json
        return @{
            lastCheck = [datetime]::Parse(
                $data.lastCheck,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
        }
    } catch {
        return $null
    }
}

function Save-SAUpdateTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )

    $path = Join-Path $QueueRoot $script:SAConstants.UpdateTimestampFile

    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $data = @{
        lastCheck = (Get-Date).ToUniversalTime().ToString('o')
    }

    $data | ConvertTo-Json -Compress | Set-Content -LiteralPath $path -Encoding UTF8 -Force
}

#endregion

#region Update Check

function Test-SAUpdateCheckDue {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,

        [Parameter(Mandatory = $true)]
        [int]$IntervalHours
    )

    if ($IntervalHours -le 0) {
        return $true
    }

    $timestamp = Get-SAUpdateTimestamp -QueueRoot $QueueRoot
    if ($null -eq $timestamp) {
        return $true
    }

    $elapsed = (Get-Date) - $timestamp.lastCheck.ToLocalTime()
    return $elapsed.TotalHours -ge $IntervalHours
}

function Get-SALatestRelease {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $repo = $script:SAConstants.UpdateGitHubRepo
    $uri = "https://api.github.com/repos/$repo/releases/latest"
    $timeout = $script:SAConstants.UpdateCheckTimeoutSeconds

    $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers @{
        'Accept'     = 'application/vnd.github.v3+json'
        'User-Agent' = 'Stagearr-UpdateCheck'
    } -MaxRetries 1 -TimeoutSeconds $timeout

    if (-not $result.Success -or $null -eq $result.Data) {
        return $null
    }

    $tagName = $result.Data.tag_name
    if ([string]::IsNullOrWhiteSpace($tagName)) {
        return $null
    }

    $versionStr = $tagName -replace '^v', ''

    # Find ZIP and checksum assets
    $zipUrl = $null
    $checksumUrl = $null
    $assetPattern = $script:SAConstants.UpdateAssetPattern
    $checksumFile = $script:SAConstants.UpdateChecksumFile

    if ($result.Data.assets) {
        foreach ($asset in $result.Data.assets) {
            if ($asset.name -like $assetPattern) {
                $zipUrl = $asset.browser_download_url
            }
            if ($asset.name -eq $checksumFile) {
                $checksumUrl = $asset.browser_download_url
            }
        }
    }

    return @{
        Version     = $versionStr
        TagName     = $tagName
        Url         = $result.Data.html_url
        ZipUrl      = $zipUrl
        ChecksumUrl = $checksumUrl
    }
}

function Compare-SAVersions {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalVersion,

        [Parameter(Mandatory = $true)]
        [string]$RemoteVersion
    )

    try {
        $local = [System.Version]$LocalVersion
        $remote = [System.Version]$RemoteVersion
        return $local.CompareTo($remote)
    } catch {
        return [string]::Compare($LocalVersion, $RemoteVersion, [System.StringComparison]::Ordinal)
    }
}

#endregion

#region Git Update

function Test-SAGitRepo {
    <#
    .SYNOPSIS
        Tests whether a directory is a git repository.
    .PARAMETER Path
        Directory to check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $gitDir = Join-Path $Path '.git'
    return (Test-Path -LiteralPath $gitDir)
}

function Invoke-SAGitUpdate {
    <#
    .SYNOPSIS
        Updates the script root via git pull.
    .DESCRIPTION
        For git-cloned installations, pulls latest changes from the remote
        instead of using ZIP extraction, which would dirty the working tree.
    .PARAMETER ScriptRoot
        Path to the Stagearr script root directory (must be a git repo).
    .PARAMETER TagName
        The release tag to pull up to (e.g., 'v2.5.0').
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot,

        [Parameter(Mandatory = $true)]
        [string]$TagName
    )

    try {
        # Fetch latest from remote including tags
        $fetchResult = & git -C $ScriptRoot fetch --tags 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-SAVerbose -Text "git fetch failed: $fetchResult"
            return $false
        }

        # Check for uncommitted changes that would block checkout
        $status = & git -C $ScriptRoot status --porcelain 2>&1
        if ($status) {
            Write-SAVerbose -Text "Working tree has uncommitted changes, stashing before update"
            $stashResult = & git -C $ScriptRoot stash push -m "Stagearr auto-update stash" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-SAVerbose -Text "git stash failed: $stashResult"
                return $false
            }
        }

        # Try to checkout the tag, falling back to pull
        $checkoutResult = & git -C $ScriptRoot checkout $TagName 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $true
        }

        # Fallback: pull latest on current branch
        Write-SAVerbose -Text "Tag checkout failed, trying git pull"
        $pullResult = & git -C $ScriptRoot pull 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-SAVerbose -Text "git pull failed: $pullResult"
            return $false
        }

        return $true
    } catch {
        Write-SAVerbose -Text "Git update failed: $_"
        return $false
    }
}

#endregion

#region Update Application

function Invoke-SADownloadFile {
    <#
    .SYNOPSIS
        Downloads a file from a URL to a local path.
    .DESCRIPTION
        Uses Invoke-WebRequest with -OutFile for binary-safe downloads.
        Ensures TLS 1.2 on PowerShell 5.1.
    .PARAMETER Uri
        The download URL.
    .PARAMETER OutFile
        The local file path to save to.
    .PARAMETER TimeoutSeconds
        Request timeout (default: 60).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$OutFile,

        [Parameter()]
        [int]$TimeoutSeconds = 60
    )

    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSeconds -Headers @{
            'User-Agent' = 'Stagearr-UpdateCheck'
        } -ErrorAction Stop -Verbose:$false
        return $true
    } catch {
        Write-SAVerbose -Text "Download failed ($Uri): $_"
        return $false
    }
}

function Sync-SAUpdatePayload {
    <#
    .SYNOPSIS
        Atomically replaces script-root files with an extracted release payload
        and prunes orphaned release files.
    .DESCRIPTION
        For each top-level item in the extracted payload, stages the new content
        into a sibling ".sa-new" path, moves any existing destination aside to a
        ".sa-old" backup, then swaps the new content into place. Directory and
        file moves are atomic on the same volume, so a failure never leaves the
        install with a half-written or missing entry: completed swaps are rolled
        back from their backups and the function returns $false.

        After all swaps succeed, prunes orphans: any entry in ManagedEntries that
        is present on disk but absent from the new payload is removed. This drops
        files a release renamed or deleted (for example a removed module script)
        so they cannot be dot-sourced again. Entries outside ManagedEntries are
        user data and are never touched.
    .PARAMETER SourceDir
        Directory holding the extracted release payload (top-level release files).
    .PARAMETER ScriptRoot
        The Stagearr script root to update in place.
    .PARAMETER ManagedEntries
        Top-level names the release owns; bounds what orphan pruning may remove.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$ManagedEntries
    )

    # Records completed swaps so they can be rolled back if a later one fails.
    # Each entry: @{ Dest = <path>; Backup = <path or $null> }
    $swapped = @()
    $payloadNames = @()

    try {
        $items = Get-ChildItem -LiteralPath $SourceDir -Force
        foreach ($item in $items) {
            $destPath = Join-Path $ScriptRoot $item.Name
            Assert-SAPathUnderRoot -Path $destPath -Root $ScriptRoot
            $payloadNames += $item.Name

            $newPath = "$destPath.sa-new"
            $backupPath = "$destPath.sa-old"

            # Clear any staging leftovers from a previously aborted update.
            if (Test-Path -LiteralPath $newPath) { Remove-Item -LiteralPath $newPath -Recurse -Force }
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Recurse -Force }

            # Stage the new content next to its destination (same volume = fast).
            Copy-Item -LiteralPath $item.FullName -Destination $newPath -Recurse -Force

            $hadExisting = Test-Path -LiteralPath $destPath
            if ($hadExisting) {
                Move-Item -LiteralPath $destPath -Destination $backupPath -Force
            }

            try {
                Move-Item -LiteralPath $newPath -Destination $destPath -Force
            } catch {
                # Forward swap failed: restore this item's original and re-throw
                # so the outer catch rolls back every earlier swap too.
                if (Test-Path -LiteralPath $newPath) { Remove-Item -LiteralPath $newPath -Recurse -Force }
                if ($hadExisting -and (Test-Path -LiteralPath $backupPath)) {
                    Move-Item -LiteralPath $backupPath -Destination $destPath -Force
                }
                throw
            }

            $swapped += @{ Dest = $destPath; Backup = if ($hadExisting) { $backupPath } else { $null } }
        }

        # All swaps succeeded: discard the backups.
        foreach ($swap in $swapped) {
            if ($swap.Backup -and (Test-Path -LiteralPath $swap.Backup)) {
                Remove-Item -LiteralPath $swap.Backup -Recurse -Force
            }
        }

        # Prune orphans: managed entries on disk but absent from the new payload.
        # Best-effort and non-fatal: the update already succeeded, so a stray
        # leftover should not flip the result to failure.
        foreach ($name in $ManagedEntries) {
            if ($payloadNames -contains $name) { continue }
            $orphan = Join-Path $ScriptRoot $name
            if (-not (Test-Path -LiteralPath $orphan)) { continue }
            try {
                Assert-SAPathUnderRoot -Path $orphan -Root $ScriptRoot
                Remove-Item -LiteralPath $orphan -Recurse -Force
            } catch {
                Write-SAVerbose -Text "Failed to prune orphaned entry '$name': $_"
            }
        }

        return $true
    } catch {
        Write-SAVerbose -Text "Update file sync failed: $_"
        # Roll back completed swaps from their backups, restoring the prior install.
        foreach ($swap in $swapped) {
            if ($swap.Backup -and (Test-Path -LiteralPath $swap.Backup)) {
                try {
                    if (Test-Path -LiteralPath $swap.Dest) { Remove-Item -LiteralPath $swap.Dest -Recurse -Force }
                    Move-Item -LiteralPath $swap.Backup -Destination $swap.Dest -Force
                } catch {
                    Write-SAVerbose -Text "Rollback failed for '$($swap.Dest)': $_"
                }
            }
        }
        return $false
    }
}

function Invoke-SAZipUpdate {
    <#
    .SYNOPSIS
        Downloads and applies a ZIP-based update from GitHub Releases.
    .DESCRIPTION
        Downloads the release ZIP asset, verifies SHA256 checksum, extracts
        to a temp folder, and copies files over the script root.
    .PARAMETER Release
        Release hashtable from Get-SALatestRelease (must include ZipUrl and ChecksumUrl).
    .PARAMETER ScriptRoot
        Path to the Stagearr script root directory.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Release,

        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    # Validate release has asset URLs
    if ([string]::IsNullOrWhiteSpace($Release.ZipUrl)) {
        Write-SAVerbose -Text "No ZIP asset found on release $($Release.TagName)"
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Release.ChecksumUrl)) {
        Write-SAVerbose -Text "No checksum file found on release $($Release.TagName)"
        return $false
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "Stagearr-Update-$(New-Guid)"
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

    try {
        # Download ZIP
        $zipFileName = Split-Path $Release.ZipUrl -Leaf
        $zipPath = Join-Path $tempDir $zipFileName
        Write-SAProgress -Label "Update" -Text "Downloading $zipFileName..."

        $downloadOk = Invoke-SADownloadFile -Uri $Release.ZipUrl -OutFile $zipPath
        if (-not $downloadOk -or -not (Test-Path -LiteralPath $zipPath)) {
            Write-SAVerbose -Text "ZIP download failed"
            return $false
        }

        # Download checksum
        $checksumPath = Join-Path $tempDir 'checksums.txt'
        $checksumOk = Invoke-SADownloadFile -Uri $Release.ChecksumUrl -OutFile $checksumPath
        if (-not $checksumOk -or -not (Test-Path -LiteralPath $checksumPath)) {
            Write-SAVerbose -Text "Checksum download failed"
            return $false
        }

        # Verify checksum - match the specific ZIP filename in checksums.txt
        $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
        $checksumContent = Get-Content -LiteralPath $checksumPath -Raw
        $checksumLines = ($checksumContent.Trim() -split "`n")
        $matchingLine = $checksumLines | Where-Object { $_ -match [regex]::Escape($zipFileName) }
        if (-not $matchingLine) {
            Write-SAVerbose -Text "No checksum entry found for $zipFileName"
            return $false
        }
        $expectedHash = ($matchingLine.Trim() -split '\s+')[0].ToLower()

        if ($actualHash -ne $expectedHash) {
            Write-SAVerbose -Text "Checksum mismatch: expected $expectedHash, got $actualHash"
            return $false
        }

        # Extract ZIP
        $extractDir = Join-Path $tempDir 'extracted'
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        # Apply the payload atomically and prune files dropped by this release.
        Write-SAProgress -Label "Update" -Text "Applying update..."
        return Sync-SAUpdatePayload -SourceDir $extractDir -ScriptRoot $ScriptRoot -ManagedEntries $script:SAConstants.UpdateManagedEntries
    } catch {
        Write-SAVerbose -Text "ZIP update failed: $_"
        return $false
    } finally {
        try {
            if (Test-Path -LiteralPath $tempDir) {
                Remove-Item -LiteralPath $tempDir -Recurse -Force
            }
        } catch {
            Write-SAVerbose -Text "Failed to clean up temp directory: $tempDir"
        }
    }
}

#endregion

#region Main Entry Point

function Invoke-SAUpdateCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$LocalVersion,

        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    # Reset state
    $script:SAUpdateState = @{
        CheckPerformed  = $false
        UpdateAvailable = $false
        UpdateApplied   = $false
        OldVersion      = ''
        NewVersion      = ''
        ReleaseUrl      = ''
        ErrorMessage    = ''
    }

    $mode = if ($Config.updates -and $Config.updates.mode) { $Config.updates.mode } else { 'off' }
    if ($mode -eq 'off') {
        return
    }

    $intervalHours = if ($Config.updates -and $null -ne $Config.updates.checkIntervalHours) {
        $Config.updates.checkIntervalHours
    } else {
        $script:SAConstants.DefaultUpdateCheckIntervalHours
    }

    $queueRoot = $Config.paths.queueRoot
    if ([string]::IsNullOrWhiteSpace($queueRoot)) {
        return
    }

    if (-not (Test-SAUpdateCheckDue -QueueRoot $queueRoot -IntervalHours $intervalHours)) {
        return
    }

    $script:SAUpdateState.CheckPerformed = $true

    $release = Get-SALatestRelease
    if ($null -eq $release) {
        $script:SAUpdateState.ErrorMessage = 'Failed to check for updates'
        Save-SAUpdateTimestamp -QueueRoot $queueRoot
        return
    }

    $comparison = Compare-SAVersions -LocalVersion $LocalVersion -RemoteVersion $release.Version
    if ($comparison -ge 0) {
        $script:SAUpdateState.OldVersion = $LocalVersion
        Write-SAVerbose -Text "Update check: up to date (local $LocalVersion, remote $($release.Version))"
        Save-SAUpdateTimestamp -QueueRoot $queueRoot
        return
    }

    # Update available
    $script:SAUpdateState.UpdateAvailable = $true
    $script:SAUpdateState.NewVersion = $release.Version
    $script:SAUpdateState.ReleaseUrl = $release.Url
    $script:SAUpdateState.OldVersion = $LocalVersion

    if ($mode -eq 'auto') {
        Write-SAProgress -Label "Update" -Text "Updating from v$LocalVersion to v$($release.Version)..."
        $isGitRepo = Test-SAGitRepo -Path $ScriptRoot
        if ($isGitRepo) {
            $updateSuccess = Invoke-SAGitUpdate -ScriptRoot $ScriptRoot -TagName $release.TagName
        } elseif (-not [string]::IsNullOrWhiteSpace($release.ZipUrl)) {
            $updateSuccess = Invoke-SAZipUpdate -Release $release -ScriptRoot $ScriptRoot
        } else {
            $updateSuccess = $false
        }

        if ($updateSuccess) {
            $script:SAUpdateState.UpdateApplied = $true
            Write-SAOutcome -Level Success -Label "Update" -Text "Updated to v$($release.Version)"
        } else {
            Write-SAOutcome -Level Warning -Label "Update" -Text "v$($release.Version) available - download manually from $($release.Url)"
        }
    } else {
        # Notify mode
        Write-SAOutcome -Level Warning -Label "Update" -Text "v$($release.Version) available - download from $($release.Url)"
    }

    Save-SAUpdateTimestamp -QueueRoot $queueRoot
}

function Invoke-SAInteractiveUpdate {
    <#
    .SYNOPSIS
        Interactive update check and apply, triggered by -Update CLI flag.
    .DESCRIPTION
        Always checks for updates (bypasses interval timer). Behavior depends on
        updates.mode config: auto applies immediately, notify/off prompts the user.
    .PARAMETER Config
        Configuration hashtable.
    .PARAMETER LocalVersion
        Current local version string.
    .PARAMETER ScriptRoot
        Path to the script root directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$LocalVersion,

        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    Write-SAProgress -Label "Update" -Text "Checking for updates..."

    $release = Get-SALatestRelease
    if ($null -eq $release) {
        Write-SAOutcome -Level Error -Label "Update" -Text "Failed to check for updates (GitHub API unreachable)"
        return
    }

    # Save timestamp so interval-based checks know we just checked
    $queueRoot = if ($Config.paths -and $Config.paths.queueRoot) { $Config.paths.queueRoot } else { $null }
    if ($queueRoot -and -not [string]::IsNullOrWhiteSpace($queueRoot)) {
        Save-SAUpdateTimestamp -QueueRoot $queueRoot
    }

    $comparison = Compare-SAVersions -LocalVersion $LocalVersion -RemoteVersion $release.Version
    if ($comparison -ge 0) {
        Write-SAOutcome -Level Success -Label "Update" -Text "Already up to date (v$LocalVersion)"
        return
    }

    # Update available
    Write-SAKeyValue -Key "Current version" -Value "v$LocalVersion"
    Write-SAKeyValue -Key "Latest version" -Value "v$($release.Version)"
    Write-SAKeyValue -Key "Release" -Value $release.Url

    $isGitRepo = Test-SAGitRepo -Path $ScriptRoot

    if (-not $isGitRepo -and [string]::IsNullOrWhiteSpace($release.ZipUrl)) {
        Write-SAOutcome -Level Warning -Label "Update" -Text "v$($release.Version) available - download from $($release.Url)"
        return
    }

    # Determine whether to prompt or auto-apply
    $mode = if ($Config.updates -and $Config.updates.mode) { $Config.updates.mode } else { 'off' }
    $shouldPrompt = $mode -ne 'auto'

    if ($shouldPrompt) {
        $method = if ($isGitRepo) { 'git pull' } else { 'ZIP download' }
        $answer = Read-Host -Prompt "  Apply update via ${method}? [Y/n]"
        if ($answer -match '^[Nn]') {
            Write-SAProgress -Label "Update" -Text "Skipped. Download manually from $($release.Url)"
            return
        }
    }

    Write-SAProgress -Label "Update" -Text "Updating from v$LocalVersion to v$($release.Version)..."
    if ($isGitRepo) {
        $updateSuccess = Invoke-SAGitUpdate -ScriptRoot $ScriptRoot -TagName $release.TagName
    } else {
        $updateSuccess = Invoke-SAZipUpdate -Release $release -ScriptRoot $ScriptRoot
    }

    if ($updateSuccess) {
        Write-SAOutcome -Level Success -Label "Update" -Text "Updated to v$($release.Version)"
        Write-SAProgress -Label "Hint" -Text "New settings may have been added. Run: .\Stagearr.ps1 -SyncConfig"
    } else {
        Write-SAOutcome -Level Warning -Label "Update" -Text "v$($release.Version) available - automatic update failed, download from $($release.Url)"
    }
}

function Get-SAUpdateState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return $script:SAUpdateState
}

function Reset-SAUpdateState {
    [CmdletBinding()]
    param()

    $script:SAUpdateState = @{
        CheckPerformed  = $false
        UpdateAvailable = $false
        UpdateApplied   = $false
        OldVersion      = ''
        NewVersion      = ''
        ReleaseUrl      = ''
        ErrorMessage    = ''
    }
}

#endregion
