#Requires -Version 5.1
<#
.SYNOPSIS
    Video file processing and orchestration for Stagearr.
.DESCRIPTION
    Functions for video file manipulation:
    - MP4 to MKV remuxing
    - MKV track selection and remuxing
    - Subtitle track extraction
    - Processing pipeline orchestration
    
    Requires: MKVToolNix (mkvmerge, mkvextract) for MKV operations
    
    Depends on: RarExtraction.ps1 (for archive handling)
#>

function Start-SARemuxMP4 {
    <#
    .SYNOPSIS
        Remuxes MP4/M4V to MKV container.
    .DESCRIPTION
        Uses mkvmerge to remux MP4 content into MKV container.
        Reads directly from source, writes to output path.
    .PARAMETER Context
        Processing context.
    .PARAMETER SourcePath
        Path to source MP4 file.
    .PARAMETER OutputPath
        Path for output MKV file.
    .OUTPUTS
        $true if successful, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )
    
    $mkvmerge = $Context.Tools.MkvMerge
    $fileName = Split-Path -Path $SourcePath -Leaf
    $sourceSize = (Get-Item -LiteralPath $SourcePath).Length
    
    Write-SAProgress -Label "Remux" -Text "$fileName -> MKV ($(Format-SASize $sourceSize))" -Indent 2
    
    # Ensure output directory exists
    $outputDir = Split-Path -Path $OutputPath -Parent
    New-SADirectory -Path $outputDir
    
    # Build mkvmerge command
    $processArgs = @(
        '-o', $OutputPath,
        '--no-global-tags',
        '--no-track-tags',
        $SourcePath
    )
    
    $result = Invoke-SAProcess -FilePath $mkvmerge -ArgumentList $processArgs
    
    # mkvmerge: 0 = success, 1 = warnings (still success), 2+ = error
    if (Test-SAProcessResult -Result $result -ToolName 'mkvmerge' -Label 'Remux' -FilePath $SourcePath -SuccessCodes @(1)) {
        $outputItem = Get-Item -LiteralPath $OutputPath -ErrorAction SilentlyContinue
        $outputSize = if ($null -ne $outputItem) { $outputItem.Length } else { 0 }

        if ($outputSize -eq 0) {
            Write-SAOutcome -Level Error -Label "Remux" -Text "Output file is empty or missing" -Indent 2
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
            return $false
        }

        Write-SAOutcome -Level Success -Label "Remux" -Text "Complete ($(Format-SASize $outputSize))" -Indent 2

        $Context.Results.FilesRemuxed++
        return $true
    } else {
        return $false
    }
}

function Start-SAMkvRemux {
    <#
    .SYNOPSIS
        Remuxes MKV with selective subtitle tracks.
    .DESCRIPTION
        Uses mkvmerge to create a new MKV with only specified subtitle tracks.
        Reads directly from source, writes to output path.
    .PARAMETER Context
        Processing context.
    .PARAMETER SourcePath
        Path to source MKV file.
    .PARAMETER OutputPath
        Path for output MKV file.
    .PARAMETER KeepSubtitleIds
        Array of subtitle track IDs to keep (all others removed).
    .PARAMETER RemoveAllSubtitles
        Remove all subtitle tracks.
    .OUTPUTS
        $true if successful, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [Parameter()]
        [int[]]$KeepSubtitleIds = @(),
        
        [Parameter()]
        [switch]$RemoveAllSubtitles
    )
    
    $mkvmerge = $Context.Tools.MkvMerge
    
    # Ensure output directory exists
    $outputDir = Split-Path -Path $OutputPath -Parent
    New-SADirectory -Path $outputDir
    
    # Build mkvmerge arguments
    $processArgs = [System.Collections.Generic.List[string]]::new()
    $processArgs.Add('-o')
    $processArgs.Add($OutputPath)
    
    # Handle subtitle selection
    if ($RemoveAllSubtitles) {
        $processArgs.Add('--no-subtitles')
    } elseif ($KeepSubtitleIds.Count -gt 0) {
        # -s trackid1,trackid2 keeps only these subtitle tracks
        $processArgs.Add('-s')
        $processArgs.Add($KeepSubtitleIds -join ',')
    }
    
    # Strip tags for cleaner output
    $processArgs.Add('--no-global-tags')
    $processArgs.Add('--no-track-tags')
    
    # Source file
    $processArgs.Add($SourcePath)
    
    $result = Invoke-SAProcess -FilePath $mkvmerge -ArgumentList $processArgs.ToArray()
    
    # mkvmerge: 0 = success, 1 = warnings (still success), 2+ = error
    if (Test-SAProcessResult -Result $result -ToolName 'mkvmerge' -Label 'Remux' -FilePath $SourcePath -SuccessCodes @(1)) {
        return $true
    } else {
        return $false
    }
}

