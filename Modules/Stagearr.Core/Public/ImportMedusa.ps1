#Requires -Version 5.1
<#
.SYNOPSIS
    Medusa import functions for Stagearr
.DESCRIPTION
    Handles import/scan triggers for Medusa (TV show management).
    Uses Medusa API v2 for postprocess operations.
    
    Exported functions:
    - Invoke-SAMedusaImport: Main import logic
    - Wait-SAMedusaQueue: Poll queue for completion
    - Test-SAMedusaConnection: Connection test
    
    Dependencies:
    - Private/ImportUtility.ps1 (URL building, path translation)
    - Private/ImportResultParser.ps1 (output parsing)
#>

#region Episode Output Helpers

function Get-SAMedusaSeasonFromFiles {
    <#
    .SYNOPSIS
        Extracts the season number from file detail arrays.
    .DESCRIPTION
        Retrieves the season from the first file that has episode info.
        All files in a batch should be from the same season.
    .PARAMETER ImportedFiles
        Array of imported file details.
    .PARAMETER SkippedFiles
        Array of skipped file details.
    .PARAMETER AbortedFiles
        Array of aborted file details.
    .OUTPUTS
        Season number or $null if no episode info available.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [array]$ImportedFiles = @(),
        
        [Parameter()]
        [array]$SkippedFiles = @(),
        
        [Parameter()]
        [array]$AbortedFiles = @()
    )
    
    # Combine all files and find the first with season info
    $allFiles = @($ImportedFiles) + @($SkippedFiles) + @($AbortedFiles)
    foreach ($file in $allFiles) {
        if ($null -ne $file -and $null -ne $file.Season) {
            return $file.Season
        }
    }
    
    return $null
}

function Write-SAMedusaEpisodeOutcome {
    <#
    .SYNOPSIS
        Writes episode-level import outcome to console.
    .DESCRIPTION
        Formats and writes import outcome using episode identifiers when available.
        Falls back to file count display when episode info is missing.
        
        Uses Phase 1 formatting functions (Format-SAEpisodeOutcome) for consistent display.
    .PARAMETER Files
        Array of file detail objects (from ImportedFiles, SkippedFiles, or AbortedFiles).
    .PARAMETER Season
        Season number (if known from other sources).
    .PARAMETER Action
        The action: 'Imported', 'Skipped', or 'Aborted'.
    .PARAMETER Reason
        Optional reason text for skipped/aborted.
    .PARAMETER Level
        Output level: Success, Warning, or Error.
    .PARAMETER Duration
        Optional duration in seconds.
    .PARAMETER Indent
        Indentation level for console output (default: 1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Files,
        
        [Parameter()]
        [int]$Season,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Imported', 'Skipped', 'Aborted')]
        [string]$Action,
        
        [Parameter()]
        [string]$Reason = '',
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Error')]
        [string]$Level,
        
        [Parameter()]
        [int]$Duration,
        
        [Parameter()]
        [int]$Indent = 1
    )
    
    if ($Files.Count -eq 0) {
        return
    }
    
    # Try to get season from files if not provided
    if (-not $Season -or $Season -le 0) {
        foreach ($file in $Files) {
            if ($null -ne $file.Season -and $file.Season -gt 0) {
                $Season = $file.Season
                break
            }
        }
    }
    
    # Extract episodes that have valid episode numbers
    $episodes = @($Files | Where-Object { $null -ne $_.Episode } | ForEach-Object { $_.Episode })
    
    # Determine display text
    if ($Season -and $Season -gt 0 -and $episodes.Count -gt 0) {
        # Use episode formatting
        $text = Format-SAEpisodeOutcome -Season $Season -Episodes $episodes -Action $Action -Reason $Reason
    } else {
        # Fallback to count-based display (no episode info available)
        $count = $Files.Count
        $fileWord = Get-SAPluralForm -Count $count -Singular 'file'
        $text = "$Action $count $fileWord"
        if (-not [string]::IsNullOrWhiteSpace($Reason)) {
            $text = "$text ($Reason)"
        }
    }
    
    # Write the outcome
    $params = @{
        Level  = $Level
        Label  = 'Medusa'
        Text   = $text
        Indent = $Indent
    }
    if ($Duration) {
        $params['Duration'] = $Duration
    }
    
    Write-SAOutcome @params
}

