#Requires -Version 7.0
<#
.SYNOPSIS
    Targeted Kodi library updates for Stagearr
.DESCRIPTION
    After an import, scans only the imported title's folder in Kodi over JSON-RPC, then
    confirms the title appeared.

    Kodi answers OK to several requests that do nothing, so the response proves little:
    - A scan path without a trailing slash is treated as its parent. A new show then adds
      nothing, and season folders can be scraped as shows.
    - A scan of a season folder creates a bogus show.
    - A scan of a missing directory only logs a warning.
    - A scan sent during a scan cancels the running one and is itself dropped.

    Hence every path comes from Files.GetDirectory, Stagearr waits for Kodi to be idle
    before scanning, and success is judged from the library afterwards.

    Best-effort: nothing here throws, and a failure never changes the job outcome. The
    import has already happened by the time this runs.
#>

#region Pure Helper Functions

function Get-SAKodiPathMap {
    <#
    .SYNOPSIS
        Parses kodi.pathMap entries of the form "arrPath|kodiPath". Pure function.
    .DESCRIPTION
        The TOML parser unrolls a one-element array to a plain string, so the value is
        always read through @(). Malformed entries are dropped; Test-SAKodiConfig reports
        a map with no usable entry.
    .PARAMETER PathMap
        Raw kodi.pathMap value: string, array of strings, or $null.
    .OUTPUTS
        PSCustomObject[] with From and To.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$PathMap
    )

    $entries = @()
    foreach ($entry in @($PathMap)) {
        if ($entry -isnot [string]) {
            continue
        }
        # The TOML parser keeps the quotes of a single-quoted array item
        $parts = $entry.Trim().Trim("'", '"').Split('|', 2)
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
            continue
        }
        $entries += [PSCustomObject]@{
            From = $parts[0].Trim()
            To   = $parts[1].Trim()
        }
    }

    return $entries
}

