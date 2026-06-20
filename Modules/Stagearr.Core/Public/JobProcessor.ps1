#Requires -Version 5.1
<#
.SYNOPSIS
    Job processing orchestration for Stagearr.
.DESCRIPTION
    Contains the main job processing logic that orchestrates video processing,
    subtitle handling, media server import, logging, and notifications.
    
    Uses the event-based output system from Phase 1 for consistent output
    across console, file logs, and email.
    
    SOLID Refactor (Phase 6): Extracted pure helper functions for testability.
#>

#region Pure Helper Functions (SOLID Refactor - Phase 6)

function Get-SASubtitleLanguagesFromResult {
    <#
    .SYNOPSIS
        Extracts unique language names from subtitle processing result.
    .DESCRIPTION
        Pure function - no I/O. Analyzes subtitle file paths to extract
        language codes and convert them to human-readable names.
    .PARAMETER SubtitleFiles
        Array of subtitle file paths.
    .OUTPUTS
        Array of unique language name strings.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter()]
        [AllowNull()]
        [array]$SubtitleFiles
    )
    
    if (-not $SubtitleFiles -or $SubtitleFiles.Count -eq 0) {
        return @()
    }
    
    $langs = $SubtitleFiles | ForEach-Object {
        if ($_ -match '\.([a-z]{2})\.srt$') {
            $langName = ConvertTo-SALanguageCode -Code $Matches[1] -To 'name'
            if ($langName) { $langName } else { $Matches[1].ToUpper() }
        }
    } | Where-Object { $_ } | Select-Object -Unique | Sort-Object
    
    return @($langs)
}

function Get-SAMissingLanguageNames {
    <#
    .SYNOPSIS
        Converts missing language codes to human-readable names.
    .DESCRIPTION
        Pure function - no I/O. Takes array of language codes and returns
        array of human-readable language names.
    .PARAMETER MissingLanguages
        Array of ISO language codes.
    .OUTPUTS
        Array of language name strings.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter()]
        [AllowNull()]
        [array]$MissingLanguages
    )
    
    if (-not $MissingLanguages -or $MissingLanguages.Count -eq 0) {
        return @()
    }
    
    $names = $MissingLanguages | ForEach-Object {
        $langName = ConvertTo-SALanguageCode -Code $_ -To 'name'
        if ($langName) { $langName } else { $_.ToUpper() }
    } | Sort-Object
    
    return @($names)
}

function Get-SAImportTargetName {
    <#
    .SYNOPSIS
        Determines the import target name based on label and config.
    .DESCRIPTION
        Pure function - no I/O. Returns the appropriate importer name
        (Radarr, Sonarr, Medusa) for display in emails.
    .PARAMETER Label
        Download label.
    .PARAMETER Config
        Configuration hashtable.
    .OUTPUTS
        String name of the import target.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $labelType = Get-SALabelType -Label $Label -Config $Config
    
    switch ($labelType) {
        'tv' {
            if ($Config.processing.tvImporter -eq 'Medusa') { 'Medusa' } else { 'Sonarr' }
        }
        'movie' { 'Radarr' }
        default { '' }
    }
}

function Get-SAImportResultText {
    <#
    .SYNOPSIS
        Gets human-readable text for import result.
    .DESCRIPTION
        Pure function - no I/O. Converts import result object to
        display text for email.
    .PARAMETER ImportResult
        Import result object.
    .OUTPUTS
        String describing the import result.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ImportResult
    )
    
    if ($null -eq $ImportResult) {
        return ''
    }

    if ($ImportResult.TbaRetryScheduled -eq $true) {
        return 'Pending retry'
    }

    if ($ImportResult.QualityRejected -eq $true) {
        return 'Skipped (quality exists)'
    } elseif ($ImportResult.Skipped -eq $true) {
        # Use specific skip reason if available
        $reason = if ($ImportResult.Message -match 'quality') {
            'quality exists'
        } elseif ($ImportResult.Message -match 'same size') {
            'same size'
        } else {
            'exists'
        }
        return "Skipped ($reason)"
    } elseif ($ImportResult.Success -eq $true) {
        # Check for partial import
        if ($ImportResult.Status -eq 'partial') {
            $imported = if ($ImportResult.ImportedCount) { $ImportResult.ImportedCount } else { 0 }
            $fileWord = if ($imported -eq 1) { 'file' } else { 'files' }
            return "Imported $imported $fileWord"
        }
        return 'Imported to library'
    } else {
        return 'Failed'
    }
}

function Get-SAEmailResultLevel {
    <#
    .SYNOPSIS
        Determines email result level from job outcome.
    .DESCRIPTION
        Pure function - no I/O. Analyzes job results to determine
        appropriate email result level (Success/Warning/Failed).
    .PARAMETER JobSuccess
        Whether the overall job succeeded.
    .PARAMETER ImportResult
        Import result object.
    .PARAMETER MissingLanguages
        Array of missing language codes.
    .OUTPUTS
        String result level for email.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$JobSuccess,
        
        [Parameter()]
        [AllowNull()]
        [object]$ImportResult,
        
        [Parameter()]
        [AllowNull()]
        [array]$MissingLanguages
    )
    
    if (-not $JobSuccess) {
        return 'Failed'
    }
    
    if ($null -ne $ImportResult) {
        # Partial import with aborts = Warning (something unexpected happened)
        if ($ImportResult.Status -eq 'partial' -and $ImportResult.AbortedCount -gt 0) {
            return 'Warning'
        }
        
        if ($ImportResult.QualityRejected -eq $true -or $ImportResult.Skipped -eq $true) {
            # Still show as Success in email body (skips are expected)
            return 'Success'
        }
    }
    
    if ($MissingLanguages -and $MissingLanguages.Count -gt 0) {
        return 'Warning'
    }
    
    return 'Success'
}

