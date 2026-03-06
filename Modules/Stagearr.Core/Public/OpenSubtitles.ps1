#Requires -Version 5.1
<#
.SYNOPSIS
    OpenSubtitles.com API integration.
.DESCRIPTION
    Functions for interacting with OpenSubtitles.com REST API:
    - Authentication token management (login, refresh, persistence)
    - Subtitle search by video hash and filename
    - Subtitle download with rate limiting
    
    API Reference: https://opensubtitles.stoplight.io/
    
    Requires: Valid OpenSubtitles.com API credentials in config
    
    Rate Limits:
    - Search: 40 requests/10 seconds
    - Download: 20 requests/24 hours (free tier)
#>

# Module-level token cache
$script:SAOpenSubtitlesToken = $null
$script:SAOpenSubtitlesTokenExpiry = $null
$script:SAOpenSubtitlesTokenFile = $null

function Get-SAOpenSubtitlesTokenPath {
    <#
    .SYNOPSIS
        Gets the path to the OpenSubtitles token cache file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$CacheFolder
    )
    
    if ([string]::IsNullOrWhiteSpace($CacheFolder)) {
        # Default to user's temp folder
        $CacheFolder = [System.IO.Path]::GetTempPath()
    }
    
    return Join-Path -Path $CacheFolder -ChildPath 'opensubtitles-token.json'
}

function Get-SAOpenSubtitlesToken {
    <#
    .SYNOPSIS
        Gets or refreshes OpenSubtitles API authentication token.
    .DESCRIPTION
        Authenticates with OpenSubtitles REST API and caches the token.
        Token is cached both in memory and on disk for persistence across sessions.
        Token is refreshed when expired or invalid.
    .PARAMETER Config
        OpenSubtitles configuration hashtable.
    .PARAMETER CacheFolder
        Folder to store token cache file (default: temp folder).
    .PARAMETER ForceRefresh
        Force token refresh even if cached token is valid.
    .OUTPUTS
        Authentication token string, or $null on failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter()]
        [string]$CacheFolder,
        
        [Parameter()]
        [switch]$ForceRefresh
    )
    
    $tokenPath = Get-SAOpenSubtitlesTokenPath -CacheFolder $CacheFolder
    
    # Check memory cache first
    if (-not $ForceRefresh -and $script:SAOpenSubtitlesToken) {
        if ($null -eq $script:SAOpenSubtitlesTokenExpiry -or (Get-Date) -lt $script:SAOpenSubtitlesTokenExpiry) {
            return $script:SAOpenSubtitlesToken
        }
    }
    
    # Check disk cache if memory is empty
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $tokenPath)) {
        try {
            $cached = Get-Content -LiteralPath $tokenPath -Raw | ConvertFrom-Json
            # Parse using invariant culture (handles ISO 8601 and other formats)
            $expiry = [DateTime]::Parse($cached.expiry, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            
            if ((Get-Date) -lt $expiry) {
                # Valid cached token found
                $script:SAOpenSubtitlesToken = $cached.token
                $script:SAOpenSubtitlesTokenExpiry = $expiry
                Write-SAVerbose -Text "Using cached OpenSubtitles token (expires: $($expiry.ToString('yyyy-MM-dd HH:mm')))"
                return $script:SAOpenSubtitlesToken
            }
        } catch {
            Write-SAVerbose -Text "Failed to read token cache: $_"
        }
    }
    
    # Validate config
    if ([string]::IsNullOrWhiteSpace($Config.user) -or 
        [string]::IsNullOrWhiteSpace($Config.password) -or
        [string]::IsNullOrWhiteSpace($Config.apiKey)) {
        Write-SAVerbose -Text "OpenSubtitles credentials missing"
        return $null
    }
    
    Write-SAVerbose -Text "Authenticating with OpenSubtitles..."
    
    $uri = 'https://api.opensubtitles.com/api/v1/login'
    $headers = @{
        'Api-Key'      = $Config.apiKey
        'Content-Type' = 'application/json'
        'Accept'       = 'application/json'
        'User-Agent'   = 'Stagearr v2.0'
    }
    
    $body = @{
        username = $Config.user
        password = $Config.password
    }
    
    $result = Invoke-SAWebRequest -Uri $uri -Method POST -Headers $headers -Body $body -MaxRetries 3
    
    if ($result.Success -and $result.Data.token) {
        $script:SAOpenSubtitlesToken = $result.Data.token
        # Token valid for 24 hours, refresh after 23
        $script:SAOpenSubtitlesTokenExpiry = (Get-Date).AddHours(23)
        
        # Save to disk cache
        try {
            $cacheData = @{
                token  = $script:SAOpenSubtitlesToken
                expiry = $script:SAOpenSubtitlesTokenExpiry.ToString('o')
            }
            $cacheData | ConvertTo-Json | Set-Content -LiteralPath $tokenPath -Encoding UTF8 -Force
            Write-SAVerbose -Text "Token cached to: $tokenPath"
        } catch {
            Write-SAVerbose -Text "Failed to cache token: $_"
        }
        
        Write-SAVerbose -Text "OpenSubtitles authenticated"
        return $script:SAOpenSubtitlesToken
    }
    
    Write-SAOutcome -Level Warning -Label "OpenSubs" -Text "Authentication failed" -Indent 1
    return $null
}

