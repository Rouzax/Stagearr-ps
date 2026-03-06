#Requires -Version 5.1
<#
.SYNOPSIS
    Media filename parsing and release info extraction.
.DESCRIPTION
    Parse scene-style release names to extract metadata:
    - TV episode detection (S01E02, 1x02, season packs)
    - Movie detection (Title.Year.Quality)
    - Quality/source extraction (BluRay, WEB-DL, 1080p)
    - Release group identification
    - Streaming service detection
    
    Supports both offline regex parsing and optional OpenSubtitles GuessIt API integration.
    
    Used by: JobProcessor.ps1 (friendly name), EmailRenderer.ps1 (subject line),
             Subtitles.ps1 (language detection from filename)
#>

function Get-SAMediaInfo {
    <#
    .SYNOPSIS
        Parses a media filename to extract metadata and friendly name.
    .DESCRIPTION
        Offline parser for scene-style release names. Detects whether the file is 
        a TV episode or movie and extracts relevant metadata for subtitle search 
        and display purposes.
        
        Patterns recognized:
        - TV: S01E02, S1E2, 1x02, etc.
        - Movie: Title.Year.Quality... or Title (Year)
        
        Also extracts: resolution, streaming service, release group, and special tags.
    .PARAMETER FileName
        The filename to parse (with or without extension).
    .OUTPUTS
        PSCustomObject with: Type, Title, FriendlyName, Year, Season, Episode,
        ScreenSize, StreamingService, ReleaseGroup, Other, Source
    .EXAMPLE
        Get-SAMediaInfo -FileName "Sleepers.NL.S02E08.1080p.WEB-DL.mkv"
        # Returns: Type=episode, Title=Sleepers NL, FriendlyName=Sleepers NL S02E08, 
        #          Season=2, Episode=8, ScreenSize=1080p, Source=WEB
    .EXAMPLE
        Get-SAMediaInfo -FileName "The.Matrix.1999.BluRay.1080p.x264-GRP.mkv"
        # Returns: Type=movie, Title=The Matrix, FriendlyName=The Matrix (1999), 
        #          Year=1999, ScreenSize=1080p, ReleaseGroup=GRP, Source=BluRay
    .EXAMPLE
        Get-SAMediaInfo -FileName "Movie.2024.2160p.NF.WEB-DL.HDR.REMUX-GROUP.mkv"
        # Returns: ScreenSize=2160p, StreamingService=NF, ReleaseGroup=GROUP, 
        #          Other=@('HDR', 'REMUX'), Source=Remux
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )
    
    # Only remove known video extensions (not arbitrary extensions like .265)
    # This prevents folder names like "Movie.H.265-GROUP" from losing the release group
    $baseName = $FileName -replace '(?i)\.(mkv|mp4|avi|m4v|wmv|ts|mov)$', ''
    
    # Initialize result with extended fields
    $result = [PSCustomObject]@{
        Type             = $null      # 'episode' or 'movie'
        Title            = $null      # Clean title without year/season info
        FriendlyName     = $null      # Display name (Title + year or season)
        Year             = $null      # Release year (movie)
        Season           = $null      # Season number (TV only)
        Episode          = $null      # Episode number (TV only)
        ScreenSize       = $null      # Resolution: '2160p', '1080p', '720p', etc.
        StreamingService = $null      # Streaming service abbreviation: 'NF', 'AMZN', 'HMAX', etc.
        ReleaseGroup     = $null      # Release group name
        Other            = $null      # Array of other tags: 'Remux', 'HDR', 'Proper', etc.
        Source           = $null      # Source type: 'BluRay', 'WEB', 'HDTV', etc.
    }
    
    # Pattern 1: TV - S01E02 or S1E2 format (most common)
    if ($baseName -match '(?i)(.*?)[.\s_-](S(\d{1,2})E(\d{1,2}))') {
        $result.Type = 'episode'
        $result.Title = ($Matches[1] -replace '[._]', ' ').Trim()
        $result.Season = [int]$Matches[3]
        $result.Episode = [int]$Matches[4]
        $result.FriendlyName = "$($result.Title) $($Matches[2].ToUpper())"
    }
    # Pattern 2: TV - Season pack S01 format (no episode)
    elseif ($baseName -match '(?i)(.*?)[.\s_-](S(\d{1,2}))[.\s_-](?!E)') {
        $result.Type = 'episode'
        $result.Title = ($Matches[1] -replace '[._]', ' ').Trim()
        $result.Season = [int]$Matches[3]
        $result.FriendlyName = "$($result.Title) $($Matches[2].ToUpper())"
    }
    # Pattern 3: TV - 1x02 format
    elseif ($baseName -match '(?i)(.*?)[.\s_-](\d{1,2})x(\d{2,3})') {
        $result.Type = 'episode'
        $result.Title = ($Matches[1] -replace '[._]', ' ').Trim()
        $result.Season = [int]$Matches[2]
        $result.Episode = [int]$Matches[3]
        $seasonEp = "S{0:D2}E{1:D2}" -f $result.Season, $result.Episode
        $result.FriendlyName = "$($result.Title) $seasonEp"
    }
    # Pattern 4: Movie - has a year (19xx or 20xx)
    elseif ($baseName -match '(?i)(.*?)[.\s_\[\(]((?:19|20)\d{2})[.\s_\]\)]') {
        $result.Type = 'movie'
        $result.Title = ($Matches[1] -replace '[._]', ' ').Trim()
        $result.Year = [int]$Matches[2]
        $result.FriendlyName = "$($result.Title) ($($result.Year))"
    }
    # Pattern 5: Unknown - try to extract title before quality markers
    else {
        $qualityMarkers = @(
            '1080p', '720p', '2160p', '4K', 'UHD',
            'BluRay', 'Blu-Ray', 'BDRip', 'BRRip', 'REMUX',
            'WEB-DL', 'WEBDL', 'WEBRip', 'WEB',
            'HDRip', 'HDTV', 'DVDRip', 'DVDScr',
            'x264', 'x265', 'H\.264', 'H\.265', 'HEVC', 'AVC',
            'PROPER', 'REPACK', 'REAL', 'iNTERNAL'
        )
        
        $title = $baseName
        foreach ($marker in $qualityMarkers) {
            if ($title -match "(?i)[.\s_-]$marker") {
                $matchIndex = $title.ToLower().IndexOf($Matches[0].ToLower())
                if ($matchIndex -gt 0) {
                    $title = $title.Substring(0, $matchIndex)
                    break
                }
            }
        }
        
        # Last resort - remove group tag at end (anything after last dash)
        $title = $title -replace '-[^-]+$', ''
        $title = ($title -replace '[._]', ' ').Trim(' -')
        
        if (-not [string]::IsNullOrWhiteSpace($title) -and $title.Length -ge 2) {
            $result.Title = $title
            $result.FriendlyName = $title
        } else {
            # If all parsing fails, use original name
            $result.Title = $baseName
            $result.FriendlyName = $baseName
        }
    }
    
    #region Extended Field Extraction
    # These fields are extracted from the full basename regardless of media type
    
    # ScreenSize (resolution): 2160p, 1080p, 720p, 480p, 4K
    if ($baseName -match '(?i)\b(2160p|1080p|720p|480p|4K)\b') {
        $result.ScreenSize = $Matches[1]
        # Normalize 4K to 2160p for consistency
        if ($result.ScreenSize -eq '4K') {
            $result.ScreenSize = '2160p'
        }
    }
    
    # ReleaseGroup: typically after the last dash, before extension
    # Pattern: matches -GroupName at end
    if ($baseName -match '(?i)-([A-Za-z0-9]+)$') {
        $group = $Matches[1]
        # Validate it's not a common false positive (codec/audio names)
        $falsePositives = @(
            'x264', 'x265', 'H264', 'H265', 'HEVC', 'AVC',
            'AAC', 'DTS', 'TrueHD', 'Atmos', 'DD', 'DDP', 'FLAC'
        )
        if ($group -notin $falsePositives -and $group.Length -ge 2 -and $group.Length -le 20) {
            $result.ReleaseGroup = $group
        }
    }
    
    # StreamingService: Common streaming service abbreviations
    # Map patterns to canonical abbreviations (scene naming convention)
    # These abbreviations are used directly in email subjects and display
    $streamingPatterns = @{
        '(?i)\bNF\b'       = 'NF'
        '(?i)\bNETFLIX\b'  = 'NF'
        '(?i)\bAMZN\b'     = 'AMZN'
        '(?i)\bAMAZON\b'   = 'AMZN'
        '(?i)\bDSNP\b'     = 'DSNP'
        '(?i)\bDSNY\b'     = 'DSNP'
        '(?i)\bDISNEY\b'   = 'DSNP'
        '(?i)\bHMAX\b'     = 'HMAX'
        '(?i)\bHBO\b'      = 'HBO'
        '(?i)\bHULU\b'     = 'HULU'
        '(?i)\bAPTV\b'     = 'ATVP'
        '(?i)\bATVP\b'     = 'ATVP'
        '(?i)\bPCOK\b'     = 'PCOK'
        '(?i)\bPMTP\b'     = 'PMTP'
        '(?i)\bSHOUT\b'    = 'SHOUT'
        '(?i)\bRED\b'      = 'RED'
        '(?i)\bIT\b'       = 'iT'
        '(?i)\bCRAV\b'     = 'CRAV'
        '(?i)\bSTAN\b'     = 'STAN'
    }
    
    foreach ($pattern in $streamingPatterns.Keys) {
        if ($baseName -match $pattern) {
            $result.StreamingService = $streamingPatterns[$pattern]
            break
        }
    }
    
    # Other: Special tags like Remux, HDR, Proper, REPACK, etc.
    $otherTags = @()
    $otherPatterns = @(
        'REMUX',
        'HDR10\+?',
        'HDR',
        'DV',          # Dolby Vision
        'PROPER',
        'REPACK',
        'REAL',
        'INTERNAL',
        'HYBRID',
        'EXTENDED',
        'UNRATED',
        'DC',          # Director's Cut
        'IMAX',
        'CRITERION'
    )
    
    foreach ($tag in $otherPatterns) {
        if ($baseName -match "(?i)\b$tag\b") {
            # Normalize to uppercase
            $matched = $Matches[0].ToUpper()
            # Special handling for HDR10+ to preserve the plus
            if ($baseName -match '(?i)\bHDR10\+') {
                $matched = 'HDR10+'
            }
            if ($matched -notin $otherTags) {
                $otherTags += $matched
            }
        }
    }
    
    if ($otherTags.Count -gt 0) {
        $result.Other = $otherTags
    }
    
    # Source: Media source type (BluRay, WEB, HDTV, etc.)
    # Order matters - more specific patterns first
    $sourcePatterns = [ordered]@{
        'Remux'    = '(?i)\b(remux)\b'
        'BluRay'   = '(?i)\b(blu-?ray|bdremux|bdrip|brrip)\b'
        'WEB'      = '(?i)\b(web-?dl|webrip|web)\b'
        'HDTV'     = '(?i)\b(hdtv)\b'
        'DVDRip'   = '(?i)\b(dvdrip|dvdscr)\b'
    }
    
    foreach ($src in $sourcePatterns.Keys) {
        if ($baseName -match $sourcePatterns[$src]) {
            $result.Source = $src
            break
        }
    }
    #endregion
    
    return $result
}

