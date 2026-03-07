#Requires -Version 5.1
<#
.SYNOPSIS
    Subtitle processing and analysis.
.DESCRIPTION
    Functions for subtitle file handling and language analysis:
    - SubtitleEdit cleanup (remove HI, fix formatting)
    - External subtitle discovery and copying
    - Language detection and gap analysis
    - Main processing orchestration
    
    Depends on: OpenSubtitles.ps1 (for downloads), MkvAnalysis.ps1 (for extraction)
#>

function Reset-SASubtitlesState {
    <#
    .SYNOPSIS
        Resets OpenSubtitles token cache state.
    .DESCRIPTION
        Clears in-memory token cache. Note: disk-cached tokens are NOT cleared
        as they are shared across sessions and have their own expiry logic.
        Call this between jobs if you want each job to re-authenticate.
    .PARAMETER IncludeDiskCache
        Also remove the disk-cached token file (forces re-authentication).
    .EXAMPLE
        Reset-SASubtitlesState
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeDiskCache
    )
    
    $script:SAOpenSubtitlesToken = $null
    $script:SAOpenSubtitlesTokenExpiry = $null
    $script:SAOpenSubtitlesTokenFile = $null
    $script:SAXmlRpcToken = $null

    if ($IncludeDiskCache) {
        $tokenPath = Get-SAOpenSubtitlesTokenPath
        if (Test-Path -LiteralPath $tokenPath) {
            Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
            Write-SAVerbose -Text "Removed disk-cached token: $tokenPath"
        }
    }
    
    # Note: Intentionally no verbose here - internal state reset is not useful for troubleshooting
}