function Start-SAExtractSubtitles {
    <#
    .SYNOPSIS
        Extracts subtitle tracks from MKV to SRT files.
    .DESCRIPTION
        Uses mkvextract to extract text subtitle tracks.
        Reads from source, writes SRTs to output folder.
    .PARAMETER Context
        Processing context.
    .PARAMETER SourcePath
        Path to source MKV file.
    .PARAMETER OutputFolder
        Folder for extracted SRT files.
    .PARAMETER Analysis
        Subtitle analysis object from Get-SAMkvSubtitleAnalysis.
    .OUTPUTS
        Array of extracted SRT file paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Analysis
    )
    
    $mkvextract = $Context.Tools.MkvExtract
    $extractedFiles = [System.Collections.Generic.List[string]]::new()
    
    if ($Analysis.ExtractableTracks.Count -eq 0) {
        return @()
    }
    
    $trackWord = Get-SAPluralForm -Count $Analysis.ExtractableTracks.Count -Singular 'track'
    Write-SAVerbose -Text "Extracting $($Analysis.ExtractableTracks.Count) subtitle $trackWord"
    
    # Ensure output folder exists
    New-SADirectory -Path $OutputFolder
    
    # Group tracks by language to handle duplicates
    $langCounts = @{}
    
    # Build extraction arguments
    # mkvextract tracks source.mkv trackid:output.srt trackid2:output2.srt
    $processArgs = [System.Collections.Generic.List[string]]::new()
    $processArgs.Add('tracks')
    $processArgs.Add($SourcePath)
    
    foreach ($trackResult in $Analysis.ExtractableTracks) {
        $track = $trackResult.Track
        $lang = $trackResult.NormalizedLanguage
        
        if ([string]::IsNullOrWhiteSpace($lang)) {
            $lang = 'und'
        }
        
        # Track duplicate languages
        if (-not $langCounts.ContainsKey($lang)) {
            $langCounts[$lang] = 0
        }
        $langCounts[$lang]++
        
        # Generate output filename
        $srtName = Get-SASrtFileName -VideoPath $SourcePath -LanguageCode $lang -TrackIndex ($langCounts[$lang] - 1)
        
        # Don't add index suffix for first track of each language
        if ($langCounts[$lang] -eq 1) {
            $srtName = Get-SASrtFileName -VideoPath $SourcePath -LanguageCode $lang
        }
        
        $srtPath = Join-Path -Path $OutputFolder -ChildPath $srtName
        
        # Pass as raw argument - escaping is handled by Invoke-SAProcess
        $processArgs.Add("$($track.Id):$srtPath")
        $extractedFiles.Add($srtPath)
        
        Write-SAVerbose -Text "Track $($track.Id): $srtName ($lang)"
    }
    
    # Run extraction
    $result = Invoke-SAProcess -FilePath $mkvextract -ArgumentList $processArgs.ToArray()
    
    # mkvextract: 0 = success, 1 = warnings (still success), 2+ = error
    if (Test-SAProcessResult -Result $result -ToolName 'mkvextract' -Label 'Extract' -FilePath $SourcePath -SuccessCodes @(1) -LogError $false) {
        # Verify files were created
        $actualExtracted = [System.Collections.Generic.List[string]]::new()
        foreach ($srtPath in $extractedFiles) {
            if (Test-Path -LiteralPath $srtPath) {
                $actualExtracted.Add($srtPath)
            }
        }
        
        # Build language list for output (e.g., "English, Dutch" or "English (2), Dutch")
        $extractedLangs = @{}
        foreach ($srt in $actualExtracted) {
            $srtName = Split-Path -Path $srt -Leaf
            if ($srtName -match '\.([a-z]{2})(?:\.\d+)?\.srt$') {
                $langCode = $Matches[1]
                $langInfo = Get-SALanguageInfo -Code $langCode
                $langName = if ($langInfo -and $langInfo.name) { $langInfo.name } else { $langCode.ToUpper() }
                if (-not $extractedLangs.ContainsKey($langName)) {
                    $extractedLangs[$langName] = 0
                }
                $extractedLangs[$langName]++
            }
        }
        
        $langDisplay = ($extractedLangs.Keys | Sort-Object | ForEach-Object {
            $count = $extractedLangs[$_]
            if ($count -gt 1) { "$_ ($count)" } else { $_ }
        }) -join ', '
        
        if ([string]::IsNullOrWhiteSpace($langDisplay)) {
            $langDisplay = "$($actualExtracted.Count) $(Get-SAPluralForm -Count $actualExtracted.Count -Singular 'track')"
        }
        
        # Log to console only - Subtitles section will summarize in HTML
        Write-SAOutcome -Level Success -Label "Extracted" -Text $langDisplay -Indent 2 -ConsoleOnly
        return $actualExtracted.ToArray()
    } else {
        # Log error with user-friendly message
        Write-SAToolError -Label "Extract" `
            -ToolName 'mkvextract' `
            -ExitCode $result.ExitCode `
            -ErrorMessage $result.StdErr `
            -FilePath $SourcePath
        return @()
    }
}