#endregion

#region Medusa Import

function Invoke-SAMedusaImport {
    <#
    .SYNOPSIS
        Triggers Medusa to scan and import downloaded TV episodes.
    .DESCRIPTION
        Uses Medusa API v2 to trigger postprocess endpoint.
        Queues the job and polls for completion status.
    .PARAMETER Config
        Medusa configuration hashtable (host, port, apiKey, etc.).
    .PARAMETER StagingPath
        Path to the staging folder containing the episode(s).
    .PARAMETER StagingRoot
        Root staging folder for relative path calculation.
    .PARAMETER ProcessMethod
        Processing method: 'copy', 'move', 'hardlink', 'symlink' (default: 'move').
    .OUTPUTS
        Import result object with Success and Message.
    .EXAMPLE
        $result = Invoke-SAMedusaImport -Config $config.importers.medusa -StagingPath "C:\Staging\TV\Show" -StagingRoot "C:\Staging"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        
        [Parameter()]
        [string]$StagingRoot,
        
        [Parameter()]
        [ValidateSet('copy', 'move', 'hardlink', 'symlink')]
        [string]$ProcessMethod = 'move'
    )
    
    # Build base URL (returns object with Url, DisplayUrl, and HostHeader)
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $baseUrl = $urlInfo.Url
    Write-SAVerbose -Text "Medusa server: $($urlInfo.DisplayUrl)"
    Write-SAVerbose -Text "Connecting to: $baseUrl"
    
    # Test API connection
    if (-not (Test-SAMedusaConnection -Config $Config)) {
        Write-SAOutcome -Level Error -Label "Medusa" -Text "Cannot connect to API" -Indent 1
        return [PSCustomObject]@{
            Success = $false
            Message = 'Connection failed'
        }
    }
    
    # Handle remote path mapping
    $importPath = $StagingPath
    if (-not [string]::IsNullOrWhiteSpace($Config.remotePath)) {
        $importPath = Convert-SAToRemotePath -LocalPath $StagingPath -RemotePath $Config.remotePath -StagingRoot $StagingRoot
        if ($importPath -ne $StagingPath) {
            Write-SAVerbose -Text "Path translated: $StagingPath -> $importPath"
        }
    }
    
    # Keep native path format (backslashes on Windows)
    Write-SAVerbose -Text "Import path: $importPath"
    Write-SAVerbose -Text "Process method: $ProcessMethod"
    
    # Build postprocess URL - POST to queue the job
    $uri = "$baseUrl/api/v2/postprocess"
    
    $headers = @{
        'X-Api-Key'    = $Config.apiKey
        'Content-Type' = 'application/json'
        'Accept'       = 'application/json'
    }
    
    # Add Host header for reverse proxy compatibility
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }
    
    $body = @{
        proc_dir        = $importPath
        process_method  = $ProcessMethod
        force           = $true
        proc_type       = 'manual'
    }
    
    Write-SAProgress -Label "Medusa" -Text "Importing..." -Indent 1 -ConsoleOnly
    Write-SAVerbose -Text "Request: POST $uri"
    
    # Use reasonable timeout for queue request (15 sec)
    $result = Invoke-SAWebRequest -Uri $uri -Method POST -Headers $headers -Body $body -TimeoutSeconds 15
    
    if (-not $result.Success) {
        Write-SAOutcome -Level Error -Label "Medusa" -Text "Failed to queue import: $($result.ErrorMessage)" -Indent 1
        return [PSCustomObject]@{
            Success = $false
            Message = $result.ErrorMessage
        }
    }
    
    # Check if we got a queue ID back
    $queueId = $result.Data.queueItem.identifier
    if (-not $queueId) {
        # Medusa sometimes returns success without a queue ID for quick operations
        if ($result.Data.status -eq 'success') {
            Write-SAOutcome -Level Success -Label "Medusa" -Text "Imported" -Indent 1
            return [PSCustomObject]@{
                Success = $true
                Message = 'Imported'
            }
        }
        
        Write-SAOutcome -Level Warning -Label "Medusa" -Text "No queue ID returned" -Indent 1
        return [PSCustomObject]@{
            Success = $true  # Assume success if Medusa accepted the request
            Message = 'Queued (no ID)'
        }
    }
    
    Write-SAVerbose -Text "Queue ID: $queueId"
    
    # Poll for completion
    $timeout = if ($Config.timeoutMinutes) { $Config.timeoutMinutes } else { $script:SAConstants.DefaultImportTimeoutMinutes }
    $pollResult = Wait-SAMedusaQueue -Config $Config -QueueId $queueId -TimeoutMinutes $timeout
    
    # Get result properties from poll result
    $isSkipped = $pollResult.Skipped -eq $true
    $skipReason = if ($pollResult.SkipReason) { $pollResult.SkipReason } else { $pollResult.Message }
    $importedCount = if ($pollResult.ImportedCount) { $pollResult.ImportedCount } else { 0 }
    $skippedCount = if ($pollResult.SkippedCount) { $pollResult.SkippedCount } else { 0 }
    
    if ($pollResult.Success) {
        # Handle different statuses
        switch ($pollResult.Status) {
            'partial' {
                # Partial import - some succeeded, some skipped/aborted
                $abortedCount = if ($pollResult.AbortedCount) { $pollResult.AbortedCount } else { 0 }
                $skippedCount = if ($pollResult.SkippedCount) { $pollResult.SkippedCount } else { 0 }
                $abortReason = if ($pollResult.AbortReason) { $pollResult.AbortReason } else { '' }
                $skipReason = if ($pollResult.SkipReason) { $pollResult.SkipReason } else { 'quality exists' }
                
                # Get season from any file for consistent display
                $season = Get-SAMedusaSeasonFromFiles -ImportedFiles $pollResult.ImportedFiles -SkippedFiles $pollResult.SkippedFiles -AbortedFiles $pollResult.AbortedFiles
                
                # Check if we have episode-level data available
                $hasEpisodeData = ($pollResult.ImportedFiles.Count -gt 0) -or ($pollResult.SkippedFiles.Count -gt 0) -or ($pollResult.AbortedFiles.Count -gt 0)
                
                if ($hasEpisodeData -and $season) {
                    # Use episode-level output
                    
                    # Primary outcome: what was imported
                    if ($pollResult.ImportedFiles.Count -gt 0) {
                        Write-SAMedusaEpisodeOutcome -Files $pollResult.ImportedFiles -Season $season -Action 'Imported' -Level Success -Duration $pollResult.Duration -Indent 1
                    }
                    
                    # Show skipped files (expected, lower priority than aborts)
                    if ($pollResult.SkippedFiles.Count -gt 0) {
                        # Get reason from first skipped file if available
                        $displayReason = if ($pollResult.SkippedFiles[0].Reason) { $pollResult.SkippedFiles[0].Reason } else { $skipReason }
                        Write-SAMedusaEpisodeOutcome -Files $pollResult.SkippedFiles -Season $season -Action 'Skipped' -Reason $displayReason -Level Warning
                    }
                    
                    # Show aborted files as WARNING (job succeeded overall, but these need attention)
                    if ($pollResult.AbortedFiles.Count -gt 0) {
                        # Get reason from first aborted file if available
                        $displayReason = if ($pollResult.AbortedFiles[0].Reason) { $pollResult.AbortedFiles[0].Reason } else { $abortReason }
                        Write-SAMedusaEpisodeOutcome -Files $pollResult.AbortedFiles -Season $season -Action 'Aborted' -Reason $displayReason -Level Warning
                        if ($displayReason -match 'Archived') {
                            Write-SAProgress -Label "Hint" -Text "Some episodes are archived in Medusa - change status to Wanted or Skipped" -Indent 2
                        }
                    }
                } else {
                    # Fallback to count-based display (no episode info available)
                    
                    # Primary outcome: what was imported
                    Write-SAOutcome -Level Success -Label "Medusa" -Text "Imported $importedCount$(if ($importedCount -eq 1) { ' file' } else { ' files' })" -Duration $pollResult.Duration -Indent 1
                    
                    # Show aborted files as WARNING
                    if ($abortedCount -gt 0) {
                        Write-SAOutcome -Level Warning -Label "Medusa" -Text "$abortedCount aborted ($abortReason)" -Indent 1
                        if ($abortReason -match 'Archived') {
                            Write-SAProgress -Label "Hint" -Text "Some episodes are archived in Medusa - change status to Wanted or Skipped" -Indent 2
                        }
                    }
                    
                    # Show skipped files (expected, lower priority)
                    if ($skippedCount -gt 0) {
                        Write-SAOutcome -Level Warning -Label "Medusa" -Text "$skippedCount skipped ($skipReason)" -Indent 1
                    }
                }
                
                $isSkipped = $false  # Not fully skipped, partial success
            }
            'skipped' {
                # All files skipped - mark as skipped for result object
                $isSkipped = $true
                
                $season = Get-SAMedusaSeasonFromFiles -SkippedFiles $pollResult.SkippedFiles
                $hasEpisodeData = $pollResult.SkippedFiles.Count -gt 0
                
                if ($hasEpisodeData -and $season) {
                    # Use episode-level output
                    $displayReason = if ($pollResult.SkippedFiles[0].Reason) { $pollResult.SkippedFiles[0].Reason } else { $skipReason }
                    Write-SAMedusaEpisodeOutcome -Files $pollResult.SkippedFiles -Season $season -Action 'Skipped' -Reason $displayReason -Level Warning -Duration $pollResult.Duration -Indent 1
                } else {
                    # Fallback to count-based display
                    $skipText = switch -Regex ($skipReason) {
                        'quality'     { 'Skipped (quality exists)' }
                        'same size'   { 'Skipped (same size)' }
                        'processed'   { 'Skipped (exists)' }
                        default       { 'Skipped (exists)' }
                    }
                    $countText = if ($skippedCount -gt 1) { " ($skippedCount files)" } else { '' }
                    Write-SAOutcome -Level Warning -Label "Medusa" -Text "$skipText$countText" -Duration $pollResult.Duration -Indent 1
                }
                Add-SAEmailException -Message "$skipReason" -Type Warning
            }
            default {
                # Normal success
                $season = Get-SAMedusaSeasonFromFiles -ImportedFiles $pollResult.ImportedFiles
                $hasEpisodeData = $pollResult.ImportedFiles.Count -gt 0
                
                if ($hasEpisodeData -and $season) {
                    # Use episode-level output
                    Write-SAMedusaEpisodeOutcome -Files $pollResult.ImportedFiles -Season $season -Action 'Imported' -Level Success -Duration $pollResult.Duration -Indent 1
                } elseif ($importedCount -gt 1) {
                    # Fallback with count
                    Write-SAOutcome -Level Success -Label "Medusa" -Text "Imported $importedCount files" -Duration $pollResult.Duration -Indent 1
                } else {
                    # Single file or unknown count
                    Write-SAOutcome -Level Success -Label "Medusa" -Text "Imported" -Duration $pollResult.Duration -Indent 1
                }
            }
        }
    } else {
        # Failed - use ErrorType from poll result for specific handling
        $msg = $pollResult.Message
        $errorType = $pollResult.ErrorType
        
        switch ($errorType) {
            'postponed' {
                Write-SAOutcome -Level Error -Label "Medusa" -Text "Postponed (missing subtitles)" -Duration $pollResult.Duration -Indent 1
                Write-SAProgress -Label "Hint" -Text "Medusa is waiting for subtitles before processing" -Indent 2
                Add-SAEmailException -Message $msg -Type Error
            }
            'aborted' {
                # Show the actual reason from Medusa
                $displayMsg = if ($msg -and $msg -ne 'Processing aborted') { $msg } else { 'Processing aborted' }
                Write-SAOutcome -Level Error -Label "Medusa" -Text $displayMsg -Duration $pollResult.Duration -Indent 1
                
                # Add specific hints based on the error
                if ($msg -match 'Archived') {
                    Write-SAProgress -Label "Hint" -Text "Episode is archived in Medusa - change status to Wanted or Skipped" -Indent 2
                } else {
                    Write-SAProgress -Label "Path" -Text $importPath -Indent 2
                }
                Add-SAEmailException -Message $displayMsg -Type Error
            }
            'mixed' {
                # Mixed scenario: some quality skips, some aborts
                $abortedCount = if ($pollResult.AbortedCount) { $pollResult.AbortedCount } else { 0 }
                $skippedCount = if ($pollResult.SkippedCount) { $pollResult.SkippedCount } else { 0 }
                $abortReason = if ($pollResult.AbortReason) { $pollResult.AbortReason } else { 'Processing aborted' }
                $skipReason = if ($pollResult.SkipReason) { $pollResult.SkipReason } else { 'Quality exists' }
                
                # Get season for episode-level display
                $season = Get-SAMedusaSeasonFromFiles -SkippedFiles $pollResult.SkippedFiles -AbortedFiles $pollResult.AbortedFiles
                $hasEpisodeData = ($pollResult.SkippedFiles.Count -gt 0) -or ($pollResult.AbortedFiles.Count -gt 0)
                
                if ($hasEpisodeData -and $season) {
                    # Use episode-level output
                    
                    # Show the abort as the primary error
                    if ($pollResult.AbortedFiles.Count -gt 0) {
                        $displayReason = if ($pollResult.AbortedFiles[0].Reason) { $pollResult.AbortedFiles[0].Reason } else { $abortReason }
                        Write-SAMedusaEpisodeOutcome -Files $pollResult.AbortedFiles -Season $season -Action 'Aborted' -Reason $displayReason -Level Error -Duration $pollResult.Duration -Indent 1
                    }
                    
                    # Show the skips as secondary
                    if ($pollResult.SkippedFiles.Count -gt 0) {
                        $displayReason = if ($pollResult.SkippedFiles[0].Reason) { $pollResult.SkippedFiles[0].Reason } else { $skipReason }
                        Write-SAMedusaEpisodeOutcome -Files $pollResult.SkippedFiles -Season $season -Action 'Skipped' -Reason $displayReason -Level Warning
                    }
                } else {
                    # Fallback to count-based display
                    
                    # Show the abort as the primary error
                    Write-SAOutcome -Level Error -Label "Medusa" -Text "$abortedCount aborted ($abortReason)" -Duration $pollResult.Duration -Indent 1
                    
                    # Show the skips as a secondary warning
                    Write-SAOutcome -Level Warning -Label "Medusa" -Text "$skippedCount skipped ($skipReason)" -Indent 1
                }
                
                # Add specific hints based on the abort reason
                if ($abortReason -match 'Archived') {
                    Write-SAProgress -Label "Hint" -Text "Some episodes are archived in Medusa - change status to Wanted or Skipped" -Indent 2
                }
                
                Add-SAEmailException -Message "$abortedCount aborted: $abortReason" -Type Error
                Add-SAEmailException -Message "$skippedCount skipped: $skipReason" -Type Warning
            }
            'file-operation' {
                Write-SAOutcome -Level Error -Label "Medusa" -Text $msg -Duration $pollResult.Duration -Indent 1
                Write-SAProgress -Label "Path" -Text $importPath -Indent 2
                Add-SAEmailException -Message $msg -Type Error
            }
            'permission' {
                Write-SAOutcome -Level Error -Label "Medusa" -Text $msg -Duration $pollResult.Duration -Indent 1
                Write-SAProgress -Label "Path" -Text $importPath -Indent 2
                Add-SAEmailException -Message $msg -Type Error
            }
            'unpack' {
                Write-SAOutcome -Level Error -Label "Medusa" -Text $msg -Duration $pollResult.Duration -Indent 1
                Add-SAEmailException -Message $msg -Type Error
            }
            'parse' {
                Write-SAOutcome -Level Error -Label "Medusa" -Text $msg -Duration $pollResult.Duration -Indent 1
                Write-SAProgress -Label "Hint" -Text "Check release naming or add scene exception" -Indent 2
                Add-SAEmailException -Message $msg -Type Error
            }
            'not-found' {
                Write-SAOutcome -Level Error -Label "Medusa" -Text $msg -Duration $pollResult.Duration -Indent 1
                Write-SAProgress -Label "Hint" -Text "Ensure show exists in Medusa" -Indent 2
                Add-SAEmailException -Message $msg -Type Error
            }
            default {
                # Check for skip patterns in output even on failure (edge cases)
                $outputText = if ($pollResult.Output -is [array]) { $pollResult.Output -join "`n" } else { $pollResult.Output }
                
                # Quality rejection
                if ($outputText -match 'Processing failed for.+File exists.+quality is equal|Processing failed for.+Marking it unsafe to replace.+quality') {
                    $isSkipped = $true
                    Write-SAOutcome -Level Warning -Label "Medusa" -Text "Skipped (quality exists)" -Duration $pollResult.Duration -Indent 1
                    Add-SAEmailException -Message "Same or better quality exists" -Type Warning
                }
                # Already processed
                elseif ($outputText -match 'already been processed, skipping|Skipping already processed') {
                    $isSkipped = $true
                    Write-SAOutcome -Level Warning -Label "Medusa" -Text "Skipped (exists)" -Duration $pollResult.Duration -Indent 1
                    Add-SAEmailException -Message "File already processed" -Type Warning
                }
                # Same size
                elseif ($outputText -match 'same size.*aborting|aborting post-processing') {
                    $isSkipped = $true
                    Write-SAOutcome -Level Warning -Label "Medusa" -Text "Skipped (same size)" -Duration $pollResult.Duration -Indent 1
                    Add-SAEmailException -Message "File already exists (same size)" -Type Warning
                }
                # File exists (generic)
                elseif ($outputText -match 'Processing failed for.+File exists') {
                    $isSkipped = $true
                    Write-SAOutcome -Level Warning -Label "Medusa" -Text "Skipped (exists)" -Duration $pollResult.Duration -Indent 1
                    Add-SAEmailException -Message "File already exists" -Type Warning
                }
                else {
                    Write-SAOutcome -Level Error -Label "Medusa" -Text $msg -Duration $pollResult.Duration -Indent 1
                    Write-SAProgress -Label "Path" -Text $importPath -Indent 2
                    Add-SAEmailException -Message $msg -Type Error
                }
            }
        }
    }
    
    # Build result object - skipped (same quality/size) or partial are treated as success
    $isPartial = $pollResult.Status -eq 'partial'
    $result = [PSCustomObject]@{
        Success = $pollResult.Success -or $isSkipped
        Message = $pollResult.Message
        Duration = $pollResult.Duration
    }
    
    if ($isSkipped) {
        $result | Add-Member -NotePropertyName 'Skipped' -NotePropertyValue $true
        $result.Message = $skipReason
    }
    
    if ($isPartial) {
        # Transfer all partial import properties from pollResult
        $result | Add-Member -NotePropertyName 'Status' -NotePropertyValue 'partial'
        $result | Add-Member -NotePropertyName 'ImportedCount' -NotePropertyValue $pollResult.ImportedCount
        $result | Add-Member -NotePropertyName 'SkippedCount' -NotePropertyValue $pollResult.SkippedCount
        $result | Add-Member -NotePropertyName 'AbortedCount' -NotePropertyValue $pollResult.AbortedCount
        $result | Add-Member -NotePropertyName 'SkipReason' -NotePropertyValue $pollResult.SkipReason
        $result | Add-Member -NotePropertyName 'AbortReason' -NotePropertyValue $pollResult.AbortReason
    }
    
    # Always transfer file detail arrays if available (for Phase 4 email enhancement)
    if ($pollResult.ImportedFiles) {
        $result | Add-Member -NotePropertyName 'ImportedFiles' -NotePropertyValue $pollResult.ImportedFiles
    }
    if ($pollResult.SkippedFiles) {
        $result | Add-Member -NotePropertyName 'SkippedFiles' -NotePropertyValue $pollResult.SkippedFiles
    }
    if ($pollResult.AbortedFiles) {
        $result | Add-Member -NotePropertyName 'AbortedFiles' -NotePropertyValue $pollResult.AbortedFiles
    }
    
    return $result
}

