#Requires -Version 5.1
<#
.SYNOPSIS
    MKV analysis functions for Stagearr
.DESCRIPTION
    Analyzes MKV files to detect video, audio, and subtitle tracks.
    Uses mkvmerge -J for JSON track information.
#>

function Get-SAVideoHash {
    <#
    .SYNOPSIS
        Computes OpenSubtitles hash for a video file.
    .DESCRIPTION
        OpenSubtitles uses a specific hash algorithm:
        - File size (8 bytes, little-endian)
        - First 64KB of file (summed as 8-byte chunks)
        - Last 64KB of file (summed as 8-byte chunks)
        Uses decimal arithmetic to handle overflow wrapping.
    .PARAMETER Path
        Path to the video file.
    .OUTPUTS
        Hash string (16 hex characters), or $null on failure.
    .EXAMPLE
        $hash = Get-SAVideoHash -Path "C:\Movies\film.mkv"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    
    try {
        $file = [System.IO.File]::OpenRead($Path)
        try {
            $fileSize = $file.Length
            
            # File must be at least 128KB
            if ($fileSize -lt 131072) {
                Write-SAVerbose -Text "File too small for OpenSubtitles hash (< 128KB)"
                return $null
            }
            
            $chunkSize = 65536  # 64KB
            $buffer = New-Object byte[] $chunkSize
            
            # Use decimal for intermediate calculations to avoid overflow
            # Then apply modulo 2^64 at the end
            [decimal]$hashSum = [decimal]$fileSize
            [decimal]$maxUInt64 = [decimal]::Parse('18446744073709551616')  # 2^64
            
            # Read first 64KB
            $file.Position = 0
            $bytesRead = $file.Read($buffer, 0, $chunkSize)
            
            for ($i = 0; $i -lt $bytesRead; $i += 8) {
                # Read as unsigned 64-bit
                [uint64]$chunk = [BitConverter]::ToUInt64($buffer, $i)
                $hashSum += [decimal]$chunk
            }
            
            # Read last 64KB
            $file.Position = $fileSize - $chunkSize
            $bytesRead = $file.Read($buffer, 0, $chunkSize)
            
            for ($i = 0; $i -lt $bytesRead; $i += 8) {
                [uint64]$chunk = [BitConverter]::ToUInt64($buffer, $i)
                $hashSum += [decimal]$chunk
            }
            
            # Apply modulo 2^64 to wrap overflow
            $hashSum = $hashSum % $maxUInt64
            
            # Convert back to uint64 and format as 16-character hex string
            [uint64]$finalHash = [uint64]$hashSum
            return $finalHash.ToString('x16')
            
        } finally {
            $file.Close()
            $file.Dispose()
        }
    } catch {
        Write-SAOutcome -Level Warning -Label "Hash" -Text "Failed to compute hash: $_"
        return $null
    }
}