function Invoke-SAVideoProcessing {
    <#
    .SYNOPSIS
        Main entry point for video processing pipeline.
    .DESCRIPTION
        Orchestrates the complete video processing:
        1. Analyze source (RAR/MP4/MKV detection)
        2. Extract RAR if needed
        3. Process video files (remux/strip/extract)
    .PARAMETER Context
        Processing context.
    .OUTPUTS
        Processing result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    $stagingPath = $Context.State.StagingPath
    
    # Initialize staging
    Initialize-SAStagingFolder -Context $Context
    
    # Get media files info (wrap in @() for PS5.1 compatibility)
    $mediaFiles = @(Get-SASourceMediaFiles -Context $Context)
    
    if ($mediaFiles.Count -eq 0) {
        Write-SAOutcome -Level Warning -Label "Staging" -Text "No media files found" -Indent 1
        return [PSCustomObject]@{
            Success        = $false
            Reason         = 'NoMediaFiles'
            ProcessedFiles = @()
            TotalSize      = 0
        }
    }
    
    $fileWord = Get-SAPluralForm -Count $mediaFiles.Count -Singular 'file'
    Write-SAVerbose -Text "Video: $($mediaFiles.Count) $fileWord to process"
    
    # Track batch processing state for header deduplication
    $Context.State.VideoFileCount = $mediaFiles.Count
    $Context.State.VideoFileIndex = 0
    
    $processedFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
    $allSuccess = $true
    
    foreach ($mediaFile in $mediaFiles) {
        
        if ($mediaFile.NeedsUnrar) {
            # Extract RAR first (header is added in Start-SAUnrar)
            $success = Start-SAUnrar -Context $Context `
                -RarPath $mediaFile.SourcePath `
                -OutputFolder $stagingPath
            
            if (-not $success) {
                $allSuccess = $false
                continue
            }
            
            # After extraction, find and process video files in staging
            $extractedVideos = Get-SAVideoFiles -Path $stagingPath -Recurse
            
            # Update file count for extracted videos
            $Context.State.VideoFileCount = $extractedVideos.Count
            $Context.State.VideoFileIndex = 0
            
            foreach ($video in $extractedVideos) {
                $videoInfo = [PSCustomObject]@{
                    Type          = if (Test-SAIsMP4 -Path $video.FullName) { 'MP4' } else { 'MKV' }
                    SourcePath    = $video.FullName
                    FileName      = $video.Name
                    Size          = $video.Length
                    NeedsUnrar    = $false
                    NeedsRemux    = (Test-SAIsMP4 -Path $video.FullName)
                    NeedsAnalysis = (Test-SAIsMKV -Path $video.FullName)
                }
                
                # For extracted files, source IS in staging, so we process in-place
                $result = Invoke-SAProcessExtractedFile -Context $Context -MediaFile $videoInfo
                $processedFiles.Add($result)
                
                # Increment file index after processing
                $Context.State.VideoFileIndex++
                
                if (-not $result.Success) {
                    $allSuccess = $false
                }
            }
        } else {
            # Process directly from source
            $result = Invoke-SAProcessMediaFile -Context $Context -MediaFile $mediaFile
            $processedFiles.Add($result)
            
            # Increment file index after processing
            $Context.State.VideoFileIndex++
            
            if (-not $result.Success) {
                $allSuccess = $false
            }
        }
    }
    
    # Summary
    if ($processedFiles.Count -eq 0) {
        # No files processed - this is a failure
        Write-SAOutcome -Level Warning -Label "Staging" -Text "No files ready" -Indent 1
        $allSuccess = $false
    } elseif ($allSuccess) {
        $fileWord = Get-SAPluralForm -Count $processedFiles.Count -Singular 'file'
        
        # C6 fix: Calculate total size for staging summary per OUTPUT-STYLE-GUIDE
        # E4 fix: Store size for email summary (files deleted before email generation)
        $totalSize = 0
        foreach ($pf in $processedFiles) {
            if ($pf.OutputPath -and (Test-Path -LiteralPath $pf.OutputPath -ErrorAction SilentlyContinue)) {
                $totalSize += (Get-Item -LiteralPath $pf.OutputPath -ErrorAction SilentlyContinue).Length
            }
        }
        
        if ($totalSize -gt 0) {
            $sizeDisplay = Format-SASize $totalSize
            Write-SAOutcome -Level Success -Label "Staging" -Text "$($processedFiles.Count) $fileWord ready ($sizeDisplay)" -Indent 1
        } else {
            Write-SAOutcome -Level Success -Label "Staging" -Text "$($processedFiles.Count) $fileWord ready" -Indent 1
        }
    } else {
        Write-SAOutcome -Level Warning -Label "Staging" -Text "Some files had errors" -Indent 1
    }
    
    return [PSCustomObject]@{
        Success        = $allSuccess
        ProcessedFiles = $processedFiles.ToArray()
        StagingPath    = $stagingPath
        TotalSize      = $totalSize  # E4 fix: Return size for email summary
    }
}

