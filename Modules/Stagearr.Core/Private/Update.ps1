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

    return @{
        Version = $versionStr
        TagName = $tagName
        Url     = $result.Data.html_url
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

function Invoke-SAGitPull {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    try {
        $gitResult = & git -C $ScriptRoot pull origin main 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return $true
        }
        Write-SAVerbose -Text "git pull failed (exit $exitCode): $gitResult"
        return $false
    } catch {
        Write-SAVerbose -Text "git pull error: $_"
        return $false
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
            $script:SAUpdateState.ErrorMessage = 'git pull failed'
            Write-SAOutcome -Level Warning -Label "Update" -Text "Update to v$($release.Version) failed — run 'git pull' manually"
        }
    } else {
        # Notify mode
        Write-SAOutcome -Level Warning -Label "Update" -Text "v$($release.Version) available — run 'git pull' to update"
    }

    Save-SAUpdateTimestamp -QueueRoot $queueRoot
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
