#Requires -Version 5.1
<#
.SYNOPSIS
    Staging operations for Stagearr
.DESCRIPTION
    Handles file staging with optimized disk write strategy:
    - RAR: Extract to staging (unavoidable)
    - MP4: Remux directly from source to staging as MKV
    - MKV: Process from source, write to staging
    - Minimizes unnecessary copies
#>

function Test-SARobocopySuccess {
    <#
    .SYNOPSIS
        Tests if a robocopy exit code indicates success.
    .DESCRIPTION
        Robocopy uses non-standard exit codes:
        - 0-7: Success or warnings (files copied, extra files, etc.)
        - 8+:  Errors occurred
    .PARAMETER ExitCode
        The exit code from robocopy.
    .OUTPUTS
        $true if successful, $false if error.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )
    
    return $ExitCode -le 7
}

function Initialize-SAStagingFolder {
    <#
    .SYNOPSIS
        Creates and initializes the staging folder for a job.
    .PARAMETER Context
        Processing context.
    .OUTPUTS
        Path to the staging folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    $stagingPath = $Context.State.StagingPath
    
    # SECURITY: Validate path is within staging root before any recursive operations
    Assert-SAPathUnderRoot -Path $stagingPath -Root $Context.Paths.StagingRoot
    
    # Clean existing staging folder if present
    if (Test-Path -LiteralPath $stagingPath) {
        Write-SAVerbose -Text "Cleaning existing staging folder"
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Create fresh staging folder
    New-SADirectory -Path $stagingPath
    
    Write-SAVerbose -Text "Staging: $stagingPath"
    
    return $stagingPath
}

function Copy-SASingleFile {
    <#
    .SYNOPSIS
        Copies a single file to destination.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory = $true)]
        [string]$DestinationFolder
    )
    
    $fileName = Split-Path -Path $SourcePath -Leaf
    $destPath = Join-Path -Path $DestinationFolder -ChildPath $fileName
    
    Write-SAVerbose -Text "Copying: $fileName"
    
    try {
        $sourceFile = Get-Item -LiteralPath $SourcePath
        $sourceSize = $sourceFile.Length
        
        # Show progress before copy operation
        Write-SAProgress -Label "Copying" -Text "to staging..." -Indent 2 -ConsoleOnly
        
        # For large files (>100MB), use robocopy for resume support
        if ($sourceSize -gt 100MB) {
            $sourceDir = Split-Path -Path $SourcePath -Parent
            
            # Use retry for transient failures
            $result = Invoke-SAProcessWithRetry -FilePath 'robocopy' `
                -ArgumentList @(
                    $sourceDir,
                    $DestinationFolder,
                    $fileName,
                    '/R:3', '/W:5', '/NP', '/NDL', '/NJH', '/NJS'
                ) `
                -MaxRetries 2 `
                -RetryDelaySeconds 5
            
            if (Test-SARobocopySuccess -ExitCode $result.ExitCode) {
                Write-SAOutcome -Level Success -Label "Copied" -Text $fileName -Indent 2 -ConsoleOnly
                return $true
            } else {
                Write-SAToolError -Label "Copy" `
                    -ToolName 'robocopy' `
                    -ExitCode $result.ExitCode `
                    -ErrorMessage $result.StdErr `
                    -FilePath $SourcePath
                return $false
            }
        } else {
            # Small file, use Copy-Item
            Copy-Item -LiteralPath $SourcePath -Destination $destPath -Force
            Write-SAOutcome -Level Success -Label "Copied" -Text $fileName -Indent 2 -ConsoleOnly
            return $true
        }
    } catch {
        # Translate exception to user-friendly message
        $errorInfo = Get-SAToolErrorInfo -ToolName 'Copy-Item' `
            -ExitCode -1 `
            -ErrorMessage $_.Exception.Message `
            -FilePath $SourcePath
        
        Write-SAOutcome -Level Error -Label "Copy" -Text $errorInfo.Problem -Indent 2
        Write-SAProgress -Label "Reason" -Text $errorInfo.Reason -Indent 2
        return $false
    }
}