function Search-SAOpenSubtitles {
    <#
    .SYNOPSIS
        Searches OpenSubtitles for subtitles matching a video.
    .DESCRIPTION
        Uses video hash and/or filename to find matching subtitles.
        Applies configured filters for hearing impaired, forced, etc.
    .PARAMETER Config
        OpenSubtitles configuration hashtable.
    .PARAMETER VideoPath
        Path to the video file (used for filename and fallback hash).
    .PARAMETER Languages
        Array of language codes to search for.
    .PARAMETER MovieHash
        Pre-computed video hash (preferred - use hash from before remuxing).
    .OUTPUTS
        Array of subtitle result objects.
    .EXAMPLE
        $results = Search-SAOpenSubtitles -Config $config -VideoPath "movie.mkv" -Languages @('en', 'nl')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$VideoPath,
        
        [Parameter(Mandatory = $true)]
        [string[]]$Languages,
        
        [Parameter()]
        [string]$MovieHash
    )
    
    # Get token
    $token = Get-SAOpenSubtitlesToken -Config $Config
    if (-not $token) {
        return @()
    }
    
    # Compute hash if not provided (fallback - may be wrong if file was remuxed)
    if ([string]::IsNullOrWhiteSpace($MovieHash)) {
        Write-SAVerbose -Text "Computing OpenSubtitles hash from video file..."
        $MovieHash = Get-SAVideoHash -Path $VideoPath
    }
    # Hash is already displayed by caller in condensed format - no need to log again
    
    $fileName = Split-Path -Path $VideoPath -Leaf
    
    # Normalize languages to ISO 639-1
    $langCodes = $Languages | ForEach-Object {
        $code = ConvertTo-SALanguageCode -Code $_ -To 'iso1'
        if ($code) { $code }
    } | Select-Object -Unique
    
    if ($langCodes.Count -eq 0) {
        Write-SAVerbose -Text "No valid language codes"
        return @()
    }
    
    $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    # Parse filename once to extract structured metadata for filtering
    $mediaInfo = Get-SAMediaInfo -FileName $fileName
    
    # Log parsed info once (used for filters, not query replacement)
    if ($mediaInfo.Type -eq 'episode') {
        Write-SAVerbose -Text "Detected: TV S$($mediaInfo.Season)E$($mediaInfo.Episode)"
    }
    elseif ($mediaInfo.Type -eq 'movie' -and $mediaInfo.Year) {
        Write-SAVerbose -Text "Detected: Movie ($($mediaInfo.Year))"
    }
    
    foreach ($lang in $langCodes) {
        # Build query parameters
        $queryParams = @{
            languages = $lang
        }
        
        if ($MovieHash) {
            $queryParams.moviehash = $MovieHash
        }
        
        # Always include the full filename as query (recommended by OpenSubtitles API)
        # The hash does primary matching; filename helps with release-specific matching
        $queryParams.query = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        
        # Add structured parameters as FILTERS (not replacements for query)
        # These narrow down results to the correct episode/movie
        if ($mediaInfo.Type -eq 'episode') {
            $queryParams.season_number = $mediaInfo.Season
            $queryParams.episode_number = $mediaInfo.Episode
            $queryParams.type = 'episode'
        }
        elseif ($mediaInfo.Type -eq 'movie' -and $mediaInfo.Year) {
            $queryParams.year = $mediaInfo.Year
            $queryParams.type = 'movie'
        }
        
        # Apply filters from config
        $filters = $Config.filters
        if ($filters) {
            if ($filters.hearingImpaired -eq 'exclude') {
                $queryParams.hearing_impaired = 'exclude'
            } elseif ($filters.hearingImpaired -eq 'only') {
                $queryParams.hearing_impaired = 'only'
            }
            
            if ($filters.foreignPartsOnly -eq 'exclude') {
                $queryParams.foreign_parts_only = 'exclude'
            } elseif ($filters.foreignPartsOnly -eq 'only') {
                $queryParams.foreign_parts_only = 'only'
            }
            
            if ($filters.machineTranslated -eq 'exclude') {
                $queryParams.machine_translated = 'exclude'
            }
            
            if ($filters.aiTranslated -eq 'exclude') {
                $queryParams.ai_translated = 'exclude'
            }
        }
        
        # Build URL with query string
        $queryString = ($queryParams.GetEnumerator() | ForEach-Object { 
            "$($_.Key)=$([System.Uri]::EscapeDataString($_.Value))" 
        }) -join '&'
        
        $uri = "https://api.opensubtitles.com/api/v1/subtitles?$queryString"
        
        $headers = @{
            'Api-Key'       = $Config.apiKey
            'Authorization' = "Bearer $token"
            'Accept'        = 'application/json'
            'User-Agent'    = 'Stagearr v2.0'
        }
        
        $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -MaxRetries 3
        
        if ($result.Success -and $result.Data.data) {
            foreach ($sub in $result.Data.data) {
                $subResult = [PSCustomObject]@{
                    Id              = $sub.id
                    Language        = $lang
                    LanguageName    = $sub.attributes.language
                    FileId          = $sub.attributes.files[0].file_id
                    FileName        = $sub.attributes.files[0].file_name
                    Downloads       = $sub.attributes.download_count
                    Rating          = $sub.attributes.ratings
                    HearingImpaired = $sub.attributes.hearing_impaired
                    ForeignPartsOnly = $sub.attributes.foreign_parts_only
                    MachineTranslated = $sub.attributes.machine_translated
                    AiTranslated    = $sub.attributes.ai_translated
                    Release         = $sub.attributes.release
                    UploadDate      = $sub.attributes.upload_date
                    # For hash matches, this will be set
                    HashMatch       = ($sub.attributes.moviehash_match -eq $true)
                }
                
                $allResults.Add($subResult)
            }
            
            $resultWord = Get-SAPluralForm -Count $result.Data.data.Count -Singular 'result'
            Write-SAVerbose -Text "Found $($result.Data.data.Count) $resultWord for '$lang'"
        } elseif ($result.StatusCode -eq 429) {
            Write-SAVerbose -Text "Rate limited, waiting..."
            Start-Sleep -Seconds 5
        }
    }
    
    # Sort: hash matches first, then by downloads
    $sorted = $allResults | Sort-Object -Property @{Expression={$_.HashMatch}; Descending=$true}, 
                                                   @{Expression={$_.Downloads}; Descending=$true}
    
    return $sorted
}