function ConvertTo-SAKodiPath {
    <#
    .SYNOPSIS
        Maps a Radarr/Sonarr title root to Kodi's form. Pure function.
    .DESCRIPTION
        Returns the parent folder and the title folder separately, because the exact path
        to scan must come from Kodi's own listing of the parent.

        The longest matching prefix wins. Matching ignores case and stops at a path
        boundary, so D:\Data does not match D:\Data2.
    .PARAMETER ArrPath
        Title root as reported by Radarr or Sonarr.
    .PARAMETER PathMap
        Entries from Get-SAKodiPathMap.
    .OUTPUTS
        PSCustomObject with Parent (ends in /) and Leaf, or $null when unmapped.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArrPath,

        [Parameter()]
        [AllowNull()]
        [object[]]$PathMap
    )

    $normalized = $ArrPath.Replace('\', '/').TrimEnd('/')
    $best = $null
    $bestPrefix = ''

    foreach ($entry in @($PathMap)) {
        if ($null -eq $entry) {
            continue
        }
        $prefix = $entry.From.Replace('\', '/').TrimEnd('/')
        if ($prefix.Length -gt $bestPrefix.Length -and
            $normalized.StartsWith("$prefix/", [StringComparison]::OrdinalIgnoreCase)) {
            $best = $entry
            $bestPrefix = $prefix
        }
    }

    if ($null -eq $best) {
        return $null
    }

    $relative = $normalized.Substring($bestPrefix.Length + 1)
    $separator = $relative.LastIndexOf('/')
    $base = $best.To.TrimEnd('/')
    if ($separator -ge 0) {
        $base = "$base/$($relative.Substring(0, $separator))"
    }

    return [PSCustomObject]@{
        Parent = "$base/"
        Leaf   = $relative.Substring($separator + 1)
    }
}

function Test-SAKodiConfig {
    <#
    .SYNOPSIS
        Lists problems with the [kodi] section. Pure function.
    .DESCRIPTION
        Deliberately separate from config validation, which aborts before a job is queued:
        a Kodi typo must only disable this step, never stop a torrent being processed.
    .PARAMETER Config
        Full configuration hashtable.
    .OUTPUTS
        String array of problems, empty when usable.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $problems = @()
    if ([string]::IsNullOrWhiteSpace($Config.kodi.host)) {
        $problems += 'kodi.host is empty'
    }
    if (@(Get-SAKodiPathMap -PathMap $Config.kodi.pathMap).Count -eq 0) {
        $problems += 'kodi.pathMap has no valid "arrPath|kodiPath" entry'
    }

    return $problems
}

function Get-SAKodiTargets {
    <#
    .SYNOPSIS
        Lists the titles one import touched. Pure function.
    .DESCRIPTION
        Works per file rather than from ArrMetadata, which only describes the first file:
        a pack can hold several titles, and each needs its own scan. Episodes stay with
        their show because two shows in one job can share an episode number.

        Verified is true only when Radarr/Sonarr history confirmed specific items. Without
        that, the list is what was sent for import, not what landed.

        Runs for every import, after the files have moved, so a failure here must not reach
        the job: it returns nothing instead.
    .PARAMETER ImportableFiles
        Scan files sent for import, each carrying .movie or .series and .episodes.
    .PARAMETER AppType
        'Radarr' or 'Sonarr'.
    .PARAMETER Verification
        Optional result from Get-SAImportVerification (uses its .Records).
    .OUTPUTS
        PSCustomObject[] with RootPath, Title, MediaType, Episodes, Verified.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ImportableFiles,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,

        [Parameter()]
        [AllowNull()]
        [object]$Verification
    )

    try {
    $idField = if ($AppType -eq 'Sonarr') { 'episodeId' } else { 'movieId' }
    $confirmedIds = @{}
    if ($null -ne $Verification) {
        foreach ($record in @($Verification.Records)) {
            if ($null -ne $record -and $null -ne $record.$idField) {
                $confirmedIds["$($record.$idField)"] = $true
            }
        }
    }
    $verified = $confirmedIds.Count -gt 0

    $targets = [ordered]@{}
    foreach ($file in @($ImportableFiles)) {
        if ($null -eq $file) {
            continue
        }

        $media = if ($AppType -eq 'Sonarr') { $file.series } else { $file.movie }
        if ($null -eq $media -or [string]::IsNullOrWhiteSpace($media.path)) {
            continue
        }

        $episodes = @()
        if ($AppType -eq 'Sonarr') {
            foreach ($episode in @($file.episodes)) {
                if ($null -eq $episode -or ($verified -and -not $confirmedIds.ContainsKey("$($episode.id)"))) {
                    continue
                }
                $episodes += [PSCustomObject]@{
                    Season  = [int]$episode.seasonNumber
                    Episode = [int]$episode.episodeNumber
                }
            }
            if ($verified -and $episodes.Count -eq 0) {
                continue
            }
        } elseif ($verified -and -not $confirmedIds.ContainsKey("$($media.id)")) {
            continue
        }

        $key = $media.path.ToLowerInvariant()
        if (-not $targets.Contains($key)) {
            $targets[$key] = [PSCustomObject]@{
                RootPath  = $media.path
                Title     = $media.title
                MediaType = if ($AppType -eq 'Sonarr') { 'tv' } else { 'movie' }
                Episodes  = @()
                Verified  = $verified
            }
        }
        $targets[$key].Episodes += $episodes
    }

    return @($targets.Values)
    } catch {
        Write-SAVerbose -Text "Kodi targets could not be built: $($_.Exception.Message)"
        return @()
    }
}

function Test-SAKodiStepNeeded {
    <#
    .SYNOPSIS
        Decides whether a job should update Kodi. Pure function.
    .DESCRIPTION
        Also true for an import reported as failed for an unknown reason. The usual cause
        is Stagearr's wait timing out on a long copy, and Radarr/Sonarr then finish the
        import regardless. Nothing else would tell Kodi, and a scan is harmless if the file
        never arrived. Medusa results carry no targets.
    .PARAMETER ImportResult
        Result object from Invoke-SAImport.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ImportResult
    )

    if ($null -eq $ImportResult -or $ImportResult.Skipped -eq $true -or $null -eq $ImportResult.KodiTargets) {
        return $false
    }
    if ($ImportResult.Success -eq $true) {
        return ($null -eq $ImportResult.ImportedCount -or $ImportResult.ImportedCount -ne 0)
    }
    return ($ImportResult.ErrorType -eq 'unknown')
}