function Get-SAGuessItInfo {
    <#
    .SYNOPSIS
        Calls OpenSubtitles GuessIt API to parse a release name.
    .DESCRIPTION
        Uses the OpenSubtitles.com GuessIt utility endpoint to parse scene-style
        release names. Returns structured metadata including title, year, season,
        episode, media type, and additional fields for email subject formatting.
        
        Requires OpenSubtitles API key to be configured.
    .PARAMETER FileName
        The filename to parse.
    .PARAMETER ApiKey
        OpenSubtitles API key.
    .OUTPUTS
        PSCustomObject with: Type, Title, FriendlyName, Year, Season, Episode, 
        Language, Source, ScreenSize, StreamingService, ReleaseGroup, Other
        Returns $null if API call fails.
    .EXAMPLE
        Get-SAGuessItInfo -FileName "Sleepers.NL.S02E08.1080p.WEB-DL.mkv" -ApiKey "xxx"
    .EXAMPLE
        Get-SAGuessItInfo -FileName "Stranger.Things.S05.2160p.NF.WEB-DL.DDP5.1.DV.HDR.H.265-NTb" -ApiKey "xxx"
        # Returns: ScreenSize=2160p, StreamingService=Netflix, ReleaseGroup=NTb
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        
        [Parameter(Mandatory = $true)]
        [string]$ApiKey
    )
    
    # Build API URL with encoded filename
    $encodedName = [System.Uri]::EscapeDataString($FileName)
    $uri = "https://api.opensubtitles.com/api/v1/utilities/guessit?filename=$encodedName"
    
    $headers = @{
        'Api-Key'      = $ApiKey
        'Content-Type' = 'application/json'
        'User-Agent'   = 'Stagearr v2.0.0'
    }
    
    try {
        $response = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -MaxRetries 2 -TimeoutSeconds 10
        
        if (-not $response.Success -or $null -eq $response.Data) {
            Write-SAVerbose -Text "GuessIt API failed: $($response.ErrorMessage)"
            return $null
        }
        
        $data = $response.Data
        
        # Handle 'other' field which can be a string or array from API
        $otherValue = $null
        if ($null -ne $data.other) {
            if ($data.other -is [array]) {
                $otherValue = $data.other
            } else {
                $otherValue = @($data.other)
            }
        }
        
        # Build result from API response
        $result = [PSCustomObject]@{
            Type             = $data.type           # 'episode' or 'movie'
            Title            = $data.title
            FriendlyName     = $null
            Year             = $data.year
            Season           = $data.season
            Episode          = $data.episode
            Language         = $data.language
            Source           = $data.source
            # New fields for email subject suffix
            ScreenSize       = $data.screen_size        # "2160p", "1080p"
            StreamingService = $data.streaming_service  # "Netflix", "Amazon Prime"
            ReleaseGroup     = $data.release_group      # "NTb", "BLOOM"
            Other            = $otherValue              # Array: "Remux", "HDR10", etc.
        }
        
        # Build friendly name based on type
        if ($result.Type -eq 'episode') {
            $seasonEp = ''
            if ($null -ne $result.Season) {
                $seasonEp = "S{0:D2}" -f [int]$result.Season
                if ($null -ne $result.Episode) {
                    $seasonEp += "E{0:D2}" -f [int]$result.Episode
                }
            }
            $result.FriendlyName = if ($seasonEp) { "$($result.Title) $seasonEp" } else { $result.Title }
        }
        elseif ($result.Type -eq 'movie') {
            $result.FriendlyName = if ($result.Year) { "$($result.Title) ($($result.Year))" } else { $result.Title }
        }
        else {
            $result.FriendlyName = $result.Title
        }
        
        # Log extended info in verbose mode
        $verboseDetails = @()
        if ($result.ScreenSize) { $verboseDetails += "res=$($result.ScreenSize)" }
        if ($result.StreamingService) { $verboseDetails += "service=$($result.StreamingService)" }
        if ($result.ReleaseGroup) { $verboseDetails += "group=$($result.ReleaseGroup)" }
        
        $verboseText = "GuessIt: $($result.FriendlyName) (type=$($result.Type)"
        if ($verboseDetails.Count -gt 0) {
            $verboseText += ", $($verboseDetails -join ', ')"
        }
        $verboseText += ")"
        Write-SAVerbose -Text $verboseText
        
        return $result
        
    } catch {
        Write-SAVerbose -Text "GuessIt API error: $_"
        return $null
    }
}