function Remove-SAStagingFolder {
    <#
    .SYNOPSIS
        Removes the staging folder after processing.
    .PARAMETER Context
        Processing context.
    .PARAMETER Force
        Remove even if NoCleanup flag is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter()]
        [switch]$Force
    )
    
    if (-not $Force -and $Context.Flags.NoCleanup) {
        Write-SAProgress -Label "Cleanup" -Text "Skipped (NoCleanup flag)" -Indent 1
        return
    }
    
    $stagingPath = $Context.State.StagingPath
    
    if (-not $stagingPath -or -not (Test-Path -LiteralPath $stagingPath)) {
        Write-SAProgress -Label "Cleanup" -Text "Skipped (no staging folder)" -Indent 1
        return
    }
    
    try {
        # SECURITY: Validate path is within staging root before recursive delete
        Assert-SAPathUnderRoot -Path $stagingPath -Root $Context.Paths.StagingRoot
        
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction Stop
        Write-SAOutcome -Level Success -Label "Cleanup" -Text "Staging folder removed" -Indent 1
    } catch {
        Write-SAOutcome -Level Warning -Label "Cleanup" -Text "Failed to remove staging: $($_.Exception.Message)" -Indent 1
    }
}

function Get-SASourceMediaFiles {
    <#
    .SYNOPSIS
        Analyzes source path and returns media file information.
    .DESCRIPTION
        Determines what processing is needed for each media file:
        - RAR files needing extraction
        - MP4 files needing remux
        - MKV files needing analysis
    .PARAMETER Context
        Processing context.
    .OUTPUTS
        Array of media file analysis objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    $sourcePath = $Context.State.SourcePath
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    # Check for RAR files
    if ($Context.State.IsRarArchive) {
        # Find the main RAR file
        if ($Context.State.IsSingleFile) {
            $rarFile = Get-Item -LiteralPath $sourcePath
        } else {
            # Find first .rar in folder (part01.rar or just .rar)
            $rarFiles = Get-ChildItem -LiteralPath $sourcePath -Filter '*.rar' -Recurse |
                Where-Object { $_.Name -notmatch '\.part(?!01)\d+\.rar$' } |
                Sort-Object Name |
                Select-Object -First 1
            $rarFile = $rarFiles
        }
        
        if ($rarFile) {
            $results.Add([PSCustomObject]@{
                Type        = 'RAR'
                SourcePath  = $rarFile.FullName
                FileName    = $rarFile.Name
                Size        = $rarFile.Length
                NeedsUnrar  = $true
                NeedsRemux  = $false
                NeedsAnalysis = $false
            })
        }
        
        return $results.ToArray()
    }
    
    # Get video files
    $videoFiles = Get-SAVideoFiles -Path $sourcePath -Recurse:($Context.State.IsFolder)
    
    foreach ($file in $videoFiles) {
        $isMP4 = Test-SAIsMP4 -Path $file.FullName
        $isMKV = Test-SAIsMKV -Path $file.FullName
        
        $results.Add([PSCustomObject]@{
            Type          = if ($isMP4) { 'MP4' } elseif ($isMKV) { 'MKV' } else { 'Other' }
            SourcePath    = $file.FullName
            FileName      = $file.Name
            Size          = $file.Length
            NeedsUnrar    = $false
            NeedsRemux    = $isMP4  # MP4 always needs remux to MKV
            NeedsAnalysis = $isMKV  # MKV needs track analysis
        })
    }
    
    return $results.ToArray()
}