#endregion

#region Medusa Queue Polling

function Wait-SAMedusaQueue {
    <#
    .SYNOPSIS
        Polls for Medusa queue item completion.
    .DESCRIPTION
        Polls /api/v2/postprocess/{queueId} until the job completes.
        
        Medusa API response fields:
        - success: null (while running), true/false (when done)
        - inProgress: true (while running), false (when done)
        - output: array of log messages
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$QueueId,
        
        [Parameter()]
        [int]$TimeoutMinutes = 10,
        
        [Parameter()]
        [int]$PollIntervalSeconds = 5
    )
    
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $uri = "$($urlInfo.Url)/api/v2/postprocess/$QueueId"
    
    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddMinutes($TimeoutMinutes)
    
    while ((Get-Date) -lt $timeoutTime) {
        Start-Sleep -Seconds $PollIntervalSeconds
        
        $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers
        
        if (-not $result.Success) {
            continue
        }
        
        # Medusa uses: success (null/true/false), inProgress (true/false), output (array)
        $success = $result.Data.success
        $inProgress = $result.Data.inProgress
        $output = $result.Data.output
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        
        Write-SAVerbose -Text "Attempt: inProgress=$inProgress, success=$success"
        
        # Check if job is still running
        if ($inProgress -eq $true -or $null -eq $success) {
            # Still running - show heartbeat
            Write-SAPollingStatus -Status 'Processing' -ElapsedSeconds $elapsed
            continue
        }
        
        # Job completed - parse output using ImportResultParser
        $parsed = ConvertFrom-SAMedusaOutput -Output $output -ApiSuccess $success
        
        # Add duration (not known by parser)
        $parsed | Add-Member -NotePropertyName 'Duration' -NotePropertyValue $elapsed -Force
        
        # Verbose logging for debugging
        if ($parsed.ImportedCount -or $parsed.SkippedCount -or $parsed.AbortedCount) {
            Write-SAVerbose -Text "Medusa results: $($parsed.ImportedCount) succeeded, $($parsed.SkippedCount) skipped, $($parsed.AbortedCount) aborted of $($parsed.TotalCount) files"
        }
        if ($parsed.AbortReason) {
            Write-SAVerbose -Text "Abort reason: $($parsed.AbortReason)"
        }
        if ($parsed.SkipReason) {
            Write-SAVerbose -Text "Skip reason: $($parsed.SkipReason)"
        }
        
        return $parsed
    }
    
    # Timeout
    $duration = [int]((Get-Date) - $startTime).TotalSeconds
    return [PSCustomObject]@{
        Success  = $false
        Status   = 'timeout'
        Message  = "Import timed out after $TimeoutMinutes minutes"
        Duration = $duration
    }
}

#endregion

#region Medusa Connection Test

function Test-SAMedusaConnection {
    <#
    .SYNOPSIS
        Tests connection to Medusa API.
    .DESCRIPTION
        Attempts to connect to Medusa's config endpoint to verify
        API accessibility and authentication.
    .PARAMETER Config
        Medusa configuration hashtable (host, port, apiKey, etc.).
    .OUTPUTS
        Boolean indicating connection success.
    .EXAMPLE
        $connected = Test-SAMedusaConnection -Config $config.importers.medusa
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $uri = "$($urlInfo.Url)/api/v2/config/main"
    
    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    
    # Add Host header for reverse proxy compatibility
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }
    
    Write-SAVerbose -Text "Testing Medusa connection..."
    
    # Use shorter timeout for connection test
    $timeout = $script:SAConstants.ConnectionTestTimeoutSeconds
    $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -MaxRetries 1 -TimeoutSeconds $timeout
    
    if ($result.Success) {
        Write-SAVerbose -Text "Medusa connection OK"
    } else {
        Write-SAVerbose -Text "Medusa connection failed: $($result.ErrorMessage)"
    }
    
    return $result.Success
}

#endregion