function Get-SAReleaseInfo {
    <#
    .SYNOPSIS
        Gets release metadata, trying OpenSubtitles GuessIt API first with local fallback.
    .DESCRIPTION
        Wrapper function that attempts to parse a release name using the OpenSubtitles
        GuessIt API for accurate results. Falls back to local Get-SAMediaInfo parsing
        if the API is unavailable or not configured.
        
        Both sources return the same structure with fields for email subject formatting.
    .PARAMETER FileName
        The filename to parse.
    .PARAMETER Config
        Configuration object containing OpenSubtitles settings.
    .OUTPUTS
        PSCustomObject with: Type, Title, FriendlyName, Year, Season, Episode,
        ScreenSize, StreamingService, ReleaseGroup, Other, Source
    .EXAMPLE
        $info = Get-SAReleaseInfo -FileName "Movie.2024.1080p.mkv" -Config $Context.Config
    .EXAMPLE
        $info = Get-SAReleaseInfo -FileName "Stranger.Things.S05.2160p.NF.WEB-DL-NTb.mkv" -Config $config
        # Returns: ScreenSize=2160p, StreamingService=Netflix, ReleaseGroup=NTb
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        
        [Parameter()]
        [object]$Config
    )
    
    # Try GuessIt API if OpenSubtitles is enabled and configured
    if ($Config -and 
        $Config.subtitles -and 
        $Config.subtitles.openSubtitles -and
        $Config.subtitles.openSubtitles.enabled -and
        -not [string]::IsNullOrWhiteSpace($Config.subtitles.openSubtitles.apiKey)) {
        
        $apiKey = $Config.subtitles.openSubtitles.apiKey
        $result = Get-SAGuessItInfo -FileName $FileName -ApiKey $apiKey
        
        if ($null -ne $result -and -not [string]::IsNullOrWhiteSpace($result.FriendlyName)) {
            return $result
        }
    }
    
    # Fallback to local parsing
    $localResult = Get-SAMediaInfo -FileName $FileName
    
    # Build verbose details for local parsing result (similar to GuessIt verbose)
    $verboseDetails = @()
    if ($localResult.Type) { $verboseDetails += "type=$($localResult.Type)" }
    if ($localResult.ScreenSize) { $verboseDetails += "res=$($localResult.ScreenSize)" }
    if ($localResult.StreamingService) { $verboseDetails += "service=$($localResult.StreamingService)" }
    if ($localResult.ReleaseGroup) { $verboseDetails += "group=$($localResult.ReleaseGroup)" }
    if ($localResult.Source) { $verboseDetails += "source=$($localResult.Source)" }
    
    if ($verboseDetails.Count -gt 0) {
        $detailStr = $verboseDetails -join ', '
        Write-SAVerbose -Label "Local" -Text "$($localResult.FriendlyName) ($detailStr)"
    }
    
    return $localResult
}