function Invoke-SAProcessExtractedFile {
    <#
    .SYNOPSIS
        Processes a file that was extracted from RAR (already in staging).
    .DESCRIPTION
        For extracted files, the source is already in staging, so we process in-place.
        MP4 remuxing is conditional on the Mp4Remux feature flag.
    .PARAMETER Context
        Processing context.
    .PARAMETER MediaFile
        Media file object.
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
                # Remux in-place (to temp file, then replace)
                $outputName = Get-SAOutputFileName -SourcePath $MediaFile.SourcePath -NewExtension '.mkv'
                $outputPath = Join-Path -Path (Split-Path -Path $MediaFile.SourcePath -Parent) -ChildPath $outputName
                
                $success = Start-SARemuxMP4 -Context $Context `
                    -SourcePath $MediaFile.SourcePath `
                    -OutputPath $outputPath
                
                if ($success) {
                    # Remove original MP4
                    Remove-Item -LiteralPath $MediaFile.SourcePath -Force -ErrorAction SilentlyContinue
                }
                
                return [PSCustomObject]@{
                    Success       = $success
                    OutputPath    = $outputPath
                    Type          = 'Remux'
                    ExtractedSrts = @()
                    OpenSubsHash  = $openSubsHash
                }
            }
            else {
                # Mp4Remux disabled - keep MP4 as-is
                Write-SAVerbose -Text "MP4 remux disabled - keeping file as-is"
                
                return [PSCustomObject]@{
                    Success       = $true
                    OutputPath    = $MediaFile.SourcePath
                    Type          = 'NoAction'
                    ExtractedSrts = @()
                    OpenSubsHash  = $openSubsHash
                }
            }
        }
        
        'MKV' {
            # Process MKV in-place
            $result = Invoke-SAProcessExtractedMkv -Context $Context `
                -SourcePath $MediaFile.SourcePath
            
            return $result
        }
        
        default {
            # Compute hash for other video types
            $openSubsHash = $null
            try {
                $openSubsHash = Get-SAVideoHash -Path $MediaFile.SourcePath
            } catch {
                Write-SAVerbose -Text "Could not compute hash: $_"
            }
            
            return [PSCustomObject]@{
                Success       = $true
                OutputPath    = $MediaFile.SourcePath
                Type          = 'NoAction'
                ExtractedSrts = @()
                OpenSubsHash  = $openSubsHash
            }
        }
    }
}

function Invoke-SAProcessExtractedMkv {
    <#
    .SYNOPSIS
        Processes an MKV that was extracted from RAR (in-place processing).
    .DESCRIPTION
        Handles video analysis, subtitle extraction, and track stripping.
        For batch operations (season packs), uses [n/N] progress format.
        Subtitle extraction and stripping are conditional on feature flags.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )
    
    $config = $Context.Config
    $fileName = Split-Path -Path $SourcePath -Leaf
    $sourceDir = Split-Path -Path $SourcePath -Parent
    $fileSize = (Get-Item -LiteralPath $SourcePath).Length
    
    # Check feature flags once at the start
    $extractionEnabled = Test-SAFeatureEnabled -Config $config -Feature 'SubtitleExtraction'
    $strippingEnabled = Test-SAFeatureEnabled -Config $config -Feature 'SubtitleStripping'
    $openSubsEnabled = Test-SAFeatureEnabled -Config $config -Feature 'OpenSubtitles'
    
    # Batch state for [n/N] progress
    $fileIndex = $Context.State.VideoFileIndex + 1  # Convert to 1-based
    $fileCount = $Context.State.VideoFileCount
    $isBatch = $fileCount -gt 1
    
    # Show Staging header only for first file
    if ($fileIndex -eq 1) {
        Write-SAPhaseHeader -Title "Staging" -FileCount $fileCount
    }
    
    # Show source file with [n/N] suffix for batch mode (DRY - same pattern for both)
    # Per OUTPUT-STYLE-GUIDE.md: "Source: filename.mkv (size) [n/N]"
    $sourceText = "$fileName ($(Format-SASize $fileSize))"
    if ($isBatch) {
        $sourceText += " [$fileIndex/$fileCount]"
    }
    Write-SAProgress -Label "Source" -Text $sourceText -Indent 1 -ConsoleOnly
    
    # Analyze MKV - only compute hash if OpenSubtitles is enabled (saves I/O)
    $mkvInfo = Get-SAMkvInfo -Path $SourcePath -MkvMergePath $Context.Tools.MkvMerge -ComputeHash $openSubsEnabled
    
    # Show "OpenSubtitles disabled" verbose only once per batch (not per file)
    if (-not $openSubsEnabled -and -not $Context.State.OpenSubsDisabledMsgShown) {
        Write-SAVerbose -Text "OpenSubtitles disabled - skipping hash computation"
        $Context.State.OpenSubsDisabledMsgShown = $true
    }
    
    if ($null -eq $mkvInfo) {
        # Per-file error outcome at indent 2 (aligns with file details)
        Write-SAOutcome -Level Error -Label "Analyze" -Text "Failed to analyze MKV" -Indent 2 -ConsoleOnly
        return [PSCustomObject]@{ Success = $false; OutputPath = $null; Type = 'Error'; OpenSubsHash = $null }
    }
    
    # Show track summary in normal output (consistent with Staging.ps1)
    # Per OUTPUT-STYLE-GUIDE.md: Tracks line at Indent 2 (4 spaces)
    $subWord = Get-SAPluralForm -Count $mkvInfo.SubtitleCount -Singular 'subtitle'
    $trackSummary = "$($mkvInfo.VideoTracks.Count) video, $($mkvInfo.AudioTracks.Count) audio, $($mkvInfo.SubtitleCount) $subWord"
    Write-SAProgress -Label "Tracks" -Text $trackSummary -Indent 2 -ConsoleOnly
    
    # Analyze subtitles (needed for both extraction and stripping decisions)
    $subAnalysis = $null
    $extractedSrts = @()
    
    if ($extractionEnabled -or $strippingEnabled) {
        $dupMode = if ($config.subtitles.extraction.duplicateLanguageMode) { $config.subtitles.extraction.duplicateLanguageMode } else { 'all' }
        $subAnalysis = Get-SAMkvSubtitleAnalysis -MkvInfo $mkvInfo `
            -WantedLanguages $config.subtitles.wantedLanguages `
            -RemovePatterns $config.subtitles.namePatternsToRemove `
            -DuplicateLanguageMode $dupMode
        
        Write-SAVerbose -Text "Subtitles: Wanted: $($subAnalysis.WantedTracks.Count), Unwanted: $($subAnalysis.UnwantedTracks.Count), Extractable: $($subAnalysis.ExtractableTracks.Count)"
        
        # Extract text subtitles - only if extraction enabled
        if ($extractionEnabled -and $subAnalysis.HasExtractable) {
            # Show progress before long operation (consistent with Staging.ps1)
            $trackWord = Get-SAPluralForm -Count $subAnalysis.ExtractableTracks.Count -Singular 'track'
            Write-SAProgress -Label "Extracting" -Text "$($subAnalysis.ExtractableTracks.Count) subtitle $trackWord..." -Indent 2 -ConsoleOnly
            
            $extractedSrts = Start-SAExtractSubtitles -Context $Context `
                -SourcePath $SourcePath `
                -OutputFolder $sourceDir `
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
    
    # Strip if needed AND stripping is enabled (in-place with temp file)
    $shouldStrip = $strippingEnabled -and $subAnalysis -and $subAnalysis.NeedsStrip
    
    if ($shouldStrip) {
        $tempPath = "$SourcePath.tmp.mkv"
        
        # Show what we're doing before the long operation (indent 2 for details)
        $trackWord = Get-SAPluralForm -Count $subAnalysis.UnwantedTracks.Count -Singular 'track'
        Write-SAProgress -Label "Remuxing" -Text "Removing $($subAnalysis.UnwantedTracks.Count) unwanted subtitle $trackWord..." -Indent 2 -ConsoleOnly
        
        $success = Start-SAMkvRemux -Context $Context `
            -SourcePath $SourcePath `
            -OutputPath $tempPath `
            -KeepSubtitleIds $subAnalysis.WantedTrackIds
        
        if ($success) {
            # Replace original with stripped version
            Remove-Item -LiteralPath $SourcePath -Force
            Rename-Item -LiteralPath $tempPath -NewName $fileName -Force
            
            $Context.Results.SubtitlesRemoved += $subAnalysis.UnwantedTracks.Count
            $trackWord = Get-SAPluralForm -Count $subAnalysis.UnwantedTracks.Count -Singular 'track'
            
            # Per-file outcome at indent 2 (aligns with file details)
            Write-SAOutcome -Level Success -Label "Removed" -Text "$($subAnalysis.UnwantedTracks.Count) unwanted $trackWord" -Indent 2 -ConsoleOnly
        } else {
            # Cleanup temp file on failure
            Write-SAOutcome -Level Error -Label "Strip" -Text "Failed" -Indent 2 -ConsoleOnly
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            return [PSCustomObject]@{ Success = $false; OutputPath = $SourcePath; Type = 'StripFailed'; OpenSubsHash = $mkvInfo.OpenSubsHash }
        }
    }
    elseif (-not $strippingEnabled -and $subAnalysis -and $subAnalysis.NeedsStrip) {
        Write-SAVerbose -Text "Subtitle stripping disabled - keeping $($subAnalysis.UnwantedTracks.Count) unwanted tracks"
    }
    
    return [PSCustomObject]@{
        Success       = $true
        OutputPath    = $SourcePath
        Type          = if ($shouldStrip) { 'Strip' } else { 'NoChange' }
        ExtractedSrts = $extractedSrts
        OpenSubsHash  = $mkvInfo.OpenSubsHash
    }
}