function Get-SAOpenSubtitlesDownload {
    <#
    .SYNOPSIS
        Downloads a subtitle file from OpenSubtitles.
    .DESCRIPTION
        Requests download link and retrieves the subtitle file.
        Handles rate limiting, download quotas, and token invalidation (401).
        If token is rejected, automatically refreshes and retries once.
    .PARAMETER Config
        OpenSubtitles configuration hashtable.
    .PARAMETER FileId
        OpenSubtitles file ID to download.
    .PARAMETER OutputPath
        Path to save the downloaded subtitle.
    .OUTPUTS
        $true if successful, $false otherwise.
    .EXAMPLE
        $success = Get-SAOpenSubtitlesDownload -Config $config -FileId 12345 -OutputPath "movie.en.srt"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [int]$FileId,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )
    
    # Get token
    $token = Get-SAOpenSubtitlesToken -Config $Config
    if (-not $token) {
        return $false
    }
    
    # Request download link
    $uri = 'https://api.opensubtitles.com/api/v1/download'
    $body = @{
        file_id = $FileId
    }
    
    # Try the request, with one retry on 401 (token invalidated server-side)
    $tokenRefreshed = $false
    
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $headers = @{
            'Api-Key'       = $Config.apiKey
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
            'Accept'        = 'application/json'
            'User-Agent'    = 'Stagearr v2.0'
        }
        
        # Use MaxRetries 1 here - we handle 401 retry ourselves
        $result = Invoke-SAWebRequest -Uri $uri -Method POST -Headers $headers -Body $body -MaxRetries 1
        
        # Handle 401 - token may have been invalidated server-side
        if (-not $result.Success -and $result.StatusCode -eq 401 -and -not $tokenRefreshed) {
            Write-SAVerbose -Text "Token rejected (HTTP 401), refreshing authentication..."
            
            # Force a new login
            $token = Get-SAOpenSubtitlesToken -Config $Config -ForceRefresh
            if (-not $token) {
                Write-SAVerbose -Text "Failed to refresh token - check credentials"
                return $false
            }
            
            $tokenRefreshed = $true
            Write-SAVerbose -Text "Token refreshed successfully, retrying download..."
            continue
        }
        
        # Exit loop on success or non-401 errors
        break
    }
    
    if (-not $result.Success) {
        if ($result.StatusCode -eq 429) {
            Write-SAVerbose -Text "Download quota exceeded"
        } elseif ($result.StatusCode -eq 401) {
            Write-SAVerbose -Text "Authentication failed after refresh - check OpenSubtitles credentials"
        } else {
            Write-SAVerbose -Text "Failed to get download link (HTTP $($result.StatusCode)): $($result.ErrorMessage)"
        }
        return $false
    }
    
    $downloadLink = $result.Data.link
    if ([string]::IsNullOrWhiteSpace($downloadLink)) {
        Write-SAVerbose -Text "No download link in response"
        return $false
    }
    
    # Log remaining downloads
    if ($result.Data.remaining) {
        Write-SAVerbose -Text "Downloads remaining today: $($result.Data.remaining)"
    }
    
    try {
        # Ensure output directory exists
        $outputDir = Split-Path -Path $OutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
            New-SADirectory -Path $outputDir
        }
        
        # Download using Invoke-WebRequest for binary handling
        $downloadParams = @{
            Uri     = $downloadLink
            OutFile = $OutputPath
        }
        
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $downloadParams.UseBasicParsing = $true
        }
        
        Invoke-WebRequest @downloadParams -ErrorAction Stop -Verbose:$false
        
        if (Test-Path -LiteralPath $OutputPath) {
            return $true
        }
        
    } catch {
        Write-SAVerbose -Text "Download failed: $_"
    }
    
    return $false
}