function Start-SASubtitleCleanup {
    <#
    .SYNOPSIS
        Cleans all subtitle files in a folder using batch processing.
    .DESCRIPTION
        Uses SubtitleEdit's batch processing capability to clean all SRT files
        in a single invocation using the *.srt pattern.
    .PARAMETER Context
        Processing context.
    .PARAMETER FolderPath
        Folder containing SRT files.
    .OUTPUTS
        Number of files cleaned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )
    
    $subtitleEdit = $Context.Tools.SubtitleEdit
    
    if ([string]::IsNullOrWhiteSpace($subtitleEdit) -or -not (Test-Path -LiteralPath $subtitleEdit)) {
        return 0
    }
    
    $srtFiles = Get-ChildItem -LiteralPath $FolderPath -Filter '*.srt' -File -ErrorAction SilentlyContinue
    
    if ($srtFiles.Count -eq 0) {
        return 0
    }
    
    # Use SubtitleEdit batch processing with *.srt pattern
    # This processes all files in a single invocation instead of per-file calls
    # Parameters match original script - /FixCommonErrors twice to catch issues that arise after first fix
    $seArgs = @(
        '/convert',
        '*.srt',
        'subrip',
        "/inputfolder:$FolderPath",
        '/overwrite',
        '/MergeSameTexts',
        '/RemoveTextForHI',
        '/FixCommonErrors',
        '/FixCommonErrors',
        "/outputfolder:$FolderPath"
    )
    
    Write-SAVerbose -Text "Batch cleaning $($srtFiles.Count) subtitle files"
    
    # Use retry for transient failures with timeout
    # Increase timeout for batch processing (10 seconds per file, minimum 60 seconds)
    $timeoutSeconds = [Math]::Max(60, $srtFiles.Count * 10)
    
    $result = Invoke-SAProcessWithRetry -FilePath $subtitleEdit `
        -ArgumentList $seArgs `
        -TimeoutSeconds $timeoutSeconds `
        -MaxRetries 1 `
        -RetryExitCodes @(-2)  # Only retry on timeout
    
    if ($result.Success -or $result.ExitCode -eq 0) {
        $fileWord = Get-SAPluralForm -Count $srtFiles.Count -Singular 'file'
        Write-SAOutcome -Level Success -Label "Cleaned" -Text "$($srtFiles.Count) $fileWord with SubtitleEdit" -Indent 1
        return $srtFiles.Count
    } else {
        # SubtitleEdit may return non-zero but still work - check if files exist
        $existingCount = @($srtFiles | Where-Object { Test-Path -LiteralPath $_.FullName }).Count
        
        if ($existingCount -eq $srtFiles.Count) {
            $fileWord = Get-SAPluralForm -Count $existingCount -Singular 'file'
            Write-SAOutcome -Level Success -Label "Cleaned" -Text "$existingCount $fileWord with SubtitleEdit" -Indent 1
            return $existingCount
        }
        
        # Log error
        $errorInfo = Get-SAToolErrorInfo -ToolName 'SubtitleEdit' `
            -ExitCode $result.ExitCode `
            -ErrorMessage $result.StdErr `
            -FilePath $FolderPath
        
        Write-SAVerbose -Text "SubtitleEdit batch failed: $($errorInfo.Problem) - $($errorInfo.Reason)"
        return 0
    }
}

function Copy-SAExternalSubtitles {
    <#
    .SYNOPSIS
        Copies external subtitle files from source to staging.
    .DESCRIPTION
        Finds and copies existing SRT files alongside video files.
        Normalizes language codes in filenames.
    .PARAMETER Context
        Processing context.
    .PARAMETER SourcePath
        Source folder or video file path.
    .PARAMETER OutputFolder
        Destination folder for subtitles.
    .PARAMETER VideoBaseName
        Base name of the video file (for matching).
    .OUTPUTS
        Array of copied subtitle file paths.
    .EXAMPLE
        $copied = Copy-SAExternalSubtitles -Context $ctx -SourcePath "C:\Downloads\Movie" -OutputFolder "C:\Staging\Movie"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,
        
        [Parameter()]
        [string]$VideoBaseName
    )
    
    $copiedFiles = [System.Collections.Generic.List[string]]::new()
    $subtitleExtensions = @('.srt', '.sub', '.ass', '.ssa')
    
    # Determine search path
    $searchPath = $SourcePath
    if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
        $searchPath = Split-Path -Path $SourcePath -Parent
        if ([string]::IsNullOrWhiteSpace($VideoBaseName)) {
            $VideoBaseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
        }
    }
    
    if (-not (Test-Path -LiteralPath $searchPath -PathType Container)) {
        return @()
    }
    
    # Find subtitle files
    $subFiles = Get-ChildItem -LiteralPath $searchPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLower() -in $subtitleExtensions }
    
    if ($subFiles.Count -eq 0) {
        return @()
    }
    
    $subWord = Get-SAPluralForm -Count $subFiles.Count -Singular 'subtitle'
    Write-SAProgress -Label "External" -Text "Found $($subFiles.Count) $subWord"
    
    # Ensure output folder exists
    New-SADirectory -Path $OutputFolder
    
    foreach ($subFile in $subFiles) {
        # Check if this subtitle matches our video
        if (-not [string]::IsNullOrWhiteSpace($VideoBaseName)) {
            if (-not $subFile.BaseName.StartsWith($VideoBaseName, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }
        
        # Try to detect and normalize language code in filename
        $newName = Get-SANormalizedSubtitleName -OriginalName $subFile.Name -VideoBaseName $VideoBaseName
        
        $destPath = Join-Path -Path $OutputFolder -ChildPath $newName
        
        # Skip if already exists
        if (Test-Path -LiteralPath $destPath) {
            Write-SAProgress -Label "External" -Text "Skipped (exists): $newName"
            continue
        }
        
        try {
            Copy-Item -LiteralPath $subFile.FullName -Destination $destPath -Force
            $copiedFiles.Add($destPath)
            Write-SAOutcome -Level Success -Label "External" -Text "Copied: $newName" -Indent 1
        } catch {
            Write-SAOutcome -Level Warning -Label "External" -Text "Failed: $($subFile.Name)" -Indent 1
        }
    }
    
    return $copiedFiles.ToArray()
}

function Get-SANormalizedSubtitleName {
    <#
    .SYNOPSIS
        Normalizes subtitle filename with proper language code.
    .PARAMETER OriginalName
        Original subtitle filename.
    .PARAMETER VideoBaseName
        Base name of the video file.
    .OUTPUTS
        Normalized filename.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OriginalName,
        
        [Parameter()]
        [string]$VideoBaseName
    )
    
    $extension = [System.IO.Path]::GetExtension($OriginalName)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($OriginalName)
    
    # Common patterns: movie.en.srt, movie.english.srt, movie.eng.srt
    $langPattern = '\.([a-zA-Z]{2,3}|[a-zA-Z]+)$'
    
    if ($baseName -match $langPattern) {
        $potentialLang = $Matches[1]
        $normalized = ConvertTo-SALanguageCode -Code $potentialLang -To 'iso1'
        
        if ($normalized) {
            # Replace language code with normalized version
            $nameWithoutLang = $baseName -replace "$langPattern", ''
            
            if (-not [string]::IsNullOrWhiteSpace($VideoBaseName)) {
                return "$VideoBaseName.$normalized$extension"
            }
            
            return "$nameWithoutLang.$normalized$extension"
        }
    }
    
    # No language code detected - use original name
    if (-not [string]::IsNullOrWhiteSpace($VideoBaseName) -and 
        -not $baseName.StartsWith($VideoBaseName, [StringComparison]::OrdinalIgnoreCase)) {
        # Prepend video base name
        return "$VideoBaseName.$baseName$extension"
    }
    
    return $OriginalName
}

#region Pure Helper Functions (SOLID Refactor - Phase 6)

function Get-SAVideoExistingLanguages {
    <#
    .SYNOPSIS
        Gets the languages a video already has from SRT files.
    .DESCRIPTION
        Pure function - no I/O. Analyzes SRT filenames to determine which
        language codes are already present for a specific video.
    .PARAMETER SrtFiles
        Array of SRT file paths.
    .PARAMETER VideoBaseName
        Base name of the video file to match against.
    .OUTPUTS
        Hashtable of language codes that are present.
    .EXAMPLE
        $langs = Get-SAVideoExistingLanguages -SrtFiles $allSrts -VideoBaseName 'Movie.2024'
        # Returns @{ 'en' = $true; 'nl' = $true }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$SrtFiles,
        
        [Parameter(Mandatory = $true)]
        [string]$VideoBaseName
    )
    
    $existingLangs = @{}
    
    foreach ($srt in $SrtFiles) {
        $srtName = Split-Path -Path $srt -Leaf
        if ($srtName.StartsWith($VideoBaseName, [StringComparison]::OrdinalIgnoreCase)) {
            if ($srtName -match '\.([a-z]{2})\.srt$') {
                $existingLangs[$Matches[1]] = $true
            }
        }
    }
    
    return $existingLangs
}

function Get-SAVideoMissingLanguages {
    <#
    .SYNOPSIS
        Determines which wanted languages are missing for a video.
    .DESCRIPTION
        Pure function - no I/O. Compares wanted languages against existing
        languages to determine what needs to be downloaded.
    .PARAMETER WantedLanguages
        Array of wanted language codes.
    .PARAMETER ExistingLanguages
        Hashtable of language codes already present.
    .OUTPUTS
        Array of normalized ISO 639-1 language codes that are missing.
    .EXAMPLE
        $missing = Get-SAVideoMissingLanguages -WantedLanguages @('en','nl','de') -ExistingLanguages @{'en'=$true}
        # Returns @('nl', 'de')
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$WantedLanguages,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$ExistingLanguages
    )
    
    $missing = @($WantedLanguages | ForEach-Object {
        $normalized = ConvertTo-SALanguageCode -Code $_ -To 'iso1'
        if ($normalized -and -not $ExistingLanguages.ContainsKey($normalized)) {
            $normalized
        }
    } | Where-Object { $_ })
    
    return $missing
}

function Get-SASubtitleLanguageCounts {
    <#
    .SYNOPSIS
        Gets language counts from SRT file collection.
    .DESCRIPTION
        Pure function - no I/O. Analyzes SRT filenames to count
        subtitles per language code.
    .PARAMETER SrtFiles
        Array of SRT file paths.
    .OUTPUTS
        Hashtable with language codes as keys and counts as values.
    .EXAMPLE
        $counts = Get-SASubtitleLanguageCounts -SrtFiles $allSrts
        # Returns @{ 'en' = 8; 'nl' = 8 }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$SrtFiles
    )
    
    $langCounts = @{}
    
    foreach ($srt in $SrtFiles) {
        $srtName = Split-Path -Path $srt -Leaf
        if ($srtName -match '\.([a-z]{2})\.srt$') {
            $langCode = $Matches[1]
            if (-not $langCounts.ContainsKey($langCode)) {
                $langCounts[$langCode] = 0
            }
            $langCounts[$langCode]++
        }
    }
    
    return $langCounts
}

function Format-SASubtitleSummary {
    <#
    .SYNOPSIS
        Formats human-readable subtitle summary text.
    .DESCRIPTION
        Pure function - no I/O. Creates summary text like "English (8), Dutch (8)"
        for batch mode or "English, Dutch" for single file mode.
    .PARAMETER LanguageCounts
        Hashtable with language codes as keys and counts as values.
    .PARAMETER TotalVideos
        Total number of videos (for determining batch vs single mode).
    .OUTPUTS
        Formatted string for display.
    .EXAMPLE
        $summary = Format-SASubtitleSummary -LanguageCounts @{'en'=8;'nl'=8} -TotalVideos 8
        # Returns "English (8), Dutch (8)"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$LanguageCounts,
        
        [Parameter()]
        [int]$TotalVideos = 1
    )
    
    if ($LanguageCounts.Count -eq 0) {
        return 'Complete'
    }
    
    $langParts = @()
    foreach ($langCode in ($LanguageCounts.Keys | Sort-Object)) {
        $langName = ConvertTo-SALanguageCode -Code $langCode -To 'name'
        if (-not $langName) { $langName = $langCode.ToUpper() }
        
        # For batches, show count per language: "Dutch (8)"
        # For single files, just show language: "Dutch"
        if ($TotalVideos -gt 1) {
            $langParts += "$langName ($($LanguageCounts[$langCode]))"
        } else {
            $langParts += $langName
        }
    }
    
    return $langParts -join ', '
}

function Get-SAMissingLanguagesInfo {
    <#
    .SYNOPSIS
        Gets missing languages info array for email reporting.
    .DESCRIPTION
        Pure function - no I/O. Creates structured data about missing
        subtitles for email templates.
    .PARAMETER FinalMissingLangs
        Hashtable with language codes as keys and missing counts as values.
    .PARAMETER TotalVideos
        Total number of videos processed.
    .OUTPUTS
        Array of PSCustomObjects with Language, MissingCount, TotalVideos.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FinalMissingLangs,
        
        [Parameter()]
        [int]$TotalVideos = 1
    )
    
    $info = @()
    
    if ($TotalVideos -gt 1) {
        foreach ($lang in $FinalMissingLangs.Keys) {
            $count = $FinalMissingLangs[$lang]
            $info += [PSCustomObject]@{
                Language     = $lang
                MissingCount = $count
                TotalVideos  = $TotalVideos
            }
        }
    } else {
        foreach ($lang in $FinalMissingLangs.Keys) {
            $info += [PSCustomObject]@{
                Language     = $lang
                MissingCount = 1
                TotalVideos  = 1
            }
        }
    }
    
    return $info
}

#endregion

#region Main Subtitle Processing

function Invoke-SASubtitleProcessing {
    <#
    .SYNOPSIS
        Main entry point for subtitle processing pipeline.
    .DESCRIPTION
        Orchestrates the complete subtitle workflow:
        1. Copy external subtitles from source
        2. Download missing subtitles from OpenSubtitles (for each video file)
        3. Clean all subtitles with SubtitleEdit
        
        Uses pure helper functions for testability (SOLID refactor - Phase 6).
    .PARAMETER Context
        Processing context.
    .PARAMETER ProcessedFiles
        Array of processed video file objects from video processing.
        Each object should have: OutputPath, OpenSubsHash, ExtractedSrts.
    .PARAMETER SourcePath
        Original source path (for external subs).
    .OUTPUTS
        Processing result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [array]$ProcessedFiles,
        
        [Parameter()]
        [string]$SourcePath
    )
    
    $stagingPath = $Context.State.StagingPath
    $wantedLanguages = $Context.Config.subtitles.wantedLanguages
    
    Write-SAPhaseHeader -Title "Subtitles"
    Write-SAVerbose -Text "Subtitle processing for $($ProcessedFiles.Count) video files"
    Write-SAVerbose -Text "Wanted languages: $($wantedLanguages -join ', ')"
    
    $allSrts = [System.Collections.Generic.List[string]]::new()
    $downloadedSrts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Collect all extracted SRTs from video processing
    foreach ($pf in $ProcessedFiles) {
        if ($pf.ExtractedSrts) {
            foreach ($srt in $pf.ExtractedSrts) {
                if (Test-Path -LiteralPath $srt) {
                    $allSrts.Add($srt)
                }
            }
        }
    }
    
    if ($allSrts.Count -gt 0) {
        $srtWord = Get-SAPluralForm -Count $allSrts.Count -Singular 'subtitle'
        Write-SAProgress -Label "Extracted" -Text "$($allSrts.Count) $srtWord from video" -Indent 1
    }
    
    # Step 1: Copy external subtitles from source (for all videos)
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        foreach ($pf in $ProcessedFiles) {
            if (-not $pf.OutputPath -or -not (Test-Path -LiteralPath $pf.OutputPath)) {
                continue
            }
            
            $videoBaseName = [System.IO.Path]::GetFileNameWithoutExtension($pf.OutputPath)
            
            $externalSubs = Copy-SAExternalSubtitles -Context $Context `
                -SourcePath $SourcePath `
                -OutputFolder $stagingPath `
                -VideoBaseName $videoBaseName
            
            foreach ($sub in $externalSubs) {
                if (-not $allSrts.Contains($sub)) {
                    $allSrts.Add($sub)
                }
            }
        }
    }
    
    # Step 2: For each video, determine missing languages and download from OpenSubtitles
    $videosWithMissing = [System.Collections.Generic.List[string]]::new()
    $totalDownloaded = 0
    $videosNeedingDownload = 0
    
    # Check OpenSubtitles feature flag using centralized function
    $openSubsEnabled = Test-SAFeatureEnabled -Config $Context.Config -Feature 'OpenSubtitles'
    
    if ($openSubsEnabled) {
        $validVideos = @($ProcessedFiles | Where-Object { $_.OutputPath -and (Test-Path -LiteralPath $_.OutputPath -ErrorAction SilentlyContinue) })
        $totalValidVideos = $validVideos.Count
        $videoIndex = 0
        
        # First pass: count how many videos need downloads (using pure helper functions)
        $missingLangsSummary = @{}
        foreach ($pf in $ProcessedFiles) {
            if (-not $pf.OutputPath -or -not (Test-Path -LiteralPath $pf.OutputPath)) {
                continue
            }
            
            $videoBaseName = [System.IO.Path]::GetFileNameWithoutExtension($pf.OutputPath)
            
            # Use pure helper to get existing languages
            $videoHasLangs = Get-SAVideoExistingLanguages -SrtFiles $allSrts.ToArray() -VideoBaseName $videoBaseName
            
            # Use pure helper to get missing languages
            $videoMissingLangs = Get-SAVideoMissingLanguages -WantedLanguages $wantedLanguages -ExistingLanguages $videoHasLangs
            
            # Count missing languages
            foreach ($lang in $videoMissingLangs) {
                if (-not $missingLangsSummary.ContainsKey($lang)) {
                    $missingLangsSummary[$lang] = 0
                }
                $missingLangsSummary[$lang]++
                $videosNeedingDownload++
            }
        }
        
        # Show batch summary at start if there are missing subtitles
        if ($missingLangsSummary.Count -gt 0) {
            $missingLangsList = @($missingLangsSummary.Keys | ForEach-Object {
                $langName = ConvertTo-SALanguageCode -Code $_ -To 'name'
                if (-not $langName) { $langName = $_.ToUpper() }
                $langName
            })
            $missingStr = $missingLangsList -join ', '
            
            if ($totalValidVideos -gt 1) {
                Write-SAProgress -Label "OpenSubs" -Text "Searching for $totalValidVideos missing $missingStr subtitles..." -Indent 1
            } else {
                Write-SAProgress -Label "OpenSubs" -Text "Searching for $missingStr..." -Indent 1
            }
        }
        
        # Second pass: actually download (using pure helper functions)
        foreach ($pf in $ProcessedFiles) {
            if (-not $pf.OutputPath -or -not (Test-Path -LiteralPath $pf.OutputPath)) {
                continue
            }
            
            $videoIndex++
            $videoPath = $pf.OutputPath
            $videoBaseName = [System.IO.Path]::GetFileNameWithoutExtension($videoPath)
            $videoFileName = Split-Path -Path $videoPath -Leaf
            
            # Use pure helpers to get existing and missing languages
            $videoHasLangs = Get-SAVideoExistingLanguages -SrtFiles $allSrts.ToArray() -VideoBaseName $videoBaseName
            $videoMissingLangs = Get-SAVideoMissingLanguages -WantedLanguages $wantedLanguages -ExistingLanguages $videoHasLangs
            
            if ($videoMissingLangs.Count -eq 0) {
                # Skip verbose for files that have all languages (no news is good news)
                continue
            }
            
            # This video needs subtitles downloaded
            $missingStr = $videoMissingLangs -join ', '
            
            $downloadParams = @{
                Context      = $Context
                VideoPath    = $videoPath
                OutputFolder = $stagingPath
                Languages    = $videoMissingLangs
            }
            
            # Condensed verbose: file, languages, hash, and batch counter at END (per style guide)
            $hashInfo = ""
            if (-not [string]::IsNullOrWhiteSpace($pf.OpenSubsHash)) {
                $downloadParams.MovieHash = $pf.OpenSubsHash
                $hashInfo = " (hash: $($pf.OpenSubsHash))"
            }
            Write-SAVerbose -Text "$videoFileName - searching $missingStr$hashInfo [$videoIndex/$totalValidVideos]"
            
            $downloaded = Start-SAOpenSubtitlesDownload @downloadParams
            
            foreach ($sub in $downloaded) {
                $allSrts.Add($sub)
                $downloadedSrts.Add($sub) | Out-Null
                $totalDownloaded++
            }
            
            # Track if this video still has missing languages after download
            $stillMissing = $videoMissingLangs.Count - $downloaded.Count
            if ($stillMissing -gt 0) {
                $videosWithMissing.Add($videoFileName)
                # Show exception per-file at INFO level (indent 1)
                $missingLangNames = @($videoMissingLangs | Where-Object { 
                    $lang = $_
                    -not ($downloaded | Where-Object { (Split-Path $_ -Leaf) -match "\.$lang\.srt$" })
                } | ForEach-Object {
                    $langName = ConvertTo-SALanguageCode -Code $_ -To 'name'
                    if (-not $langName) { $langName = $_.ToUpper() }
                    $langName
                })
                if ($totalValidVideos -gt 1) {
                    Write-SAProgress -Label "!" -Text "[$videoIndex/$totalValidVideos] $($missingLangNames -join ', ') not available" -Indent 1
                }
            }
        }
        
        # Show batch download summary
        if ($totalDownloaded -gt 0) {
            # Per OUTPUT-STYLE-GUIDE.md: proper pluralization (1 subtitle vs 2 subtitles)
            $subWord = Get-SAPluralForm -Count $totalDownloaded -Singular 'subtitle'
            Write-SAOutcome -Level Success -Label "OpenSubs" -Text "Downloaded $totalDownloaded $subWord" -Indent 1
        } elseif ($videosNeedingDownload -gt 0) {
            Write-SAProgress -Label "OpenSubs" -Text "No subtitles found" -Indent 1
        }
    } else {
        # Per OUTPUT-STYLE-GUIDE: disabled features should be verbose-only
        Write-SAVerbose -Text "OpenSubtitles disabled - skipping download"
    }
    
    # Calculate final per-video missing languages for email reporting (using pure helper functions)
    $finalMissingLangs = @{}
    foreach ($pf in $ProcessedFiles) {
        if (-not $pf.OutputPath -or -not (Test-Path -LiteralPath $pf.OutputPath)) {
            continue
        }
        
        $videoBaseName = [System.IO.Path]::GetFileNameWithoutExtension($pf.OutputPath)
        
        # Use pure helpers to get current state
        $videoHasLangs = Get-SAVideoExistingLanguages -SrtFiles $allSrts.ToArray() -VideoBaseName $videoBaseName
        $videoMissingLangs = Get-SAVideoMissingLanguages -WantedLanguages $wantedLanguages -ExistingLanguages $videoHasLangs
        
        # Track missing per language
        foreach ($lang in $videoMissingLangs) {
            if (-not $finalMissingLangs.ContainsKey($lang)) {
                $finalMissingLangs[$lang] = 0
            }
            $finalMissingLangs[$lang]++
        }
    }
    
    # Build missing languages result (languages missing from ANY video)
    $stillMissingLangs = @($finalMissingLangs.Keys)
    
    # Build summary message
    $totalVideos = @($ProcessedFiles | Where-Object { $_.OutputPath -and (Test-Path -LiteralPath $_.OutputPath -ErrorAction SilentlyContinue) }).Count
    
    if ($finalMissingLangs.Count -gt 0 -and $totalVideos -gt 1) {
        # Multi-file: report per-language missing counts
        $missingDetails = @()
        foreach ($key in $finalMissingLangs.Keys) {
            $langName = ConvertTo-SALanguageCode -Code $key -To 'name'
            if (-not $langName) { $langName = $key.ToUpper() }
            $count = $finalMissingLangs[$key]
            $missingDetails += "$langName ($count of $totalVideos)"
        }
        Write-SAOutcome -Level Warning -Label "Missing" -Text ($missingDetails -join ', ') -Indent 1
    } elseif ($finalMissingLangs.Count -gt 0) {
        # Single file: just list missing languages
        $missingNames = @()
        foreach ($lang in $stillMissingLangs) {
            $langName = ConvertTo-SALanguageCode -Code $lang -To 'name'
            if ($langName) { $missingNames += $langName } else { $missingNames += $lang.ToUpper() }
        }
        Write-SAOutcome -Level Warning -Label "Missing" -Text ($missingNames -join ', ') -Indent 1
    }
    
    # Step 3: Clean all subtitles with SubtitleEdit
    # Check feature flag using centralized function
    $cleanupEnabled = Test-SAFeatureEnabled -Config $Context.Config -Feature 'SubtitleCleanup'
    
    if ($allSrts.Count -gt 0 -and $cleanupEnabled -and -not [string]::IsNullOrWhiteSpace($Context.Tools.SubtitleEdit)) {
        $fileWord = Get-SAPluralForm -Count $allSrts.Count -Singular 'file'
        Write-SAProgress -Text "Cleaning $($allSrts.Count) $fileWord with SubtitleEdit..." -Indent 1
        $null = Start-SASubtitleCleanup -Context $Context -FolderPath $stagingPath
    }
    elseif ($allSrts.Count -gt 0 -and -not $cleanupEnabled) {
        # Per OUTPUT-STYLE-GUIDE: disabled features should be verbose-only
        Write-SAVerbose -Text "Subtitle cleanup disabled - skipping SubtitleEdit processing"
    }
    elseif ($allSrts.Count -gt 0 -and [string]::IsNullOrWhiteSpace($Context.Tools.SubtitleEdit)) {
        Write-SAVerbose -Text "SubtitleEdit not configured - skipping cleanup"
    }
    
    # Step 4: Upload cleaned subtitles to OpenSubtitles (excluding downloaded ones)
    $uploadedCount = 0
    if ($allSrts.Count -gt 0 -and $openSubsEnabled -and
        $Context.Config.subtitles.openSubtitles.uploadCleaned -eq $true) {

        $uploadableSrts = @($allSrts | Where-Object { -not $downloadedSrts.Contains($_) })

        if ($uploadableSrts.Count -gt 0) {
            $videoHashMap = @{}
            $videoSizeMap = @{}
            foreach ($pf in $ProcessedFiles) {
                if ($pf.OutputPath -and (Test-Path -LiteralPath $pf.OutputPath)) {
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($pf.OutputPath)
                    if ($pf.OpenSubsHash) { $videoHashMap[$baseName] = $pf.OpenSubsHash }
                    $videoSizeMap[$baseName] = (Get-Item -LiteralPath $pf.OutputPath).Length
                }
            }

            $uploadResult = Start-SAOpenSubtitlesUpload -Context $Context `
                -SubtitlePaths $uploadableSrts `
                -VideoHashMap $videoHashMap `
                -VideoSizeMap $videoSizeMap
            $uploadedCount = $uploadResult.UploadedCount
        }
    }

    # C5 fix: Summary shows languages, not file count (per OUTPUT-STYLE-GUIDE)
    # Use pure helper function for language counting
    $langCounts = Get-SASubtitleLanguageCounts -SrtFiles $allSrts.ToArray()
    
    if ($langCounts.Count -gt 0) {
        # Use pure helper function for summary text
        $summaryText = Format-SASubtitleSummary -LanguageCounts $langCounts -TotalVideos $totalVideos
        Write-SAOutcome -Level Success -Label "Subtitles" -Text $summaryText -Indent 1
    } else {
        Write-SAOutcome -Level Success -Label "Subtitles" -Text "Complete" -Indent 1
    }
    
    # Build missing languages info for email using pure helper function
    $missingLanguagesInfo = Get-SAMissingLanguagesInfo -FinalMissingLangs $finalMissingLangs -TotalVideos $totalVideos
    
    return [PSCustomObject]@{
        Success              = $true
        SubtitleFiles        = $allSrts.ToArray()
        ExtractedCount       = ($ProcessedFiles | ForEach-Object { if ($_.ExtractedSrts) { $_.ExtractedSrts.Count } else { 0 } } | Measure-Object -Sum).Sum
        DownloadedCount      = $totalDownloaded
        UploadedCount        = $uploadedCount
        MissingLanguages     = $stillMissingLangs
        MissingLanguagesInfo = $missingLanguagesInfo
    }
}

#endregion