function Format-SAImportEpisodeNote {
    <#
    .SYNOPSIS
        Formats import file details for email Notes section.
    .DESCRIPTION
        Pure function - no I/O. Formats imported/skipped/aborted file details
        into a human-readable email note with episode identifiers when available.
        
        Uses Format-SAEpisodeOutcome for consistent formatting with console output.
        Falls back to count-based display when episode info is unavailable.
    .PARAMETER Files
        Array of file detail objects from ImportedFiles, SkippedFiles, or AbortedFiles.
        Each object may have: Filename, Season, Episode, Reason.
    .PARAMETER Action
        The action: 'Imported', 'Skipped', or 'Aborted'.
    .PARAMETER Reason
        Optional reason text (overrides per-file reasons if provided).
    .OUTPUTS
        Formatted string like "Imported S02E08" or "Skipped S02E01-E06: Quality exists".
        Returns empty string if Files is null or empty.
    .EXAMPLE
        Format-SAImportEpisodeNote -Files $result.ImportedFiles -Action 'Imported'
        # Returns: "Imported S02E08" (single episode)
    .EXAMPLE
        Format-SAImportEpisodeNote -Files $result.SkippedFiles -Action 'Skipped'
        # Returns: "Skipped S02E01-E06: Quality exists" (multiple episodes with reason)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$Files,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Imported', 'Skipped', 'Aborted')]
        [string]$Action,
        
        [Parameter()]
        [string]$Reason = ''
    )
    
    # Handle null/empty files
    if ($null -eq $Files -or $Files.Count -eq 0) {
        return ''
    }
    
    # Extract season from first file with season info
    $season = $null
    foreach ($file in $Files) {
        if ($null -ne $file -and $null -ne $file.Season -and $file.Season -gt 0) {
            $season = $file.Season
            break
        }
    }
    
    # Extract episodes that have valid episode numbers
    $episodes = @($Files | Where-Object { $null -ne $_.Episode } | ForEach-Object { $_.Episode })
    
    # Get reason from files if not provided
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        foreach ($file in $Files) {
            if ($null -ne $file -and -not [string]::IsNullOrWhiteSpace($file.Reason)) {
                $Reason = $file.Reason
                break
            }
        }
    }
    
    # Use episode formatting if we have valid season and episode data
    if ($season -and $season -gt 0 -and $episodes.Count -gt 0) {
        # Use Format-SAEpisodeOutcome for consistent formatting with console
        return Format-SAEpisodeOutcome -Season $season -Episodes $episodes -Action $Action -Reason $Reason
    }
    
    # Fallback to count-based display (no episode info available)
    $count = $Files.Count
    $fileWord = Get-SAPluralForm -Count $count -Singular 'file'
    $text = "$Action $count $fileWord"
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $text = "$text`: $Reason"
    }
    
    return $text
}

#endregion

function Test-SATbaRetryNeeded {
    <#
    .SYNOPSIS
        Determines if a TBA auto-retry should be scheduled.
    .PARAMETER ImportResult
        Import result object from Invoke-SAImport.
    .PARAMETER Job
        Current job hashtable.
    .OUTPUTS
        Boolean. True if a retry should be scheduled.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ImportResult,

        [Parameter(Mandatory = $true)]
        [hashtable]$Job
    )

    if ($null -eq $ImportResult) { return $false }
    if ($ImportResult.Skipped -ne $true) { return $false }
    if ($ImportResult.ErrorType -ne 'tba') { return $false }
    if ($Job.input.tbaRetry -eq $true) { return $false }

    return $true
}

function Test-SATbaRetryMode {
    <#
    .SYNOPSIS
        Determines how a TBA retry job should be processed.
    .DESCRIPTION
        Checks whether staged files still exist for import-only mode,
        or whether the original download is available for full pipeline fallback.
    .PARAMETER Job
        Job hashtable with input.tbaRetry, input.stagingPath, input.downloadPath.
    .OUTPUTS
        PSCustomObject with Mode (ImportOnly/FullPipeline/Failed) and StagingPath,
        or $null if not a retry job.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Job
    )

    if ($Job.input.tbaRetry -ne $true) { return $null }

    $stagingExists = (-not [string]::IsNullOrWhiteSpace($Job.input.stagingPath)) -and
                     (Test-Path -LiteralPath $Job.input.stagingPath)

    if ($stagingExists) {
        return [PSCustomObject]@{
            Mode        = 'ImportOnly'
            StagingPath = $Job.input.stagingPath
        }
    }

    $downloadExists = (-not [string]::IsNullOrWhiteSpace($Job.input.downloadPath)) -and
                      (Test-Path -LiteralPath $Job.input.downloadPath)

    if ($downloadExists) {
        return [PSCustomObject]@{
            Mode        = 'FullPipeline'
            StagingPath = $null
        }
    }

    return [PSCustomObject]@{
        Mode        = 'Failed'
        StagingPath = $null
    }
}

function Add-SATbaRetryEmailExceptions {
    <#
    .SYNOPSIS
        Adds email exceptions for TBA retry scenarios.
    .PARAMETER ImportResult
        Import result object.
    .PARAMETER RetryAfter
        Scheduled retry datetime (for scenario A).
    .PARAMETER ImportTarget
        Importer name (Sonarr/Radarr).
    .PARAMETER IsTbaRetry
        Whether the current job is a TBA retry.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ImportResult,

        [Parameter()]
        [AllowNull()]
        [object]$RetryAfter,

        [Parameter()]
        [string]$ImportTarget,

        [Parameter()]
        [bool]$IsTbaRetry
    )

    # Scenario A: Original run, retry scheduled
    if (-not $IsTbaRetry -and $ImportResult.TbaRetryScheduled -eq $true -and $null -ne $RetryAfter) {
        Add-SAEmailException -Message "${ImportTarget}: Episode title is still TBA after metadata refresh" -Type Info
        $retryDateStr = $RetryAfter.ToString('yyyy-MM-dd HH:mm')
        Add-SAEmailException -Message "Automatic retry scheduled; will import on the next processing run after $retryDateStr" -Type Info
        return
    }

    # Scenario B: Retry succeeded
    if ($IsTbaRetry -and $ImportResult.Success -eq $true -and $ImportResult.Skipped -ne $true) {
        Add-SAEmailException -Message "This import was automatically retried after a TBA skip" -Type Info
        return
    }

    # Scenario C: Retry failed or skipped again
    if ($IsTbaRetry -and ($ImportResult.Success -ne $true -or $ImportResult.Skipped -eq $true)) {
        $reason = if ($ImportResult.Message) { $ImportResult.Message } else { 'unknown' }
        Add-SAEmailException -Message "Automatic TBA retry failed: $reason" -Type Warning
        Add-SAEmailException -Message "Use -Rerun to retry manually" -Type Warning
        return
    }
}