#endregion

#region JSON-RPC

function Invoke-SAKodiRpc {
    <#
    .SYNOPSIS
        Calls one Kodi JSON-RPC method. Never throws.
    .DESCRIPTION
        Always a single attempt: a retried VideoLibrary.Scan that Kodi did receive would
        cancel the scan it started. The body is pre-serialized because Invoke-SAWebRequest
        only encodes hashtables and objects, and the charset is explicit so titles with
        accents survive on every supported PowerShell version.
    .PARAMETER Config
        Full configuration hashtable.
    .PARAMETER Method
        JSON-RPC method name.
    .PARAMETER Params
        Method parameters.
    .OUTPUTS
        PSCustomObject with Success, Result, Unreachable, Rejected, ErrorMessage.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter()]
        [hashtable]$Params = @{}
    )

    $kodi = $Config.kodi
    $scheme = if ($kodi.ssl -eq $true) { 'https' } else { 'http' }
    $uri = "${scheme}://$($kodi.host):$($kodi.port)/jsonrpc"

    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($kodi.username)) {
        $credential = [Text.Encoding]::UTF8.GetBytes("$($kodi.username):$($kodi.password)")
        $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String($credential)
    }

    $body = @{
        jsonrpc = '2.0'
        id      = 1
        method  = $Method
        params  = $Params
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $response = Invoke-SAWebRequest -Uri $uri -Method POST -Headers $headers -Body $body `
            -ContentType 'application/json; charset=utf-8' -MaxRetries 1 `
            -TimeoutSeconds $script:SAConstants.KodiRequestTimeoutSeconds
    } catch {
        return [PSCustomObject]@{
            Success      = $false
            Result       = $null
            Unreachable  = $true
            Rejected     = $false
            ErrorMessage = $_.Exception.Message
        }
    }

    if (-not $response.Success) {
        $hasStatus = $null -ne $response.StatusCode -and $response.StatusCode -ne 0
        $rejected = $response.StatusCode -in @(401, 403)
        $message = if ($rejected) {
            'Kodi rejected the request: authentication failed'
        } else {
            $response.ErrorMessage
        }
        return [PSCustomObject]@{
            Success      = $false
            Result       = $null
            Unreachable  = -not $hasStatus
            Rejected     = $rejected
            ErrorMessage = $message
        }
    }

    if ($null -ne $response.Data.error) {
        return [PSCustomObject]@{
            Success      = $false
            Result       = $null
            Unreachable  = $false
            Rejected     = $false
            ErrorMessage = "Kodi returned an error: $($response.Data.error.message)"
        }
    }

    return [PSCustomObject]@{
        Success      = $true
        Result       = $response.Data.result
        Unreachable  = $false
        Rejected     = $false
        ErrorMessage = $null
    }
}

#endregion

#region Library Update

# Set when Kodi cannot be reached, so a queue of jobs behind a sleeping host does not pay
# the timeout once each. Lives for the worker run: Reset-SAJobState leaves it alone on
# purpose, and a new worker tries again.
$script:SAKodiUnreachable = $false

function Reset-SAKodiBreaker {
    <#
    .SYNOPSIS
        Clears the unreachable flag.
    #>
    [CmdletBinding()]
    param()

    $script:SAKodiUnreachable = $false
}

function Get-SAKodiBudgetSeconds {
    <#
    .SYNOPSIS
        Time one job may spend on Kodi. Pure function.
    .PARAMETER ItemCount
        Number of movies and episodes in the job.
    .PARAMETER TitleCount
        Number of titles, each of which needs its own scan and clean.
    .OUTPUTS
        Seconds.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ItemCount,

        [Parameter(Mandatory = $true)]
        [int]$TitleCount
    )

    $constants = $script:SAConstants
    $budget = $constants.KodiBudgetBaseSeconds + ($ItemCount * $constants.KodiBudgetPerItemSeconds) +
        (($TitleCount - 1) * $constants.KodiBudgetPerTitleSeconds)
    return [Math]::Min($budget, $constants.KodiBudgetMaxSeconds)
}