function Invoke-SAPassthroughProcessing {
    <#
    .SYNOPSIS
        Passthrough processing for unknown labels (no video/subtitle processing).
    .DESCRIPTION
        Simply extracts RAR archives or copies files to staging:
        - If source contains RAR files: extract to staging
        - Otherwise: copy all files to staging
        No video processing, no subtitle handling, no import.
    .PARAMETER Context
        Processing context.
    .OUTPUTS
        Processing result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    $sourcePath = $Context.State.SourcePath
    $stagingPath = $Context.State.StagingPath
    
    # Initialize staging
    Initialize-SAStagingFolder -Context $Context
    
    # Check for RAR files
    $rarFiles = @()
    if (Test-Path -LiteralPath $sourcePath -PathType Container) {
        $rarFiles = @(Get-ChildItem -LiteralPath $sourcePath -Filter '*.rar' -Recurse |
            Where-Object { $_.Name -notmatch '\.part(?!01)\d+\.rar$' })
    } elseif ($sourcePath -match '\.rar$') {
        $rarFiles = @(Get-Item -LiteralPath $sourcePath)
    }
    
    if ($rarFiles.Count -gt 0) {
        # Extract RAR
        Write-SAPhaseHeader -Title "Passthrough (RAR)"
        
        $firstRar = $rarFiles | Sort-Object { $_.Name } | Select-Object -First 1
        $success = Start-SAUnrar -Context $Context -RarPath $firstRar.FullName -OutputFolder $stagingPath
        
        # Check for explicit failure OR no files extracted (belt-and-suspenders)
        $extractedFiles = @(Get-ChildItem -LiteralPath $stagingPath -Recurse -File -ErrorAction SilentlyContinue)
        if ((-not $success) -or ($extractedFiles.Count -eq 0)) {
            return [PSCustomObject]@{
                Success = $false
                Reason  = 'RarExtractionFailed'
            }
        }
        
        # Success message is already shown by Start-SAUnrar
    } else {
        # Copy all files to staging
        Write-SAPhaseHeader -Title "Passthrough (Copy)"
        
        # Show progress before copy
        Write-SAProgress -Label "Copying" -Text "to destination..." -Indent 1
        
        if (Test-Path -LiteralPath $sourcePath -PathType Container) {
            # Copy folder contents
            $files = Get-ChildItem -LiteralPath $sourcePath -File -ErrorAction SilentlyContinue
            $totalSize = 0
            $copyCount = 0
            
            foreach ($file in $files) {
                $destPath = Join-Path -Path $stagingPath -ChildPath $file.Name
                Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
                $totalSize += $file.Length
                $copyCount++
            }
            
            $fileWord = Get-SAPluralForm -Count $copyCount -Singular 'file'
            Write-SAOutcome -Level Success -Label "Copied" -Text "$copyCount $fileWord ($(Format-SASize $totalSize))" -Indent 1
        } else {
            # Single file
            $fileName = Split-Path -Path $sourcePath -Leaf
            $destPath = Join-Path -Path $stagingPath -ChildPath $fileName
            Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
            $fileSize = (Get-Item -LiteralPath $sourcePath).Length
            
            Write-SAOutcome -Level Success -Label "Copied" -Text "1 file ($(Format-SASize $fileSize))" -Indent 1
        }
    }
    
    return [PSCustomObject]@{
        Success     = $true
        StagingPath = $stagingPath
    }
}