#region Main Job Processing

function Invoke-SAJobProcessing {
    <#
    .SYNOPSIS
        Processes a single torrent job through the complete pipeline.
    .DESCRIPTION
        Orchestrates the full processing workflow for a torrent job:
        - Determines label type (TV/Movie/Passthrough)
        - Runs video processing (RAR extraction, remux, subtitle strip/extract)
        - Handles subtitle acquisition and cleanup
        - Imports to media server (Radarr/Sonarr/Medusa)
        - Generates plain-text log and sends email notification
    .PARAMETER Context
        The processing context object created by New-SAContext and initialized with Initialize-SAContext.
    .PARAMETER Job
        The job object from the queue containing input parameters and state.
    .OUTPUTS
        [bool] Returns $true if processing succeeded, $false otherwise.
    .EXAMPLE
        $result = Invoke-SAJobProcessing -Context $context -Job $pendingJob
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Job
    )
    
    $displayName = Split-Path $Job.input.downloadPath -Leaf
    
    # Initialize event-based output system with log folder
    Initialize-SAOutputSystem -Name $displayName `
        -Label $Job.input.downloadLabel `
        -SourcePath $Job.input.downloadPath `
        -StagingPath $Context.State.StagingPath `
        -LogFolder $Context.Paths.LogArchive `
        -TorrentHash $Job.input.torrentHash `
        -VerboseMode:$Context.Flags.VerboseMode
    
    # Configure file log with exact path and tool versions
    $logPath = Get-SAContextLogPath -Context $Context
    $toolVersions = Get-SAToolVersionsForLog -Context $Context
    Set-SAFileLogConfig -LogPath $logPath -ToolVersions $toolVersions
    
    # Reset import module state (clears hostname resolution cache)
    Reset-SAImportState
    
    # Determine label type (tv/movie/passthrough)
    $labelType = Get-SALabelType -Label $Context.State.ProcessingLabel -Config $Context.Config
    
    if ($labelType -eq 'passthrough') {
        return Invoke-SAPassthroughJob -Context $Context -Job $Job
    }
    
    # Standard processing (TV/Movie)
    return Invoke-SAStandardJob -Context $Context -Job $Job
}

function Invoke-SAPassthroughJob {
    <#
    .SYNOPSIS
        Processes a passthrough job (unknown label - copy only).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Job
    )
    
    # Passthrough mode: just extract/copy, no processing
    Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Staging' -Activity 'Passthrough processing...'
    $passthroughResult = Invoke-SAPassthroughProcessing -Context $Context
    $passthroughSuccess = $passthroughResult.Success -eq $true
    
    if ($passthroughSuccess) {
        # L1 fix: Style Import line as outcome with skip marker
        Write-SAOutcome -Level Skip -Label "Import" -Text "Passthrough mode (no import configured)" -Indent 1
        
        # M2 fix: Move staging path to verbose (user doesn't need to know internal path)
        Write-SAVerbose -Text "Staging path: $($Context.State.StagingPath)"
    } else {
        Write-SAOutcome -Level Error -Label "Passthrough" -Text "Processing failed" -Indent 1
        
        # Cleanup staging on failure (no usable content)
        if (-not $Context.Flags.NoCleanup) {
            Remove-SAStagingFolder -Context $Context
        }
    }
    
    # Finalize outputs and send notification
    Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Finalize' -Activity 'Cleaning up...'
    $displayName = Split-Path $Job.input.downloadPath -Leaf
    
    # Passthrough: Use original name as-is (not media, no parsing needed)
    $friendlyName = $displayName
    
    $duration = Get-SAContextDuration -Context $Context
    
    # Calculate video stats for passthrough
    $videoCount = 0
    $videoSize = ''
    if ($passthroughResult.CopiedFiles -and $passthroughResult.CopiedFiles.Count -gt 0) {
        $videoCount = $passthroughResult.CopiedFiles.Count
        $totalSize = 0
        foreach ($cf in $passthroughResult.CopiedFiles) {
            if ($cf.Size) { $totalSize += $cf.Size }
        }
        if ($totalSize -gt 0) {
            $videoSize = Format-SASize $totalSize
        }
    }
    
    # Set email summary data with passthrough flag (M3 fix)
    # Note: No SourceName for passthrough - Name IS the original name
    $emailParams = @{
        Name        = $friendlyName
        Label       = $Job.input.downloadLabel
        Result      = $(if ($passthroughSuccess) { 'Success' } else { 'Failed' })
        Duration    = $duration.ToString('mm\:ss')
        IsPassthrough = $true
        VideoCount  = $videoCount
        VideoSize   = $videoSize
    }
    
    # Add failure details for failed jobs
    if (-not $passthroughSuccess) {
        $emailParams.FailurePhase = 'Staging'
        if ($passthroughResult.Reason) {
            $emailParams.FailureError = $passthroughResult.Reason
        }
        if ($passthroughResult.FailedPath) {
            $emailParams.FailurePath = $passthroughResult.FailedPath
        }
    }
    
    Set-SAEmailSummary @emailParams
    
    if (-not $passthroughSuccess -and $passthroughResult.Reason) {
        Add-SAEmailException -Message $passthroughResult.Reason -Type Error
    }
    
    # Save file log and set path in email
    $logPath = Get-SAContextLogPath -Context $Context
    Save-SAFileLog -Path $logPath
    Set-SAEmailLogPath -Path $logPath
    
    Write-SAProgress -Label "Log" -Text $logPath -Indent 1 -ConsoleOnly
    
    # Send email notification
    if (-not $Context.Flags.NoMail -and $Context.Config.notifications.email.enabled) {
        $title = "$($Job.input.downloadLabel) - $displayName"
        $emailBody = ConvertTo-SAEmailHtml -Title $title
        $emailSubject = Get-SAEmailSubject -Result $(if ($passthroughSuccess) { 'Success' } else { 'Failed' })
        
        Send-SAEmail -Config $Context.Config.notifications.email `
            -Subject $emailSubject `
            -Body $emailBody
    }
    
    return $passthroughSuccess
}