function Get-SAFileEpisodeInfo {
    <#
    .SYNOPSIS
        Parses a filename into structured episode information.
    .DESCRIPTION
        Extracts season/episode data from a video filename using Get-SAMediaInfo.
        Returns a structured object suitable for import result tracking.
        Returns null if parsing fails (graceful degradation).
        
        This is a generic helper that can be used by any importer (Medusa, Sonarr, etc.)
        to extract episode details from filenames for display and reporting.
    .PARAMETER Filename
        The video filename to parse.
    .PARAMETER Reason
        Optional reason text (for skip/abort tracking).
    .OUTPUTS
        PSCustomObject with Filename, Season, Episode, Reason properties.
        Returns null if parsing fails.
    .EXAMPLE
        Get-SAFileEpisodeInfo -Filename "Show.S02E08.mkv"
        # Returns: @{Filename='Show.S02E08.mkv'; Season=2; Episode=8; Reason=''}
    .EXAMPLE
        Get-SAFileEpisodeInfo -Filename "Movie.2024.mkv" -Reason "Quality exists"
        # Returns: @{Filename='Movie.2024.mkv'; Season=$null; Episode=$null; Reason='Quality exists'}
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filename,
        
        [Parameter()]
        [string]$Reason = ''
    )
    
    try {
        # Use existing Get-SAMediaInfo for parsing
        $mediaInfo = Get-SAMediaInfo -FileName $Filename
        
        # Only include if we got episode info
        if ($mediaInfo.Type -eq 'episode' -and $null -ne $mediaInfo.Season) {
            return [PSCustomObject]@{
                Filename = $Filename
                Season   = $mediaInfo.Season
                Episode  = $mediaInfo.Episode
                Reason   = $Reason
            }
        }
        
        # For movies or unknown, still include with null episode
        return [PSCustomObject]@{
            Filename = $Filename
            Season   = $mediaInfo.Season
            Episode  = $mediaInfo.Episode
            Reason   = $Reason
        }
    }
    catch {
        # Graceful degradation - return null if parsing fails
        Write-SAVerbose -Label "Parser" -Text "Failed to parse: $Filename"
        return $null
    }
}