function Invoke-SAProcessMediaFile {
    <#
    .SYNOPSIS
        Processes a single media file with the optimal strategy.
    .DESCRIPTION
        Applies the disk-optimized processing:
        - MP4: Direct remux from source to staging (if Mp4Remux enabled), otherwise copy
        - MKV: Analyze, then strip/extract as needed from source (based on feature flags)
    .PARAMETER Context
        Processing context.
    .PARAMETER MediaFile
        Media file object from Get-SASourceMediaFiles.
    .OUTPUTS
        Processing result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$MediaFile
    )
    
    $stagingPath = $Context.State.StagingPath
    $config = $Context.Config
    
    switch ($MediaFile.Type) {
        'MP4' {
            # Compute OpenSubtitles hash BEFORE remuxing (hash changes after mux)
            $openSubsHash = $null
            try {
                $openSubsHash = Get-SAVideoHash -Path $MediaFile.SourcePath
                Write-SAVerbose -Text "MP4 hash for OpenSubtitles: $openSubsHash"
            } catch {
                Write-SAVerbose -Text "Could not compute hash for MP4: $_"
            }
            
            # Check if MP4 remuxing is enabled
            if (Test-SAFeatureEnabled -Config $config -Feature 'Mp4Remux') {
                # Direct remux from source to staging
                $outputName = Get-SAOutputFileName -SourcePath $MediaFile.SourcePath -NewExtension '.mkv'
                $outputPath = Join-Path -Path $stagingPath -ChildPath $outputName
                
                $success = Start-SARemuxMP4 -Context $Context `
                    -SourcePath $MediaFile.SourcePath `
                    -OutputPath $outputPath
                
                return [PSCustomObject]@{
                    Success       = $success
                    OutputPath    = $outputPath
                    Type          = 'Remux'
                    ExtractedSrts = @()
                    OpenSubsHash  = $openSubsHash
                }
            }
            else {
                # Mp4Remux disabled - copy MP4 as-is
                Write-SAVerbose -Text "MP4 remux disabled - copying file as-is"
                $destPath = Join-Path -Path $stagingPath -ChildPath $MediaFile.FileName
                Copy-Item -LiteralPath $MediaFile.SourcePath -Destination $destPath -Force
                
                return [PSCustomObject]@{
                    Success       = $true
                    OutputPath    = $destPath
                    Type          = 'Copy'
                    ExtractedSrts = @()
                    OpenSubsHash  = $openSubsHash
                }
            }
        }
        
        'MKV' {
            # Analyze and process MKV
            $result = Invoke-SAProcessMkv -Context $Context `
                -SourcePath $MediaFile.SourcePath `
                -StagingPath $stagingPath
            
            return $result
        }
        
        'Other' {
            # Copy other video files as-is
            Write-SAProgress -Label "Copy" -Text $MediaFile.FileName
            $destPath = Join-Path -Path $stagingPath -ChildPath $MediaFile.FileName
            Copy-Item -LiteralPath $MediaFile.SourcePath -Destination $destPath -Force
            
            # Compute hash for OpenSubtitles (can use copied file)
            $openSubsHash = $null
            try {
                $openSubsHash = Get-SAVideoHash -Path $destPath
            } catch {
                Write-SAVerbose -Text "Could not compute hash: $_"
            }
            
            return [PSCustomObject]@{
                Success       = $true
                OutputPath    = $destPath
                Type          = 'Copy'
                ExtractedSrts = @()
                OpenSubsHash  = $openSubsHash
            }
        }
    }
}

