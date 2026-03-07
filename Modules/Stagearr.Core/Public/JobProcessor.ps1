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

function Get-SAEmailMetadataSource {
    <#
    .SYNOPSIS
        Determines the source of email metadata.
    .DESCRIPTION
        Pure function - no I/O. Identifies which source will be used for email metadata
        based on configuration and availability:
        - 'none': Metadata disabled in config
        - 'ArrMetadata': From Radarr/Sonarr ManualImport scan
        - 'OMDb': From OMDb API lookup
    .PARAMETER ImportResult
        Import result object that may contain ArrMetadata.
    .PARAMETER OmdbEnabled
        Whether OMDb feature is enabled in config.
    .PARAMETER ConfigSource
        Configured metadata source: 'auto', 'omdb', or 'none'.
    .OUTPUTS
        String identifying the metadata source.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ImportResult,
        
        [Parameter()]
        [bool]$OmdbEnabled = $false,
        
        [Parameter()]
        [ValidateSet('auto', 'omdb', 'none')]
        [string]$ConfigSource = 'auto'
    )
    
    # Check config override first
    if ($ConfigSource -eq 'none') {
        return 'none'
    }
    
    if ($ConfigSource -eq 'omdb') {
        # Force OMDb - skip ArrMetadata check
        if ($OmdbEnabled) {
            return 'OMDb'
        }
        return 'none'
    }
    
    # Auto mode: Check if ArrMetadata is available from import
    if ($null -ne $ImportResult -and $null -ne $ImportResult.ArrMetadata) {
        return 'ArrMetadata'
    }
    
    # Check if OMDb fallback is available
    if ($OmdbEnabled) {
        return 'OMDb'
    }
    
    return 'none'
}

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
        -TorrentHash $Job.input.torrentHash
    
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
    
    # Step 1: Video processing (RAR/remux/strip/extract)
    Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Staging' -Activity 'Processing video files...'
    $videoResult = Invoke-SAVideoProcessing -Context $Context
    
    if (-not $videoResult.Success) {
        Write-SAOutcome -Level Error -Label "Staging" -Text "Processing failed" -Indent 1
        # Don't return early - continue to cleanup and notification
    }
    
    # Step 2: Subtitle processing (external + OpenSubtitles + cleanup)
    $subResult = $null
    $importResult = $null
    
    if ($videoResult.Success) {
        # Get all staging videos for subtitle processing
        $stagingVideos = Get-ChildItem -LiteralPath $Context.State.StagingPath -Filter '*.mkv' -File -ErrorAction SilentlyContinue
        
        if ($stagingVideos -and $stagingVideos.Count -gt 0) {
            $subParams = @{
                Context        = $Context
                ProcessedFiles = $videoResult.ProcessedFiles
                SourcePath     = $Job.input.downloadPath
            }
            
            Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Subtitles' -Activity 'Processing subtitles...'
            $subResult = Invoke-SASubtitleProcessing @subParams
        }
        
        # Step 3: Import to media server (Radarr/Sonarr/Medusa)
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
    
    # Email metadata enrichment - Priority based on config: metadata.source
    # This happens BEFORE cleanup so we have access to release info, and BEFORE email summary
    $omdbData = $null
    $omdbEnabled = Test-SAFeatureEnabled -Feature 'omdb' -Config $Context.Config
    
    # Get metadata source from config (defaults to 'auto')
    $metadataSourceConfig = 'auto'
    if ($Context.Config.notifications.email.metadata -and 
        $Context.Config.notifications.email.metadata.source) {
        $metadataSourceConfig = $Context.Config.notifications.email.metadata.source
    }
    
    # Get poster size from config (defaults to 'w185')
    $posterSize = 'w185'
    if ($Context.Config.notifications.email.metadata -and 
        $Context.Config.notifications.email.metadata.poster -and 
        $Context.Config.notifications.email.metadata.poster.size) {
        $posterSize = $Context.Config.notifications.email.metadata.poster.size
    }
    
    # Determine actual metadata source based on config and availability
    $metadataSource = Get-SAEmailMetadataSource -ImportResult $importResult -OmdbEnabled $omdbEnabled -ConfigSource $metadataSourceConfig
    
    if ($metadataSourceConfig -eq 'none') {
        # Metadata disabled
        Write-SAVerbose -Text "Email metadata: Disabled (metadata.source = none)"
    } elseif ($metadataSourceConfig -eq 'omdb') {
        # Force OMDb - skip ArrMetadata
        if ($omdbEnabled) {
            Write-SAVerbose -Text "Email metadata: Using OMDb (metadata.source = omdb)"
            
            $releaseInfo = $Context.State.ReleaseInfo
            if ($releaseInfo -and $releaseInfo.Title) {
                $labelType = Get-SALabelType -Label $Job.input.downloadLabel -Config $Context.Config
                $omdbType = if ($labelType -eq 'tv') { 'series' } else { 'movie' }
                
                $omdbData = Get-SAOmdbMetadata `
                    -Title $releaseInfo.Title `
                    -Year $releaseInfo.Year `
                    -Type $omdbType `
                    -Config $Context.Config.omdb
            }
        } else {
            Write-SAVerbose -Text "Email metadata: None available (metadata.source = omdb but OMDb disabled)"
        }
    } elseif ($null -ne $importResult -and $null -ne $importResult.ArrMetadata) {
        # Auto mode with ArrMetadata available
        $omdbData = $importResult.ArrMetadata
        Write-SAVerbose -Text "Email metadata: Using ArrMetadata from $($importResult.ArrMetadata.Source)"
        
        # Download poster from TMDb if enabled and URL available
        $posterEnabled = $Context.Config.omdb.poster.enabled -ne $false
        if ($posterEnabled -and -not [string]::IsNullOrWhiteSpace($omdbData.PosterUrl) -and $null -eq $omdbData.PosterData) {
            # Update poster URL to use configured size
            if ($omdbData.PosterUrl -match '/t/p/\w+/') {
                $omdbData.PosterUrl = $omdbData.PosterUrl -replace '/t/p/\w+/', "/t/p/$posterSize/"
            }
            $omdbData.PosterData = Get-SAArrPosterData -PosterUrl $omdbData.PosterUrl
        }
        
        # Respect display.plot config - clear if not enabled
        $plotEnabled = $Context.Config.omdb.display.plot -eq $true
        if (-not $plotEnabled) {
            $omdbData.Plot = $null
        }
    } elseif ($Context.State.OmdbData) {
        # Cached from IMDB ID resolution during subtitle upload — reuse to avoid duplicate API call
        $omdbData = $Context.State.OmdbData
        Write-SAVerbose -Text "Email metadata: Using cached OMDb data from subtitle upload"
    } elseif ($omdbEnabled) {
        # Auto mode, falling back to OMDb API
        Write-SAVerbose -Text "Email metadata: Falling back to OMDb API"

        $releaseInfo = $Context.State.ReleaseInfo
        if ($releaseInfo -and $releaseInfo.Title) {
            $labelType = Get-SALabelType -Label $Job.input.downloadLabel -Config $Context.Config
            $omdbType = if ($labelType -eq 'tv') { 'series' } else { 'movie' }

            $omdbData = Get-SAOmdbMetadata `
                -Title $releaseInfo.Title `
                -Year $releaseInfo.Year `
                -Type $omdbType `
                -Config $Context.Config.omdb
        }
    } else {
        Write-SAVerbose -Text "Email metadata: None available (no ArrMetadata, OMDb disabled)"
    }
    
    # Step 4: Finalize (Cleanup, Log, Email)
    Write-SAPhaseHeader -Title "Finalize"
    Update-SAJobProgress -QueueRoot $Context.Paths.QueueRoot -JobId $Job.id -Phase 'Finalize' -Activity 'Cleaning up...'

    # Cleanup staging folder (unless NoCleanup flag is set)
    if (-not $Context.Flags.NoCleanup) {
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
            if ($importResult.QualityRejected -eq $true -or $importResult.Skipped -eq $true) {
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
