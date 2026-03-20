#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-update helpers for Stagearr
.DESCRIPTION
    Checks GitHub Releases for new versions, optionally applies updates via git pull.
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

        # Verify checksum
        $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
        $checksumContent = Get-Content -LiteralPath $checksumPath -Raw
        $expectedHash = ($checksumContent.Trim() -split '\s+')[0].ToLower()

        if ($actualHash -ne $expectedHash) {
            Write-SAVerbose -Text "Checksum mismatch: expected $expectedHash, got $actualHash"
            return $false
        }

        # Extract ZIP
        $extractDir = Join-Path $tempDir 'extracted'
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        # Copy files to script root
        Write-SAProgress -Label "Update" -Text "Applying update..."
        $items = Get-ChildItem -Path $extractDir -Force
        foreach ($item in $items) {
            $destPath = Join-Path $ScriptRoot $item.Name
            if ($item.PSIsContainer) {
                if (Test-Path -LiteralPath $destPath) {
                    Remove-Item -LiteralPath $destPath -Recurse -Force
                }
                Copy-Item -LiteralPath $item.FullName -Destination $destPath -Recurse -Force
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination $destPath -Force
            }
        }

        return $true
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
        $pullSuccess = Invoke-SAGitPull -ScriptRoot $ScriptRoot
        if ($pullSuccess) {
            $script:SAUpdateState.UpdateApplied = $true
            Write-SAOutcome -Level Success -Label "Update" -Text "Updated to v$($release.Version)"
        } else {
            Write-SAOutcome -Level Warning -Label "Update" -Text "v$($release.Version) available - run 'git pull' to update"
        }
    } else {
        # Notify mode
        Write-SAOutcome -Level Warning -Label "Update" -Text "v$($release.Version) available - run 'git pull' to update"
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

    # Determine whether to prompt or auto-apply
    $mode = if ($Config.updates -and $Config.updates.mode) { $Config.updates.mode } else { 'off' }
    $shouldPrompt = $mode -ne 'auto'

    if ($shouldPrompt) {
        $answer = Read-Host -Prompt "  Apply update? [Y/n]"
        if ($answer -match '^[Nn]') {
            Write-SAProgress -Label "Update" -Text "Skipped. Run 'git pull' to update manually."
            return
        }
    }

    Write-SAProgress -Label "Update" -Text "Updating from v$LocalVersion to v$($release.Version)..."
    $pullSuccess = Invoke-SAGitPull -ScriptRoot $ScriptRoot

    if ($pullSuccess) {
        Write-SAOutcome -Level Success -Label "Update" -Text "Updated to v$($release.Version)"
        Write-SAProgress -Label "Hint" -Text "New settings may have been added. Run: .\Stagearr.ps1 -SyncConfig"
    } else {
        Write-SAOutcome -Level Warning -Label "Update" -Text "v$($release.Version) available - automatic update failed, run 'git pull' to update"
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