function Invoke-SAProcessMkv {
    <#
    .SYNOPSIS
        Processes an MKV file: analyze, extract SRTs, strip unwanted subs.
    .DESCRIPTION
        Implements the optimized MKV processing:
        1. Analyze tracks with mkvmerge -J
        2. Extract wanted text subtitles to staging (if SubtitleExtraction enabled)
        3. If unwanted subs exist, remux with strip from source (if SubtitleStripping enabled)
        4. If no changes needed, copy from source
    .PARAMETER Context
        Processing context.
    .PARAMETER SourcePath
        Path to source MKV file.
    .PARAMETER StagingPath
        Path to staging folder.
    .OUTPUTS
        Processing result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingPath
    )
    
    $config = $Context.Config
    $fileName = Split-Path -Path $SourcePath -Leaf
    $fileSize = (Get-Item -LiteralPath $SourcePath).Length
    
    # Check feature flags once at the start
    $extractionEnabled = Test-SAFeatureEnabled -Config $config -Feature 'SubtitleExtraction'
    $strippingEnabled = Test-SAFeatureEnabled -Config $config -Feature 'SubtitleStripping'
    $openSubsEnabled = Test-SAFeatureEnabled -Config $config -Feature 'OpenSubtitles'
    
    # Show Staging header only for first file (batch processing deduplication)
    $fileIndex = $Context.State.VideoFileIndex
    $fileCount = $Context.State.VideoFileCount
    $isBatch = $fileCount -gt 1
    
    if ($fileIndex -eq 0) {
        # First file - show header with count if batch
        if ($isBatch) {
            Write-SAPhaseHeader -Title "Staging" -FileCount $fileCount
        } else {
            Write-SAPhaseHeader -Title "Staging"
        }
    }
    
    # Show source file with [n/N] suffix for batch mode (DRY - same pattern for both)
    # Per OUTPUT-STYLE-GUIDE.md: "Source: filename.mkv (size) [n/N]"
    $sourceText = "$fileName ($(Format-SASize $fileSize))"
    if ($isBatch) {
        $displayIndex = $fileIndex + 1  # Convert to 1-based
        $sourceText += " [$displayIndex/$fileCount]"
    }
    Write-SAProgress -Label "Source" -Text $sourceText -Indent 1 -ConsoleOnly
    
    # File details always use Indent 2 (4 spaces) - identical structure for batch and single
    
    # Step 1: Analyze MKV - only compute hash if OpenSubtitles is enabled (saves I/O)
    $mkvInfo = Get-SAMkvInfo -Path $SourcePath -MkvMergePath $Context.Tools.MkvMerge -ComputeHash $openSubsEnabled
    
    # Show "OpenSubtitles disabled" verbose only once per batch (not per file)
    if (-not $openSubsEnabled -and -not $Context.State.OpenSubsDisabledMsgShown) {
        Write-SAVerbose -Text "OpenSubtitles disabled - skipping hash computation"
        $Context.State.OpenSubsDisabledMsgShown = $true
    }
    
    if ($null -eq $mkvInfo) {
        Write-SAOutcome -Level Error -Label "Analyze" -Text "Failed to analyze MKV" -Indent 2
        return [PSCustomObject]@{
            Success      = $false
            OutputPath   = $null
            Type         = 'Error'
            OpenSubsHash = $null
        }
    }
    
    # Show track summary in normal output (with proper pluralization per style guide)
    # Note: "video" and "audio" are track type labels that stay singular
    # Only "subtitle/subtitles" gets pluralized
    $subWord = Get-SAPluralForm -Count $mkvInfo.SubtitleCount -Singular 'subtitle'
    $trackSummary = "$($mkvInfo.VideoTracks.Count) video, $($mkvInfo.AudioTracks.Count) audio, $($mkvInfo.SubtitleCount) $subWord"
    Write-SAProgress -Label "Tracks" -Text $trackSummary -Indent 2 -ConsoleOnly
    
    # Step 2: Analyze subtitles (needed for both extraction and stripping decisions)
    $subAnalysis = $null
    $extractedSrts = @()
    
    if ($extractionEnabled -or $strippingEnabled) {
        $dupMode = if ($config.subtitles.extraction.duplicateLanguageMode) { $config.subtitles.extraction.duplicateLanguageMode } else { 'all' }
        $subAnalysis = Get-SAMkvSubtitleAnalysis -MkvInfo $mkvInfo `
            -WantedLanguages $config.subtitles.wantedLanguages `
            -RemovePatterns $config.subtitles.namePatternsToRemove `
            -DuplicateLanguageMode $dupMode
        
        # Step 3: Extract text subtitles (from source) - only if extraction enabled
        if ($extractionEnabled -and $subAnalysis.HasExtractable) {
            $trackWord = Get-SAPluralForm -Count $subAnalysis.ExtractableTracks.Count -Singular 'track'
            Write-SAProgress -Label "Extracting" -Text "$($subAnalysis.ExtractableTracks.Count) subtitle $trackWord..." -Indent 2 -ConsoleOnly
            
            $extractedSrts = Start-SAExtractSubtitles -Context $Context `
                -SourcePath $SourcePath `
                -OutputFolder $StagingPath `
                -Analysis $subAnalysis
            
            $Context.Results.SubtitlesExtracted += $extractedSrts.Count
        }
        elseif (-not $extractionEnabled -and $subAnalysis.HasExtractable) {
            Write-SAVerbose -Text "Subtitle extraction disabled - skipping $($subAnalysis.ExtractableTracks.Count) extractable tracks"
        }
    }
    else {
        # Show "both disabled" verbose only once per batch (not per file)
        if (-not $Context.State.SubtitlesBothDisabledMsgShown) {
            Write-SAVerbose -Text "Subtitle extraction and stripping both disabled - skipping subtitle analysis"
            $Context.State.SubtitlesBothDisabledMsgShown = $true
        }
    }
    
    # Step 4: Determine MKV handling
    $outputName = Split-Path -Path $SourcePath -Leaf
    $outputPath = Join-Path -Path $StagingPath -ChildPath $outputName
    
    # Only strip if stripping is enabled AND there are unwanted tracks
    $shouldStrip = $strippingEnabled -and $subAnalysis -and $subAnalysis.NeedsStrip
    
    if ($shouldStrip) {
        # Show what we're doing before the long operation
        $trackWord = Get-SAPluralForm -Count $subAnalysis.UnwantedTracks.Count -Singular 'track'
        Write-SAProgress -Label "Remuxing" -Text "Removing $($subAnalysis.UnwantedTracks.Count) unwanted subtitle $trackWord..." -Indent 2 -ConsoleOnly
        
        # Remux with subtitle strip (read from source, write to staging)
        $success = Start-SAMkvRemux -Context $Context `
            -SourcePath $SourcePath `
            -OutputPath $outputPath `
            -KeepSubtitleIds $subAnalysis.WantedTrackIds
        
        if ($success) {
            $Context.Results.SubtitlesRemoved += $subAnalysis.UnwantedTracks.Count
            $trackWord = Get-SAPluralForm -Count $subAnalysis.UnwantedTracks.Count -Singular 'subtitle'
            # Per-file outcome at indent 2 (aligns with file details)
            Write-SAOutcome -Level Success -Label "Removed" -Text "$($subAnalysis.UnwantedTracks.Count) unwanted $trackWord" -Indent 2 -ConsoleOnly
        } else {
            Write-SAOutcome -Level Error -Label "Strip" -Text "Failed to remux MKV" -Indent 2 -ConsoleOnly
        }
        
        return [PSCustomObject]@{
            Success       = $success
            OutputPath    = $outputPath
            Type          = 'Strip'
            ExtractedSrts = $extractedSrts
            OpenSubsHash  = $mkvInfo.OpenSubsHash
        }
    } else {
        # Log why we're not stripping (verbose only)
        if (-not $strippingEnabled -and $subAnalysis -and $subAnalysis.NeedsStrip) {
            Write-SAVerbose -Text "Subtitle stripping disabled - keeping $($subAnalysis.UnwantedTracks.Count) unwanted tracks"
        }
        
        # No strip needed - just copy
        $success = Copy-SASingleFile -SourcePath $SourcePath -DestinationFolder $StagingPath
        
        return [PSCustomObject]@{
            Success       = $success
            OutputPath    = $outputPath
            Type          = 'Copy'
            ExtractedSrts = $extractedSrts
            OpenSubsHash  = $mkvInfo.OpenSubsHash
        }
    }
}