function Invoke-SAStandardJob {
    <#
    .SYNOPSIS
        Processes a standard TV/Movie job.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Job
    )
    
    $displayName = Split-Path $Job.input.downloadPath -Leaf
    
    # Parse release info early and store for later use
    # This provides verbose output right after the log header (before first phase)
    $releaseInfo = Get-SAReleaseInfo -FileName $displayName -Config $Context.Config
    $releaseInfo = Add-SAReleaseDisplayInfo -ReleaseInfo $releaseInfo
    $Context.State.ReleaseInfo = $releaseInfo
    
    # Verbose: Log enriched quality info (only if there's something to show beyond raw parsing)
    if ($releaseInfo -and ($releaseInfo.Source -or $releaseInfo.HdrDisplay)) {
        $qualityParts = @()
        if ($releaseInfo.Source) { $qualityParts += "source=$($releaseInfo.Source)" }
        if ($releaseInfo.HdrDisplay) { $qualityParts += "hdr=$($releaseInfo.HdrDisplay)" }
        Write-SAVerbose -Text "Quality: $($qualityParts -join ', ')"
    }

    # Early *arr queue lookup - get IMDB ID and metadata before OMDb query
    # This avoids OMDb title-based ambiguity (e.g., anime vs live-action "One Piece")
    # and caches queue records for reuse during import (no duplicate API call)
    $labelType = Get-SALabelType -Label $Job.input.downloadLabel -Config $Context.Config
    $omdbType = if ($labelType -eq 'tv') { 'series' } else { 'movie' }

    # Determine *arr app type and config (used by queue lookup and safety check)
    $arrAppType = if ($labelType -eq 'tv') { 'Sonarr' } else { 'Radarr' }
    $arrConfig = $Context.Config.importers.($arrAppType.ToLower())

    if (-not [string]::IsNullOrWhiteSpace($Job.input.torrentHash) -and $null -ne $arrConfig -and $arrConfig.enabled) {
        try {
            # Try queue first (active downloads), then history (completed downloads)
            $mediaObj = $null
            $mediaSource = $null

            $queueRecords = Get-SAArrQueueRecords -AppType $arrAppType -Config $arrConfig `
                -DownloadId $Job.input.torrentHash

            if ($queueRecords -and $queueRecords.Count -gt 0) {
                # Cache for reuse during import (avoids duplicate API call)
                $Context.State.EarlyQueueRecords = $queueRecords
                $mediaObj = if ($arrAppType -eq 'Sonarr') { $queueRecords[0].series } else { $queueRecords[0].movie }
                $mediaSource = 'queue'
            } else {
                # Queue empty (torrent finished) -- fall back to history API
                $historyRecords = Get-SAArrHistoryRecords -AppType $arrAppType -Config $arrConfig `
                    -DownloadId $Job.input.torrentHash
                $mediaSource = 'history'

                if ($null -ne $historyRecords -and @($historyRecords).Count -gt 0) {
                    # Extract media object for metadata (IMDB, title, year)
                    $mediaObj = if ($arrAppType -eq 'Sonarr') { $historyRecords[0].series } else { $historyRecords[0].movie }

                    # Cache full records for enrichment (has series + episode data)
                    $Context.State.EarlyQueueRecords = @($historyRecords)
                }
            }

            # Extract metadata from series/movie object
            if ($null -ne $mediaObj) {
                if ($mediaObj.id) {
                    $Context.State.ArrMediaId = $mediaObj.id
                }
                if (-not [string]::IsNullOrWhiteSpace($mediaObj.imdbId)) {
                    $Context.State.ArrImdbId = $mediaObj.imdbId
                }
                if (-not [string]::IsNullOrWhiteSpace($mediaObj.title)) {
                    $Context.State.ArrTitle = $mediaObj.title
                }
                if ($mediaObj.year -gt 0) {
                    $Context.State.ArrYear = [string]$mediaObj.year
                }

                $arrDesc = @()
                if ($Context.State.ArrTitle) { $arrDesc += "`"$($Context.State.ArrTitle)`"" }
                if ($Context.State.ArrYear) { $arrDesc += "($($Context.State.ArrYear))" }
                if ($Context.State.ArrImdbId) { $arrDesc += "[$($Context.State.ArrImdbId)]" }
                Write-SAVerbose -Text "$arrAppType ${mediaSource}: $($arrDesc -join ' ')"
            }
        } catch {
            Write-SAVerbose -Text "$arrAppType lookup failed: $($_.Exception.Message)"
        }
    }

    # Safety check: Detect dangerous files (exe/scripts) in TV/Movie downloads
    # Passthrough jobs are unaffected (handled by Invoke-SAPassthroughJob)
    $dangerCheck = Test-SADangerousDownload -SourcePath $Job.input.downloadPath
    if ($dangerCheck.IsDangerous) {
        Write-SAPhaseHeader -Title "Safety Check"
        $fileList = $dangerCheck.DangerousFiles -join ', '
        Write-SAOutcome -Level Error -Label "Security" -Text "Dangerous files detected: $fileList" -Indent 1

        # Attempt to blocklist in *arr and remove from download client
        $blocklisted = $false
        if ($Context.State.EarlyQueueRecords -and $Context.State.EarlyQueueRecords.Count -gt 0) {
            $queueId = $Context.State.EarlyQueueRecords[0].id
            Write-SAVerbose -Text "Blocklisting queue item $queueId in $arrAppType"

            $removeResult = Remove-SAArrQueueItem -Config $arrConfig -QueueId $queueId `
                -Reason "Dangerous files detected: $fileList"

            if ($removeResult.Success) {
                Write-SAOutcome -Level Success -Label "Blocklist" -Text "Removed from $arrAppType and download client" -Indent 1
                $blocklisted = $true
            } else {
                Write-SAOutcome -Level Warning -Label "Blocklist" -Text "Failed: $($removeResult.ErrorMessage)" -Indent 1
            }
        } else {
            Write-SAOutcome -Level Warning -Label "Blocklist" -Text "No queue record available - manual cleanup required" -Indent 1
        }

        # Set up email notification for the security block
        Set-SAEmailSummary -Name $displayName `
            -Result 'Blocked' `
            -ImportTarget $arrAppType `
            -FailurePhase 'Security' `
            -FailureError "Dangerous files detected (probable malware): $fileList" `
            -FailurePath $Job.input.downloadPath

        $securityMsg = "Dangerous files detected (probable malware): $fileList"
        if ($blocklisted) {
            $securityMsg += " - blocklisted in $arrAppType"
        }
        Add-SAEmailException -Message $securityMsg -Type Error

        # Save log and send notification
        $logPath = Get-SAContextLogPath -Context $Context
        Save-SAFileLog -Path $logPath
        Set-SAEmailLogPath -Path $logPath
        Write-SAProgress -Label "Log" -Text $logPath -Indent 1 -ConsoleOnly

        if (-not $Context.Flags.NoMail -and $Context.Config.notifications.email.enabled) {
            $title = "$($Job.input.downloadLabel) - $displayName"
            $emailBody = ConvertTo-SAEmailHtml -Title $title
            $emailSubject = Get-SAEmailSubject -Result 'Blocked'
            Send-SAEmail -Config $Context.Config.notifications.email `
                -Subject $emailSubject `
                -Body $emailBody
        }

        return $false
    }

    # TBA retry mode: determine processing strategy
    $tbaRetryMode = Test-SATbaRetryMode -Job $Job
    if ($null -ne $tbaRetryMode) {
        if ($tbaRetryMode.Mode -eq 'Failed') {
            Write-SAPhaseHeader -Title "Import (TBA retry)"
            Write-SAOutcome -Level Error -Label "Retry" -Text "Staged files and original download no longer exist" -Indent 1
            Add-SAEmailException -Message "TBA retry failed: staged files and original download no longer exist" -Type Error

            Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Finalize' -Activity 'Cleaning up...'
            Write-SAPhaseHeader -Title "Finalize"

            $logPath = Get-SAContextLogPath -Context $Context
            Save-SAFileLog -Path $logPath
            Set-SAEmailLogPath -Path $logPath
            Write-SAProgress -Label "Log" -Text $logPath -Indent 1 -ConsoleOnly

            if (-not $Context.Flags.NoMail -and $Context.Config.notifications.email.enabled) {
                $earlyFriendlyName = if ($releaseInfo -and $releaseInfo.FriendlyName) { $releaseInfo.FriendlyName } else { $displayName }
                Set-SAEmailSummary -Name $earlyFriendlyName -SourceName $displayName `
                    -Label $Job.input.downloadLabel -Result 'Failed' `
                    -Duration '00:00' -FailurePhase 'Import' `
                    -FailureError 'TBA retry failed: source files no longer available'
                Add-SAEmailException -Message "Use -Rerun to retry manually if files become available" -Type Warning

                $title = "$($Job.input.downloadLabel) - $displayName"
                $emailBody = ConvertTo-SAEmailHtml -Title $title
                $emailSubject = Get-SAEmailSubject -Result 'Failed'
                Send-SAEmail -Config $Context.Config.notifications.email `
                    -Subject $emailSubject -Body $emailBody
            }

            return $false
        }

        if ($tbaRetryMode.Mode -eq 'ImportOnly') {
            $Context.State.StagingPath = $tbaRetryMode.StagingPath
            Write-SAVerbose -Text "TBA retry: using existing staged files at $($tbaRetryMode.StagingPath)"
        } elseif ($tbaRetryMode.Mode -eq 'FullPipeline') {
            Write-SAVerbose -Text "TBA retry: staged files gone, falling back to full pipeline"
        }
    }

    # Query OMDb - uses *arr IMDB ID for exact lookup, or falls back to title search
    if (Test-SAFeatureEnabled -Feature 'omdb' -Config $Context.Config) {
        $omdbParams = @{
            Config = $Context.Config.omdb
            Type   = $omdbType
        }
        if ($Context.State.ArrImdbId) {
            # Tier 1: Exact IMDB ID lookup (most reliable)
            $omdbParams.ImdbId = $Context.State.ArrImdbId
        } else {
            # Tier 2/3: Title search - prefer *arr title/year over filename-parsed
            $omdbTitle = if ($Context.State.ArrTitle) { $Context.State.ArrTitle } else { if ($releaseInfo) { $releaseInfo.Title } }
            $omdbYear = if ($Context.State.ArrYear) { $Context.State.ArrYear } else { if ($releaseInfo) { $releaseInfo.Year } }
            if (-not [string]::IsNullOrWhiteSpace($omdbTitle)) {
                $omdbParams.Title = $omdbTitle
                $omdbParams.Year = $omdbYear
            }
        }
        if ($omdbParams.ImdbId -or $omdbParams.Title) {
            $Context.State.OmdbData = Get-SAOmdbMetadata @omdbParams
        }
    }

    # Step 1: Video processing (RAR/remux/strip/extract)
    # Step 2: Subtitle processing (external + OpenSubtitles + cleanup)
    $subResult = $null
    $importResult = $null

    $skipProcessing = ($null -ne $tbaRetryMode -and $tbaRetryMode.Mode -eq 'ImportOnly')

    if ($skipProcessing) {
        $videoResult = [PSCustomObject]@{ Success = $true; ProcessedFiles = @(); TotalSize = 0 }
        Write-SAVerbose -Text "TBA retry: skipping video and subtitle processing"
    } else {
        if (Test-SALockStolen) {
            Write-SAOutcome -Level Error -Label "Lock" -Text "Global lock lost to another worker, aborting job"
            return $false
        }
        Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Staging' -Activity 'Processing video files...'
        $videoResult = Invoke-SAVideoProcessing -Context $Context

        if (-not $videoResult.Success) {
            Write-SAOutcome -Level Error -Label "Staging" -Text "Processing failed" -Indent 1
        }
    }

    if ($videoResult.Success -and -not $skipProcessing) {
        $stagingVideos = Get-ChildItem -LiteralPath $Context.State.StagingPath -Filter '*.mkv' -File -ErrorAction SilentlyContinue

        if ($stagingVideos -and $stagingVideos.Count -gt 0) {
            $subParams = @{
                Context        = $Context
                ProcessedFiles = $videoResult.ProcessedFiles
                SourcePath     = $Job.input.downloadPath
            }

            if (Test-SALockStolen) {
                Write-SAOutcome -Level Error -Label "Lock" -Text "Global lock lost to another worker, aborting job"
                return $false
            }
            Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Subtitles' -Activity 'Processing subtitles...'
            $subResult = Invoke-SASubtitleProcessing @subParams
        }
    }

    # Step 3: Import to media server (Radarr/Sonarr/Medusa)
    if ($videoResult.Success) {
        if ($null -ne $tbaRetryMode) {
            Write-SAVerbose -Text "TBA retry: proceeding to import"
        }
        if (Test-SALockStolen) {
            Write-SAOutcome -Level Error -Label "Lock" -Text "Global lock lost to another worker, aborting job"
            return $false
        }
        Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Import' -Activity 'Importing to media server...'
        $importResult = Invoke-SAImport -Context $Context
    }
    
    # Determine if import was successful
    $importSuccess = $false
    if ($videoResult.Success -and $null -ne $importResult) {
        if ($importResult.Skipped -eq $true) {
            $importSuccess = $true  # Skipped is OK (unknown label)
        } elseif ($importResult.Success -eq $true) {
            $importSuccess = $true
        }
    }

    # MDBList collection sync (best-effort, non-fatal) - mark the imported item as
    # "collected" / In Library. Only on a genuine import (not a skip), and only when
    # enabled. A failure here never changes the job outcome.
    if ($null -ne $importResult -and $importResult.Success -eq $true -and $importResult.Skipped -ne $true `
            -and (Test-SAFeatureEnabled -Feature 'MDBList' -Config $Context.Config)) {
        $mdbMediaType = if ($labelType -eq 'tv') { 'tv' } else { 'movie' }
        Write-SAProgress -Label 'MDBList' -Text 'Marking as collected...' -Indent 1 -ConsoleOnly

        # For TV, a fully-downloaded show is marked show-level so it leaves MDBList
        # "not collected" lists; a partial show is marked episode-level. Completeness is
        # read fresh from Sonarr (post-import, so it includes the file we just imported).
        $mdbShowComplete = $false
        if ($mdbMediaType -eq 'tv' -and $null -ne $importResult.ArrMetadata) {
            $mdbShowComplete = Test-SAArrShowFullyDownloaded -AppType 'Sonarr' `
                -Config $Context.Config.importers.sonarr -SeriesId $importResult.ArrMetadata.ArrId
        }

        $mdbResult = Invoke-SAMDBListCollect -Config $Context.Config.mdblist `
            -ArrMetadata $importResult.ArrMetadata `
            -MediaType $mdbMediaType `
            -ImportedEpisodes $importResult.ImportedEpisodes `
            -ShowComplete:$mdbShowComplete
        if ($mdbResult.Success) {
            if ($mdbResult.Updated -gt 0) {
                Write-SAOutcome -Level Success -Label 'MDBList' -Text 'Marked as collected' -Duration $mdbResult.Duration -Indent 1 -EmailInclude
            } else {
                # HTTP 200 but nothing changed: already collected, or MDBList could not
                # resolve the supplied ID. Either way it is not a failure, just no-op.
                Write-SAOutcome -Level Success -Label 'MDBList' -Text 'Already collected (no change)' -Duration $mdbResult.Duration -Indent 1
            }
        } elseif (-not $mdbResult.Skipped) {
            Write-SAOutcome -Level Warning -Label 'MDBList' -Text 'Not marked (non-fatal)' -Indent 1
            Add-SAEmailException -Message "MDBList: $($mdbResult.ErrorMessage)" -Type Warning
        }
    }

    # TBA auto-retry: schedule a retry job if import was skipped due to TBA title
    $tbaRetryScheduled = $false
    $tbaRetryAfter = $null
    if (Test-SATbaRetryNeeded -ImportResult $importResult -Job $Job) {
        $tbaRetryAfter = (Get-Date).AddHours($script:SAConstants.TbaRetryDelayHours)

        $retryParams = @{
            QueueRoot     = $Context.Paths.QueueRoot
            DownloadPath  = $Job.input.downloadPath
            DownloadLabel = $Job.input.downloadLabel
            TorrentHash   = $Job.input.torrentHash
            DownloadRoot  = $Job.input.downloadRoot
            RetryAfter    = $tbaRetryAfter
            TbaRetry      = $true
            StagingPath   = $Context.State.StagingPath
            Force         = $true
        }

        $retryJob = Add-SAJob @retryParams
        if ($null -ne $retryJob) {
            $tbaRetryScheduled = $true
            $Context.Flags.NoCleanup = $true
            Write-SAVerbose -Text "TBA retry scheduled for $(($tbaRetryAfter).ToString('yyyy-MM-dd HH:mm')) (job: $($retryJob.id))"
        }
    }

    # Email metadata enrichment
    # OMDb (cached from early pipeline query) provides poster + ratings
    # ArrMetadata (from import) provides *arr ratings/genre/plot
    # Merge strategy: *arr base + OMDb poster, fill rating gaps from OMDb
    $omdbData = $null

    # Get metadata source from config (defaults to 'auto')
    $metadataSourceConfig = 'auto'
    if ($Context.Config.notifications.email.metadata -and
        $Context.Config.notifications.email.metadata.source) {
        $metadataSourceConfig = $Context.Config.notifications.email.metadata.source
    }

    $cachedOmdb = $Context.State.OmdbData  # From early pipeline query (may be null)
    $arrMetadata = if ($null -ne $importResult) { $importResult.ArrMetadata } else { $null }

    if ($metadataSourceConfig -eq 'none') {
        Write-SAVerbose -Text "Email metadata: Disabled (metadata.source = none)"
    } elseif ($metadataSourceConfig -eq 'omdb') {
        # Force OMDb only
        if ($cachedOmdb) {
            $omdbData = $cachedOmdb
            Write-SAVerbose -Text "Email metadata: Using OMDb (metadata.source = omdb)"
        } else {
            Write-SAVerbose -Text "Email metadata: None available (metadata.source = omdb but OMDb disabled)"
        }
    } elseif ($null -ne $arrMetadata) {
        # Auto mode: merge *arr metadata with OMDb poster
        $omdbData = $arrMetadata

        if ($null -ne $cachedOmdb) {
            Write-SAVerbose -Text "Email metadata: Merging ArrMetadata + OMDb poster"
            # Overlay OMDb poster (small, reliable ~25KB)
            if ($cachedOmdb.PosterData) {
                $omdbData.PosterData = $cachedOmdb.PosterData
            }
            # Fill missing ratings from OMDb
            if (-not $omdbData.ImdbRating -and $cachedOmdb.ImdbRating) {
                $omdbData.ImdbRating = $cachedOmdb.ImdbRating
            }
            if (-not $omdbData.RottenTomatoes -and $cachedOmdb.RottenTomatoes) {
                $omdbData.RottenTomatoes = $cachedOmdb.RottenTomatoes
            }
            if (-not $omdbData.Metacritic -and $cachedOmdb.Metacritic) {
                $omdbData.Metacritic = $cachedOmdb.Metacritic
            }
        } else {
            Write-SAVerbose -Text "Email metadata: Using ArrMetadata (no OMDb available)"
        }

        # Respect display.plot config
        if ($Context.Config.omdb.display.plot -ne $true) {
            $omdbData.Plot = $null
        }
    } elseif ($null -ne $cachedOmdb) {
        # No *arr metadata, use OMDb directly
        $omdbData = $cachedOmdb
        Write-SAVerbose -Text "Email metadata: Using OMDb (no ArrMetadata available)"
    } else {
        Write-SAVerbose -Text "Email metadata: None available"
    }
    
    # Step 4: Finalize (Cleanup, Log, Email)
    Write-SAPhaseHeader -Title "Finalize"
    Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Finalize' -Activity 'Cleaning up...'

    # Cleanup staging folder
    # TBA retry jobs always clean up (staged files have served their purpose)
    $forceCleanup = ($Job.input.tbaRetry -eq $true)
    if ($forceCleanup -or -not $Context.Flags.NoCleanup) {
        Remove-SAStagingFolder -Context $Context
    } else {
        Write-SAProgress -Label "Cleanup" -Text "Skipped (NoCleanup flag)" -Indent 1
    }
    
    # Step 5: Build email summary (using pure helper functions from Phase 6)
    $jobSuccess = ($videoResult.Success -eq $true) -and $importSuccess
    $duration = Get-SAContextDuration -Context $Context
    
    # Extract subtitle languages using pure helper function
    $subLangs = Get-SASubtitleLanguagesFromResult -SubtitleFiles $(if ($subResult) { $subResult.SubtitleFiles } else { @() })
    
    # Extract missing languages using pure helper function
    $missingLangs = Get-SAMissingLanguageNames -MissingLanguages $(if ($subResult) { $subResult.MissingLanguages } else { @() })
    
    # Determine import target and result using pure helper functions
    $importTarget = Get-SAImportTargetName -Label $Job.input.downloadLabel -Config $Context.Config

    if ($tbaRetryScheduled -and $null -ne $importResult) {
        $importResult | Add-Member -NotePropertyName TbaRetryScheduled -NotePropertyValue $true -Force
    }

    $importResultText = Get-SAImportResultText -ImportResult $importResult
    
    # E4 fix: Use TotalSize from videoResult (calculated before cleanup)
    $videoCount = 0
    $videoSize = ''
    if ($videoResult.ProcessedFiles -and $videoResult.ProcessedFiles.Count -gt 0) {
        $videoCount = $videoResult.ProcessedFiles.Count

        # Use pre-calculated TotalSize if available (E4 fix)
        if ($videoResult.TotalSize -and $videoResult.TotalSize -gt 0) {
            $videoSize = Format-SASize $videoResult.TotalSize
        }
    }

    # For TBA retry import-only: calculate video stats from staging folder
    if ($skipProcessing -and $Context.State.StagingPath -and (Test-Path -LiteralPath $Context.State.StagingPath)) {
        $retryVideos = Get-ChildItem -LiteralPath $Context.State.StagingPath -Filter '*.mkv' -File -ErrorAction SilentlyContinue
        if ($retryVideos) {
            $videoCount = @($retryVideos).Count
            $totalSize = ($retryVideos | Measure-Object -Property Length -Sum).Sum
            if ($totalSize -gt 0) {
                $videoSize = Format-SASize $totalSize
            }
        }
    }

    # Use pre-parsed ReleaseInfo from Context.State (parsed early for verbose output)
    $releaseInfo = $Context.State.ReleaseInfo
    
    $friendlyName = $releaseInfo.FriendlyName
    
    # Determine overall result using pure helper function
    $emailResult = Get-SAEmailResultLevel -JobSuccess $jobSuccess -ImportResult $importResult -MissingLanguages $missingLangs
    
    # Build email summary parameters - E2 fix: use friendlyName, add SourceName
    $emailParams = @{
        Name         = $friendlyName
        SourceName   = $displayName     # Original release name for reference
        Label        = $Job.input.downloadLabel
        Subtitles    = $subLangs
        MissingLangs = $missingLangs
        ImportTarget = $importTarget
        ImportResult = $importResultText
        Result       = $emailResult
        Duration     = $duration.ToString('mm\:ss')
        VideoCount   = $videoCount
        VideoSize    = $videoSize
        ReleaseInfo  = $releaseInfo     # For subject template (ScreenSize, Source, etc.)
        TorrentHash  = $Job.input.torrentHash  # For {hash4} placeholder
        OmdbData     = $omdbData        # OMDb enrichment data (poster, ratings, genre)
    }
    
    # Add failure details for failed jobs
    if (-not $jobSuccess) {
        # Determine which phase failed
        if (-not $videoResult.Success) {
            $emailParams.FailurePhase = 'Staging'
            $emailParams.FailureError = if ($videoResult.Error) { $videoResult.Error } else { 'Video processing failed' }
            if ($videoResult.FailedFile) {
                $emailParams.FailurePath = $videoResult.FailedFile
            }
        } elseif ($null -ne $importResult -and -not $importResult.Success) {
            $emailParams.FailurePhase = 'Import'
            $emailParams.FailureError = if ($importResult.Message) { $importResult.Message } else { 'Import failed' }
            if ($importResult.Path) {
                $emailParams.FailurePath = $importResult.Path
            } elseif ($Context.State.StagingPath) {
                $emailParams.FailurePath = $Context.State.StagingPath
            }
        }
    }
    
    Set-SAEmailSummary @emailParams
    
    # Add exceptions for warnings/errors
    if ($missingLangs.Count -gt 0) {
        Add-SAEmailException -Message "Missing subtitles: $($missingLangs -join ', ')" -Type Warning
    }
    
    if (-not $videoResult.Success) {
        Add-SAEmailException -Message "Video processing failed" -Type Error
    }
    
    if ($null -ne $importResult -and -not $importResult.Success -and -not $importResult.Skipped -and -not $importResult.QualityRejected) {
        $importErrMsg = if ($importResult.Message) { $importResult.Message } else { 'Import failed' }
        Add-SAEmailException -Message "$importTarget`: $importErrMsg" -Type Error
    }
    
    # Add warnings for partial imports (some succeeded, some failed/aborted)
    # Phase 4 enhancement: Use episode-level detail when available
    if ($null -ne $importResult -and $importResult.Status -eq 'partial') {
        $imported = if ($importResult.ImportedCount) { $importResult.ImportedCount } else { 0 }
        $skipped = if ($importResult.SkippedCount) { $importResult.SkippedCount } else { 0 }
        $aborted = if ($importResult.AbortedCount) { $importResult.AbortedCount } else { 0 }
        
        # Check if we have episode-level data available
        $hasEpisodeData = ($importResult.ImportedFiles -and $importResult.ImportedFiles.Count -gt 0) -or
                          ($importResult.SkippedFiles -and $importResult.SkippedFiles.Count -gt 0) -or
                          ($importResult.AbortedFiles -and $importResult.AbortedFiles.Count -gt 0)
        
        if ($hasEpisodeData) {
            # Use episode-level formatting (consistent with console output)
            
            # Show what was imported
            if ($importResult.ImportedFiles -and $importResult.ImportedFiles.Count -gt 0) {
                $note = Format-SAImportEpisodeNote -Files $importResult.ImportedFiles -Action 'Imported'
                if (-not [string]::IsNullOrWhiteSpace($note)) {
                    Add-SAEmailException -Message $note -Type Info
                }
            }
            
            # Show what was skipped (quality exists)
            if ($importResult.SkippedFiles -and $importResult.SkippedFiles.Count -gt 0) {
                $note = Format-SAImportEpisodeNote -Files $importResult.SkippedFiles -Action 'Skipped'
                if (-not [string]::IsNullOrWhiteSpace($note)) {
                    Add-SAEmailException -Message $note -Type Warning
                }
            }
            
            # Show what was aborted - this needs attention
            if ($importResult.AbortedFiles -and $importResult.AbortedFiles.Count -gt 0) {
                $note = Format-SAImportEpisodeNote -Files $importResult.AbortedFiles -Action 'Aborted'
                if (-not [string]::IsNullOrWhiteSpace($note)) {
                    Add-SAEmailException -Message $note -Type Warning
                }
            }
        } else {
            # Fallback to count-based display (backward compatibility)
            
            # Show what was imported
            if ($imported -gt 0) {
                $fileWord = if ($imported -eq 1) { 'file' } else { 'files' }
                Add-SAEmailException -Message "$imported $fileWord imported to library" -Type Info
            }
            
            # Show what was skipped (quality exists)
            if ($skipped -gt 0) {
                $fileWord = if ($skipped -eq 1) { 'file' } else { 'files' }
                $reason = if ($importResult.SkipReason) { $importResult.SkipReason } else { 'already exists' }
                Add-SAEmailException -Message "$skipped $fileWord skipped: $reason" -Type Warning
            }
            
            # Show what was aborted - this needs attention
            if ($aborted -gt 0) {
                $fileWord = if ($aborted -eq 1) { 'file' } else { 'files' }
                $reason = if ($importResult.AbortReason) { $importResult.AbortReason } else { 'processing aborted' }
                Add-SAEmailException -Message "$aborted $fileWord aborted: $reason" -Type Warning
            }
        }
    }

    # TBA retry email notifications
    $isTbaRetry = ($Job.input.tbaRetry -eq $true)
    if ($tbaRetryScheduled -or $isTbaRetry) {
        Add-SATbaRetryEmailExceptions -ImportResult $importResult `
            -RetryAfter $tbaRetryAfter -ImportTarget $importTarget `
            -IsTbaRetry $isTbaRetry
    }

    # Step 6: Save file log and set path in email
    $logPath = Get-SAContextLogPath -Context $Context
    Save-SAFileLog -Path $logPath
    Set-SAEmailLogPath -Path $logPath
    
    Write-SAProgress -Label "Log" -Text $logPath -Indent 1 -ConsoleOnly
    
    # Step 7: Send email notification
    if (-not $Context.Flags.NoMail -and $Context.Config.notifications.email.enabled) {
        $title = "$($Job.input.downloadLabel) - $displayName"
        $emailBody = ConvertTo-SAEmailHtml -Title $title
        
        # Get configured subject style and template
        $emailConfig = $Context.Config.notifications.email
        $subjectStyle = if ($emailConfig.subjectStyle) { 
            $emailConfig.subjectStyle 
        } else { 
            'detailed'  # Default
        }
        $subjectTemplate = if ($emailConfig.subjectTemplate) {
            $emailConfig.subjectTemplate
        } else {
            ''
        }
        
        # Determine result for subject
        $subjectResult = if ($jobSuccess) {
            if ($tbaRetryScheduled) {
                'Success'
            } elseif ($importResult.QualityRejected -eq $true -or $importResult.Skipped -eq $true) {
                'Skipped'
            } else {
                'Success'
            }
        } else {
            'Failed'
        }
        
        $emailSubject = Get-SAEmailSubject -Result $subjectResult `
                                           -SubjectStyle $subjectStyle `
                                           -SubjectTemplate $subjectTemplate
        
        # Extract inline images from OmdbData for CID references
        $inlineImages = Get-SAEmailInlineImages -OmdbData $omdbData
        
        Send-SAEmail -Config $emailConfig `
            -Subject $emailSubject `
            -Body $emailBody `
            -InlineImages $inlineImages
    }
    
    # Return success only if both video processing and import succeeded
    return $jobSuccess
}

#endregion