function Get-SAKodiElapsedSeconds {
    <#
    .SYNOPSIS
        Whole seconds on a stopwatch. Separate so tests can drive the clock.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Timer
    )

    return [int]$Timer.Elapsed.TotalSeconds
}

function Get-SAKodiScanState {
    <#
    .SYNOPSIS
        Reads whether Kodi is scanning or cleaning.
    .OUTPUTS
        'Idle', 'Busy', 'Unreachable' or 'Error'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $response = Invoke-SAKodiRpc -Config $Config -Method 'XBMC.GetInfoBooleans' -Params @{ booleans = @('Library.IsScanningVideo') }
    if ($response.Unreachable) {
        return 'Unreachable'
    }
    if (-not $response.Success) {
        return 'Error'
    }
    if ($response.Result.'Library.IsScanningVideo' -eq $true) {
        return 'Busy'
    }
    return 'Idle'
}

function Wait-SAKodiIdle {
    <#
    .SYNOPSIS
        Waits for Kodi to stop scanning, within the job's budget.
    .OUTPUTS
        'Idle', 'Busy' (budget ran out), 'Unreachable' or 'Error'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Timer,

        [Parameter(Mandatory = $true)]
        [int]$BudgetSeconds
    )

    while ($true) {
        $state = Get-SAKodiScanState -Config $Config
        if ($state -ne 'Busy' -or (Get-SAKodiElapsedSeconds -Timer $Timer) -ge $BudgetSeconds) {
            return $state
        }
        Start-Sleep -Seconds $script:SAConstants.KodiPollSeconds
    }
}