function Start-SAOpenSubtitlesDownload {
    <#
    .SYNOPSIS
        Main entry point for downloading subtitles from OpenSubtitles.
    .DESCRIPTION
        Searches for and downloads subtitles for a video file.
        Respects configured languages and filters.
    .PARAMETER Context
        Processing context.
    .PARAMETER VideoPath
        Path to the video file (for naming and fallback hash).
    .PARAMETER MovieHash
        Pre-computed OpenSubtitles hash (preferred, avoids re-computation).
    .PARAMETER OutputFolder
        Folder to save downloaded subtitles.
    .PARAMETER Languages
        Languages to search for (uses config if not specified).
    .PARAMETER MaxPerLanguage
        Maximum subtitles to download per language (default: 1).
    .OUTPUTS
        Array of downloaded subtitle file paths.
    .EXAMPLE
        $srtFiles = Start-SAOpenSubtitlesDownload -Context $ctx -VideoPath "movie.mkv" -OutputFolder "C:\Staging"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$VideoPath,
        
        [Parameter()]
        [string]$MovieHash,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,
        
        [Parameter()]
        [string[]]$Languages,
        
        [Parameter()]
        [int]$MaxPerLanguage = 1
    )
    
    $config = $Context.Config.subtitles.openSubtitles
    
    if (-not $config.enabled) {
        return @()
    }
    
    # Use config languages if not specified
    if (-not $Languages -or $Languages.Count -eq 0) {
        $Languages = $Context.Config.subtitles.wantedLanguages
    }
    
    # Search for subtitles (caller shows batch summary, skip per-file verbose here)
    $searchParams = @{
        Config    = $config
        VideoPath = $VideoPath
        Languages = $Languages
    }
    if (-not [string]::IsNullOrWhiteSpace($MovieHash)) {
        $searchParams.MovieHash = $MovieHash
    }
    $searchResults = Search-SAOpenSubtitles @searchParams
    
    if ($searchResults.Count -eq 0) {
        Write-SAProgress -Label "OpenSubs" -Text "No subtitles found for $($Languages -join ', ')"
        return @()
    }
    
    # Download best matches per language
    $downloadedFiles = [System.Collections.Generic.List[string]]::new()
    $downloadedPerLang = @{}
    
    foreach ($sub in $searchResults) {
        $lang = $sub.Language
        
        # Check if we've downloaded enough for this language
        if (-not $downloadedPerLang.ContainsKey($lang)) {
            $downloadedPerLang[$lang] = 0
        }
        
        if ($downloadedPerLang[$lang] -ge $MaxPerLanguage) {
            continue
        }
        
        # Generate output filename
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
        $langCode = ConvertTo-SALanguageCode -Code $lang -To 'iso1'
        
        $srtName = "$baseName.$langCode.srt"
        if ($downloadedPerLang[$lang] -gt 0) {
            $srtName = "$baseName.$langCode.$($downloadedPerLang[$lang]).srt"
        }
        
        $outputPath = Join-Path -Path $OutputFolder -ChildPath $srtName
        
        # Skip if file already exists
        if (Test-Path -LiteralPath $outputPath) {
            Write-SAVerbose -Text "Already exists: $srtName"
            continue
        }
        
        # Download
        $success = Get-SAOpenSubtitlesDownload -Config $config -FileId $sub.FileId -OutputPath $outputPath
        
        if ($success) {
            $downloadedFiles.Add($outputPath)
            $downloadedPerLang[$lang]++
            $Context.Results.SubtitlesDownloaded++
            # Move per-file success to verbose - summary shown by caller
            Write-SAVerbose -Text "Downloaded: $srtName"
        } else {
            # Show failures at INFO level since they're exceptions
            Write-SAOutcome -Level Warning -Label "OpenSubs" -Text "Download failed for $langCode" -Indent 1 -ConsoleOnly
        }
        
        # Rate limiting - small delay between downloads
        Start-Sleep -Milliseconds 500
    }
    
    return $downloadedFiles.ToArray()
}