function Get-SAMkvInfo {
    <#
    .SYNOPSIS
        Gets detailed track information from an MKV file.
    .DESCRIPTION
        Runs mkvmerge -J to get JSON track info, then parses it into
        a structured object with video, audio, and subtitle tracks.
        Also computes OpenSubtitles hash for later subtitle lookups.
    .PARAMETER Path
        Path to the MKV file.
    .PARAMETER MkvMergePath
        Path to mkvmerge executable.
    .PARAMETER ComputeHash
        Compute OpenSubtitles hash (default: true).
    .OUTPUTS
        PSCustomObject with tracks, container info, and analysis results.
    .EXAMPLE
        $info = Get-SAMkvInfo -Path "movie.mkv" -MkvMergePath "C:\mkvmerge.exe"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$MkvMergePath,
        
        [Parameter()]
        [bool]$ComputeHash = $true
    )
    
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-SAOutcome -Level Warning -Label "MKV" -Text "File not found: $Path"
        return $null
    }
    
    # Run mkvmerge -J
    $result = Invoke-SAProcess -FilePath $MkvMergePath -ArgumentList @('-J', $Path)
    
    if (-not $result.Success) {
        # Get user-friendly error info
        $errorInfo = Get-SAToolErrorInfo -ToolName 'mkvmerge' `
            -ExitCode $result.ExitCode `
            -ErrorMessage $result.StdErr `
            -FilePath $Path
        
        Write-SAOutcome -Level Warning -Label "MKV" -Text $errorInfo.Problem
        Write-SAVerbose -Text "Reason: $($errorInfo.Reason)"
        return $null
    }
    
    try {
        # mkvmerge -J output should be pure JSON, but ensure we only get the JSON object
        $jsonText = $result.StdOut.Trim()
        
        # Find the JSON object boundaries (starts with { ends with })
        $startIndex = $jsonText.IndexOf('{')
        $endIndex = $jsonText.LastIndexOf('}')
        
        if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
            $jsonText = $jsonText.Substring($startIndex, $endIndex - $startIndex + 1)
        }
        
        $json = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
    } catch {
        Write-SAOutcome -Level Warning -Label "MKV" -Text "Failed to parse mkvmerge output: $_"
        return $null
    }
    
    # Parse tracks
    $videoTracks = [System.Collections.Generic.List[PSCustomObject]]::new()
    $audioTracks = [System.Collections.Generic.List[PSCustomObject]]::new()
    $subtitleTracks = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    foreach ($track in $json.tracks) {
        $trackInfo = [PSCustomObject]@{
            Id           = $track.id
            Type         = $track.type
            Codec        = $track.codec
            CodecId      = $track.properties.codec_id
            Language     = $track.properties.language
            LanguageIetf = $track.properties.language_ietf
            TrackName    = $track.properties.track_name
            Default      = [bool]$track.properties.default_track
            Forced       = [bool]$track.properties.forced_track
            Enabled      = [bool]$track.properties.enabled_track
            TextSubtitles = $track.properties.text_subtitles
            # Additional properties for specific track types
            Properties   = $track.properties
        }
        
        switch ($track.type) {
            'video' { $videoTracks.Add($trackInfo) }
            'audio' { $audioTracks.Add($trackInfo) }
            'subtitles' { $subtitleTracks.Add($trackInfo) }
        }
    }
    
    # Compute OpenSubtitles hash (before any modifications)
    $openSubsHash = $null
    if ($ComputeHash) {
        $openSubsHash = Get-SAVideoHash -Path $Path
        if ($openSubsHash) {
            Write-SAVerbose -Text "OpenSubtitles hash: $openSubsHash"
        }
    }
    
    # Build result object
    $mkvInfo = [PSCustomObject]@{
        Path           = $Path
        FileName       = Split-Path -Path $Path -Leaf
        Container      = $json.container
        VideoTracks    = $videoTracks.ToArray()
        AudioTracks    = $audioTracks.ToArray()
        SubtitleTracks = $subtitleTracks.ToArray()
        OpenSubsHash   = $openSubsHash
        # Convenience properties
        HasVideo       = ($videoTracks.Count -gt 0)
        HasAudio       = ($audioTracks.Count -gt 0)
        HasSubtitles   = ($subtitleTracks.Count -gt 0)
        SubtitleCount  = $subtitleTracks.Count
    }
    
    return $mkvInfo
}

function Get-SAMkvSubtitleAnalysis {
    <#
    .SYNOPSIS
        Analyzes subtitle tracks to determine wanted/unwanted based on config.
    .DESCRIPTION
        Implements intelligent subtitle selection:
        - For each wanted language: keep ALL tracks in MKV, extract only LARGEST to SRT
        - If NO wanted languages match: keep ALL subtitles (protection rule)
        - Remove only tracks from unwanted languages
        
        This ensures users have subtitle choice in their player while providing
        the best SRT for external use.
    .PARAMETER MkvInfo
        MKV info object from Get-SAMkvInfo.
    .PARAMETER WantedLanguages
        Array of wanted language codes (e.g., @('eng', 'nld')).
    .PARAMETER RemovePatterns
        Array of track name patterns to skip during extraction (e.g., @('Forced', 'SDH')).
        Pattern-matched tracks are still kept in MKV but deprioritized for extraction.
    .OUTPUTS
        Analysis object with wanted/unwanted track lists.
    .EXAMPLE
        $analysis = Get-SAMkvSubtitleAnalysis -MkvInfo $info -WantedLanguages @('eng','nld') -RemovePatterns @('Forced')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$MkvInfo,
        
        [Parameter()]
        [string[]]$WantedLanguages = @('eng'),
        
        [Parameter()]
        [string[]]$RemovePatterns = @(),

        [Parameter()]
        [ValidateSet('all', 'largest')]
        [string]$DuplicateLanguageMode = 'all'
    )
    
    # First pass: analyze all tracks
    $trackAnalysis = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    foreach ($track in $MkvInfo.SubtitleTracks) {
        $isWantedLanguage = $false
        $matchesRemovePattern = $false
        $isTextSubtitle = $false
        
        # Check language
        $trackLang = $track.Language
        if ([string]::IsNullOrWhiteSpace($trackLang)) {
            $trackLang = 'und'
        }
        
        # Normalize to ISO 639-2 for comparison
        $normalizedLang = ConvertTo-SALanguageCode -Code $trackLang -To 'iso2t'
        
        foreach ($wantedLang in $WantedLanguages) {
            $normalizedWanted = ConvertTo-SALanguageCode -Code $wantedLang -To 'iso2t'
            if ($normalizedLang -eq $normalizedWanted) {
                $isWantedLanguage = $true
                break
            }
        }
        
        # Check remove patterns in track name (for extraction priority, not removal)
        $trackName = $track.TrackName
        if (-not [string]::IsNullOrWhiteSpace($trackName) -and $RemovePatterns.Count -gt 0) {
            foreach ($pattern in $RemovePatterns) {
                if (-not [string]::IsNullOrWhiteSpace($pattern) -and $trackName -match [regex]::Escape($pattern)) {
                    $matchesRemovePattern = $true
                    break
                }
            }
        }
        
        # Check if text subtitle (extractable to SRT)
        # SRT-compatible codecs: S_TEXT/UTF8, S_TEXT/ASCII, SubRip, S_TEXT/WEBVTT
        $srtCodecs = @('S_TEXT/UTF8', 'S_TEXT/ASCII', 'SubRip', 'S_TEXT/WEBVTT')
        $isTextSubtitle = ($track.CodecId -in $srtCodecs) -or ($track.TextSubtitles -eq $true)
        
        # Get track size from properties (for picking largest)
        $trackSize = 0
        if ($null -ne $track.Properties -and $track.Properties.tag_number_of_bytes) {
            $trackSize = [int64]$track.Properties.tag_number_of_bytes
        }
        
        $trackAnalysis.Add([PSCustomObject]@{
            Track              = $track
            IsWantedLanguage   = $isWantedLanguage
            MatchesRemovePattern = $matchesRemovePattern
            IsTextSubtitle     = $isTextSubtitle
            NormalizedLanguage = $normalizedLang
            TrackSize          = $trackSize
        })
    }
    
    # Check if ANY wanted language has matches (wrap in @() for PS5.1 compatibility)
    $hasAnyWantedMatch = @($trackAnalysis | Where-Object { $_.IsWantedLanguage }).Count -gt 0
    
    # Second pass: determine which tracks to keep in MKV and which to extract
    $wantedTracks = [System.Collections.Generic.List[PSCustomObject]]::new()
    $unwantedTracks = [System.Collections.Generic.List[PSCustomObject]]::new()
    $extractableTracks = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    if (-not $hasAnyWantedMatch) {
        # PROTECTION RULE: No wanted languages found - keep ALL subtitles, extract nothing
        Write-SAVerbose -Text "No wanted languages found - keeping all $($MkvInfo.SubtitleCount) subtitles (protection rule)"
        
        foreach ($analysis in $trackAnalysis) {
            $trackResult = [PSCustomObject]@{
                Track              = $analysis.Track
                IsWantedLanguage   = $analysis.IsWantedLanguage
                MatchesRemovePattern = $analysis.MatchesRemovePattern
                IsTextSubtitle     = $analysis.IsTextSubtitle
                NormalizedLanguage = $analysis.NormalizedLanguage
                TrackSize          = $analysis.TrackSize
                ShouldKeep         = $true  # Keep all
                ShouldExtract      = $false # Extract nothing
            }
            $wantedTracks.Add($trackResult)
        }
    } else {
        # Normal processing: keep wanted languages, remove unwanted
        
        # Group wanted language tracks by language to find largest per language
        $wantedByLanguage = @{}
        foreach ($analysis in $trackAnalysis) {
            if ($analysis.IsWantedLanguage) {
                $lang = $analysis.NormalizedLanguage
                if (-not $wantedByLanguage.ContainsKey($lang)) {
                    $wantedByLanguage[$lang] = [System.Collections.Generic.List[PSCustomObject]]::new()
                }
                $wantedByLanguage[$lang].Add($analysis)
            }
        }
        
        # For each wanted language, select text subtitles for extraction
        # Mode 'largest': pick only the biggest track per language
        # Mode 'all': extract all text tracks (with numeric suffixes for duplicates)
        $tracksToExtract = @{}
        foreach ($lang in $wantedByLanguage.Keys) {
            $langTracks = $wantedByLanguage[$lang]
            $textTracks = @($langTracks | Where-Object { $_.IsTextSubtitle })

            if ($textTracks.Count -gt 0) {
                if ($DuplicateLanguageMode -eq 'all') {
                    # Extract all text tracks for this language
                    foreach ($t in $textTracks) {
                        $tracksToExtract[$t.Track.Id] = $true
                    }
                    Write-SAVerbose -Text "Selected for extraction ($lang): all $($textTracks.Count) text track(s)"
                } else {
                    # 'largest' mode: prefer non-pattern-matched tracks
                    $preferredTracks = @($textTracks | Where-Object { -not $_.MatchesRemovePattern })

                    if ($preferredTracks.Count -gt 0) {
                        $largest = $preferredTracks | Sort-Object -Property TrackSize -Descending | Select-Object -First 1
                    } else {
                        $largest = $textTracks | Sort-Object -Property TrackSize -Descending | Select-Object -First 1
                        Write-SAVerbose -Text "Using pattern-matched subtitle for $lang - no clean alternative"
                    }

                    $tracksToExtract[$largest.Track.Id] = $true
                    Write-SAVerbose -Text "Selected for extraction: $lang track $($largest.Track.Id) ($($largest.TrackSize) bytes)"
                }
            }
        }
        
        # Now classify all tracks
        foreach ($analysis in $trackAnalysis) {
            $shouldKeep = $analysis.IsWantedLanguage
            $shouldExtract = $tracksToExtract.ContainsKey($analysis.Track.Id)
            
            $trackResult = [PSCustomObject]@{
                Track              = $analysis.Track
                IsWantedLanguage   = $analysis.IsWantedLanguage
                MatchesRemovePattern = $analysis.MatchesRemovePattern
                IsTextSubtitle     = $analysis.IsTextSubtitle
                NormalizedLanguage = $analysis.NormalizedLanguage
                TrackSize          = $analysis.TrackSize
                ShouldKeep         = $shouldKeep
                ShouldExtract      = $shouldExtract
            }
            
            if ($shouldKeep) {
                $wantedTracks.Add($trackResult)
            } else {
                $unwantedTracks.Add($trackResult)
            }
            
            if ($shouldExtract) {
                $extractableTracks.Add($trackResult)
            }
        }
    }
    
    # Log summary
    $extractLangs = ($extractableTracks | ForEach-Object { $_.NormalizedLanguage } | Select-Object -Unique) -join ', '
    if ($extractableTracks.Count -gt 0) {
        Write-SAVerbose -Text "Extraction: $($extractableTracks.Count) track(s) - $extractLangs"
    }
    Write-SAVerbose -Text "MKV: Keeping $($wantedTracks.Count), removing $($unwantedTracks.Count) subtitle tracks"
    
    return [PSCustomObject]@{
        MkvPath           = $MkvInfo.Path
        TotalSubtitles    = $MkvInfo.SubtitleCount
        WantedTracks      = $wantedTracks.ToArray()
        UnwantedTracks    = $unwantedTracks.ToArray()
        ExtractableTracks = $extractableTracks.ToArray()
        # Convenience
        HasUnwantedTracks = ($unwantedTracks.Count -gt 0)
        HasExtractable    = ($extractableTracks.Count -gt 0)
        NeedsStrip        = ($unwantedTracks.Count -gt 0)
        WantedTrackIds    = @($wantedTracks | ForEach-Object { $_.Track.Id })
        UnwantedTrackIds  = @($unwantedTracks | ForEach-Object { $_.Track.Id })
        ExtractTrackIds   = @($extractableTracks | ForEach-Object { $_.Track.Id })
        # New: protection rule triggered
        ProtectionApplied = (-not $hasAnyWantedMatch)
    }
}

function Get-SAVideoFiles {
    <#
    .SYNOPSIS
        Gets video files from a path (file or directory).
    .PARAMETER Path
        Source path (file or directory).
    .PARAMETER Recurse
        Search subdirectories.
    .PARAMETER ExcludeSamples
        Exclude sample files/folders (default: true).
    .OUTPUTS
        Array of FileInfo objects for video files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter()]
        [switch]$Recurse,
        
        [Parameter()]
        [bool]$ExcludeSamples = $true
    )
    
    $videoExtensions = $script:SAConstants.VideoExtensions
    $results = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        # Single file
        $file = Get-Item -LiteralPath $Path
        $ext = $file.Extension.ToLower()
        
        if ($ext -in $videoExtensions) {
            if (-not $ExcludeSamples -or -not (Test-SASamplePath -Path $file.FullName)) {
                $results.Add($file)
            }
        }
    } elseif (Test-Path -LiteralPath $Path -PathType Container) {
        # Directory
        $searchParams = @{
            LiteralPath = $Path
            File        = $true
        }
        
        if ($Recurse) {
            $searchParams.Recurse = $true
        }
        
        $files = Get-ChildItem @searchParams | Where-Object {
            $_.Extension.ToLower() -in $videoExtensions
        }
        
        foreach ($file in $files) {
            if (-not $ExcludeSamples -or -not (Test-SASamplePath -Path $file.FullName)) {
                $results.Add($file)
            }
        }
    }
    
    return $results.ToArray()
}

function Test-SAIsMP4 {
    <#
    .SYNOPSIS
        Tests if a file is an MP4.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    return ($ext -in @('.mp4', '.m4v'))
}

function Test-SAIsMKV {
    <#
    .SYNOPSIS
        Tests if a file is an MKV.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    return ($ext -eq '.mkv')
}

function Get-SAOutputFileName {
    <#
    .SYNOPSIS
        Gets the output filename, changing extension if needed.
    .PARAMETER SourcePath
        Source file path.
    .PARAMETER NewExtension
        New extension (with dot, e.g., '.mkv').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter()]
        [string]$NewExtension = '.mkv'
    )
    
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    return "$baseName$NewExtension"
}

function Get-SASrtFileName {
    <#
    .SYNOPSIS
        Generates SRT filename with language code.
    .PARAMETER VideoPath
        Path to the video file.
    .PARAMETER LanguageCode
        Language code (will be normalized to ISO 639-1).
    .PARAMETER TrackIndex
        Optional track index for multiple same-language tracks.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath,
        
        [Parameter(Mandatory = $true)]
        [string]$LanguageCode,
        
        [Parameter()]
        [int]$TrackIndex = 0
    )
    
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    $normalizedLang = ConvertTo-SALanguageCode -Code $LanguageCode -To 'iso1'
    
    if ([string]::IsNullOrWhiteSpace($normalizedLang)) {
        $normalizedLang = 'und'
    }
    
    if ($TrackIndex -gt 0) {
        return "$baseName.$normalizedLang.$TrackIndex.srt"
    }
    
    return "$baseName.$normalizedLang.srt"
}