function Resolve-SAKodiDirectory {
    <#
    .SYNOPSIS
        Finds a title folder in Kodi's own listing of its parent.
    .DESCRIPTION
        Scanning a built string is unsafe: a missing slash or a spelling difference still
        returns OK. Kodi's listing gives the form it will store, and proves the folder
        exists and that Kodi can reach the share.
    .OUTPUTS
        PSCustomObject with Status ('Found', 'Missing', 'NoAnswer', 'Rejected'), Path and
        ErrorMessage.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Leaf
    )

    $response = Invoke-SAKodiRpc -Config $Config -Method 'Files.GetDirectory' -Params @{ directory = $Parent; media = 'files' }
    if ($response.Unreachable) {
        return [PSCustomObject]@{ Status = 'NoAnswer'; Path = $null; ErrorMessage = $response.ErrorMessage }
    }
    if ($response.Rejected) {
        return [PSCustomObject]@{ Status = 'Rejected'; Path = $null; ErrorMessage = $response.ErrorMessage }
    }

    if ($response.Success) {
        foreach ($entry in @($response.Result.files)) {
            if ($null -eq $entry -or $entry.filetype -eq 'file') {
                continue
            }
            $name = ($entry.file.TrimEnd('/', '\') -split '[/\\]')[-1]
            if ($name -ieq $Leaf) {
                return [PSCustomObject]@{ Status = 'Found'; Path = $entry.file.TrimEnd('/', '\') + '/'; ErrorMessage = $null }
            }
        }
    }

    return [PSCustomObject]@{ Status = 'Missing'; Path = $null; ErrorMessage = $null }
}

function Get-SAKodiMissingItems {
    <#
    .SYNOPSIS
        Lists a target's items that are not in the Kodi library.
    .DESCRIPTION
        Without a confirmed episode list there is nothing specific to look for, so a show
        counts as present once it has any episode under its folder.
    .OUTPUTS
        PSCustomObject with Success and Missing (labels).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$KodiPath
    )

    $filter = @{ field = 'path'; operator = 'startswith'; value = $KodiPath }

    if ($Target.MediaType -eq 'movie') {
        $response = Invoke-SAKodiRpc -Config $Config -Method 'VideoLibrary.GetMovies' -Params @{ filter = $filter; limits = @{ end = 1 } }
        if (-not $response.Success) {
            return [PSCustomObject]@{ Success = $false; Missing = @() }
        }
        $missing = if ([int]$response.Result.limits.total -gt 0) { @() } else { @($Target.Title) }
        return [PSCustomObject]@{ Success = $true; Missing = $missing }
    }

    $response = Invoke-SAKodiRpc -Config $Config -Method 'VideoLibrary.GetEpisodes' -Params @{ filter = $filter; properties = @('season', 'episode') }
    if (-not $response.Success) {
        return [PSCustomObject]@{ Success = $false; Missing = @() }
    }

    $present = @{}
    foreach ($episode in @($response.Result.episodes)) {
        if ($null -ne $episode) {
            $present["$($episode.season):$($episode.episode)"] = $true
        }
    }

    $missing = @()
    if (@($Target.Episodes).Count -eq 0) {
        if ($present.Count -eq 0) {
            $missing = @($Target.Title)
        }
    } else {
        foreach ($episode in @($Target.Episodes)) {
            if (-not $present.ContainsKey("$($episode.Season):$($episode.Episode)")) {
                $missing += '{0} S{1:00}E{2:00}' -f $Target.Title, $episode.Season, $episode.Episode
            }
        }
    }

    return [PSCustomObject]@{ Success = $true; Missing = $missing }
}

function Invoke-SAKodiTargetUpdate {
    <#
    .SYNOPSIS
        Scans one title and checks the result.
    .DESCRIPTION
        The library check waits for Kodi to go idle first. On an upgrade the old entry
        already matches the title's folder, so checking earlier would pass before the scan
        has done anything.
    .OUTPUTS
        PSCustomObject with Status ('Updated', 'Missing', 'Skipped', 'Unreachable'),
        Missing and Reason.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter()]
        [AllowNull()]
        [object[]]$PathMap,

        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Timer,

        [Parameter(Mandatory = $true)]
        [int]$BudgetSeconds
    )

    $result = {
        param($Status, $Reason = $null, $Missing = @())
        [PSCustomObject]@{ Status = $Status; Reason = $Reason; Missing = @($Missing) }
    }

    $mapped = ConvertTo-SAKodiPath -ArrPath $Target.RootPath -PathMap $PathMap
    if ($null -eq $mapped) {
        return & $result 'Skipped' 'no kodi.pathMap entry matches its folder'
    }

    # The idle check comes first because it is the cheap call that proves Kodi is up. A
    # listing can time out on a spun-down share while Kodi itself is fine, so a listing
    # that gets no answer must not count as an outage.
    $idleResult = {
        param($State)
        switch ($State) {
            'Unreachable' { return & $result 'Unreachable' 'Kodi is unreachable' }
            'Busy' { return & $result 'Skipped' 'Kodi was still busy when the time limit ran out' }
            'Error' { return & $result 'Skipped' 'Kodi would not report its scan state' }
        }
    }

    $blocked = & $idleResult (Wait-SAKodiIdle -Config $Config -Timer $Timer -BudgetSeconds $BudgetSeconds)
    if ($null -ne $blocked) {
        return $blocked
    }

    $resolved = Resolve-SAKodiDirectory -Config $Config -Parent $mapped.Parent -Leaf $mapped.Leaf
    switch ($resolved.Status) {
        'NoAnswer' { return & $result 'Skipped' 'Kodi did not list its folder in time' }
        'Rejected' { return & $result 'Skipped' $resolved.ErrorMessage }
        'Missing' { return & $result 'Skipped' 'Kodi cannot see its folder (check kodi.pathMap)' }
    }

    # The listing took time, and a scan sent into a running scan cancels both
    $blocked = & $idleResult (Wait-SAKodiIdle -Config $Config -Timer $Timer -BudgetSeconds $BudgetSeconds)
    if ($null -ne $blocked) {
        return $blocked
    }

    if ((Get-SAKodiElapsedSeconds -Timer $Timer) -ge $BudgetSeconds) {
        return & $result 'Skipped' 'the time limit ran out before its scan'
    }

    $scan = Invoke-SAKodiRpc -Config $Config -Method 'VideoLibrary.Scan' -Params @{ directory = $resolved.Path; showdialogs = $false }
    if ($scan.Unreachable) {
        # Kodi may have received it, so neither "scanned" nor "not scanned" is known
        if ((Get-SAKodiScanState -Config $Config) -eq 'Unreachable') {
            return & $result 'Unreachable' 'Kodi is unreachable'
        }
        return & $result 'Missing' 'Kodi did not answer the scan request, so it is not confirmed' @($Target.Title)
    }
    if (-not $scan.Success) {
        return & $result 'Skipped' $scan.ErrorMessage
    }

    Start-Sleep -Seconds $script:SAConstants.KodiPollSeconds
    $state = Wait-SAKodiIdle -Config $Config -Timer $Timer -BudgetSeconds $BudgetSeconds
    if ($state -eq 'Unreachable') {
        return & $result 'Unreachable' 'Kodi is unreachable'
    }
    if ($state -ne 'Idle') {
        # Judging now would pass an upgrade on its old entry, or fail a new title too early
        return & $result 'Missing' 'scan sent, but Kodi was still busy, so it is not confirmed' @($Target.Title)
    }

    $check = Get-SAKodiMissingItems -Config $Config -Target $Target -KodiPath $resolved.Path
    $graceEnd = (Get-SAKodiElapsedSeconds -Timer $Timer) + $script:SAConstants.KodiVerifyGraceSeconds
    while ($check.Success -and @($check.Missing).Count -gt 0 -and (Get-SAKodiElapsedSeconds -Timer $Timer) -lt $graceEnd) {
        Start-Sleep -Seconds $script:SAConstants.KodiPollSeconds
        $check = Get-SAKodiMissingItems -Config $Config -Target $Target -KodiPath $resolved.Path
    }

    if (-not $check.Success) {
        return & $result 'Missing' 'could not be confirmed in Kodi' @($Target.Title)
    }
    if (@($check.Missing).Count -gt 0) {
        $reason = if ($Target.Verified) { 'not found in Kodi after the scan' } else { 'not found in Kodi after the scan, and it may not have imported' }
        return & $result 'Missing' $reason $check.Missing
    }
    return & $result 'Updated'
}

function Invoke-SAKodiStep {
    <#
    .SYNOPSIS
        The pipeline's Kodi step: gates, update and reporting. Never throws.
    .DESCRIPTION
        Everything sits inside one try/catch, gates included, because the import has already
        happened and nothing here may change the job outcome.

        A skip uses Skip level with an Info note: a Warning event turns the email amber, and
        a sleeping HTPC must not do that to every job.
    .PARAMETER Context
        Processing context.
    .PARAMETER JobId
        Job id, for progress reporting.
    .PARAMETER ImportResult
        Result object from Invoke-SAImport.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [Parameter()]
        [AllowNull()]
        [object]$ImportResult
    )

    try {
        if (-not (Test-SAFeatureEnabled -Feature 'Kodi' -Config $Context.Config) -or -not (Test-SAKodiStepNeeded -ImportResult $ImportResult)) {
            return
        }

        Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $JobId -Phase 'Import' -Activity 'Updating Kodi...'
        Write-SAProgress -Label 'Kodi' -Text 'Scanning...' -Indent 1 -ConsoleOnly
        $kodiResult = Invoke-SAKodiUpdate -Config $Context.Config -Targets $ImportResult.KodiTargets

        switch ($kodiResult.Status) {
            'Updated' {
                Write-SAOutcome -Level Success -Label 'Kodi' -Text $kodiResult.Text -Duration $kodiResult.Duration -Indent 1 -EmailInclude
            }
            'Partial' {
                Write-SAOutcome -Level Warning -Label 'Kodi' -Text 'Not everything reached Kodi' -Duration $kodiResult.Duration -Indent 1
                Add-SAEmailException -Message "Kodi: $($kodiResult.Text)" -Type Warning
            }
            default {
                Write-SAOutcome -Level Skip -Label 'Kodi' -Text 'Not scanned' -Indent 1
                Add-SAEmailException -Message "Kodi: $($kodiResult.Text)" -Type Info
            }
        }
    } catch {
        Write-SAVerbose -Text "Kodi step failed: $($_.Exception.Message)"
        Write-SAOutcome -Level Skip -Label 'Kodi' -Text 'Not scanned' -Indent 1
        Add-SAEmailException -Message 'Kodi: update failed, so the title stays out of Kodi until a scan runs' -Type Info
    }
}

function Invoke-SAKodiUpdate {
    <#
    .SYNOPSIS
        Updates Kodi for every title in a job. Never throws.
    .PARAMETER Config
        Full configuration hashtable.
    .PARAMETER Targets
        Titles from Get-SAKodiTargets.
    .OUTPUTS
        PSCustomObject with Status ('Updated', 'Partial', 'Skipped'), Text, Missing, Duration.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter()]
        [AllowNull()]
        [object[]]$Targets
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $finish = {
        param($Status, $Text, $Missing = @())
        [PSCustomObject]@{
            Status   = $Status
            Text     = $Text
            Missing  = @($Missing)
            Duration = [int]$timer.Elapsed.TotalSeconds
        }
    }
    $stillNeeded = 'it stays out of Kodi until a scan runs'

    $targetList = @($Targets | Where-Object { $null -ne $_ })
    if ($targetList.Count -eq 0) {
        return & $finish 'Skipped' 'Nothing to scan'
    }
    if ($script:SAKodiUnreachable) {
        return & $finish 'Skipped' "Kodi was unreachable earlier in this run, so $stillNeeded"
    }

    $problems = @(Test-SAKodiConfig -Config $Config)
    if ($problems.Count -gt 0) {
        return & $finish 'Skipped' "$($problems -join '; '), so $stillNeeded"
    }

    try {
        $pathMap = Get-SAKodiPathMap -PathMap $Config.kodi.pathMap
        $itemCount = 0
        foreach ($target in $targetList) {
            $itemCount += [Math]::Max(1, @($target.Episodes).Count)
        }
        $budget = Get-SAKodiBudgetSeconds -ItemCount $itemCount -TitleCount $targetList.Count

        $updated = 0
        $missing = @()
        $notes = @()
        foreach ($target in $targetList) {
            $outcome = Invoke-SAKodiTargetUpdate -Config $Config -Target $target -PathMap $pathMap -Timer $timer -BudgetSeconds $budget
            switch ($outcome.Status) {
                'Updated' { $updated++ }
                'Missing' {
                    $missing += $outcome.Missing
                    $note = "$($target.Title): $($outcome.Reason)"
                    if ($outcome.Missing -notcontains $target.Title) {
                        $note += " ($($outcome.Missing -join ', '))"
                    }
                    $notes += $note
                }
                'Unreachable' {
                    $script:SAKodiUnreachable = $true
                    $notes += "$($target.Title): $($outcome.Reason), so $stillNeeded"
                }
                default { $notes += "$($target.Title): $($outcome.Reason), so $stillNeeded" }
            }
            if ($script:SAKodiUnreachable) {
                $position = [array]::IndexOf($targetList, $target)
                foreach ($remaining in @($targetList | Select-Object -Skip ($position + 1))) {
                    $notes += "$($remaining.Title): not attempted, so $stillNeeded"
                }
                break
            }
        }

        if ($notes.Count -eq 0) {
            $text = if ($updated -eq 1) { 'Scanned and confirmed' } else { "Scanned and confirmed $updated titles" }
            return & $finish 'Updated' $text
        }
        $status = if ($updated -gt 0 -or $missing.Count -gt 0) { 'Partial' } else { 'Skipped' }
        return & $finish $status ($notes -join '; ') $missing
    } catch {
        return & $finish 'Skipped' "Kodi update failed ($($_.Exception.Message)), so $stillNeeded"
    }
}

#endregion
