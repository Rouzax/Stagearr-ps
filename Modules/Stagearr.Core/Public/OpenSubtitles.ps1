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

# XML-RPC session token (separate from REST API token)
$script:SAXmlRpcToken = $null

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

#region XML-RPC Upload Functions

function Invoke-SAXmlRpcRequest {
    <#
    .SYNOPSIS
        Sends an XML-RPC method call and parses the response.
    .PARAMETER Url
        XML-RPC endpoint URL.
    .PARAMETER MethodName
        XML-RPC method name (e.g. 'LogIn', 'TryUploadSubtitles').
    .PARAMETER Parameters
        Array of XML-RPC parameter strings (pre-formatted as XML value elements).
    .OUTPUTS
        Parsed response hashtable with Status, Data keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$MethodName,

        [Parameter()]
        [string[]]$Parameters = @()
    )

    # Build XML-RPC request
    $paramXml = ''
    foreach ($p in $Parameters) {
        $paramXml += "<param>$p</param>"
    }

    $body = @"
<?xml version="1.0" encoding="UTF-8"?>
<methodCall>
<methodName>$MethodName</methodName>
<params>$paramXml</params>
</methodCall>
"@

    try {
        $response = Invoke-WebRequest -Uri $Url -Method POST -Body $body `
            -ContentType 'text/xml' -UseBasicParsing -ErrorAction Stop -Verbose:$false

        Write-SAVerbose -Text "XML-RPC $MethodName`: HTTP $($response.StatusCode)"

        [xml]$xml = $response.Content

        # Check for fault
        $fault = $xml.methodResponse.fault
        if ($fault) {
            $faultString = $fault.value.struct.member |
                Where-Object { $_.name -eq 'faultString' } |
                ForEach-Object { $_.value.string }
            Write-SAVerbose -Text "XML-RPC $MethodName fault: $faultString"
            return @{ Success = $false; ErrorMessage = "XML-RPC fault: $faultString" }
        }

        # Parse response struct
        $responseParams = $xml.methodResponse.params.param.value
        $data = ConvertFrom-SAXmlRpcValue -XmlValue $responseParams

        # Check status field
        $status = $null
        if ($data -is [hashtable] -and $data.ContainsKey('status')) {
            $status = $data['status']
        }

        Write-SAVerbose -Text "XML-RPC $MethodName`: status=$status"

        return @{
            Success = ($null -eq $status -or $status -match '^2')
            Status  = $status
            Data    = $data
        }
    }
    catch {
        Write-SAVerbose -Text "XML-RPC $MethodName exception: $_"
        return @{ Success = $false; ErrorMessage = "XML-RPC request failed: $_" }
    }
}

function ConvertFrom-SAXmlRpcValue {
    <#
    .SYNOPSIS
        Converts an XML-RPC value element to a PowerShell object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $XmlValue
    )

    if ($null -eq $XmlValue) { return $null }

    # Handle XmlElement
    if ($XmlValue -is [System.Xml.XmlElement]) {
        $child = $XmlValue.FirstChild

        if ($null -eq $child) {
            # Bare <value>text</value>
            return $XmlValue.InnerText
        }

        switch ($child.LocalName) {
            'string'  { return $child.InnerText }
            'int'     { return [int]$child.InnerText }
            'i4'      { return [int]$child.InnerText }
            'boolean' { return $child.InnerText -eq '1' }
            'double'  { return [double]$child.InnerText }
            'struct' {
                $result = @{}
                foreach ($member in $child.member) {
                    $name = $member.name
                    $val = ConvertFrom-SAXmlRpcValue -XmlValue $member.value
                    $result[$name] = $val
                }
                return $result
            }
            'array' {
                $items = @()
                foreach ($item in $child.data.value) {
                    $items += ConvertFrom-SAXmlRpcValue -XmlValue $item
                }
                return $items
            }
            default { return $child.InnerText }
        }
    }

    # Plain string
    return $XmlValue.ToString()
}

function ConvertTo-SAXmlRpcString {
    <#
    .SYNOPSIS
        Wraps a string value as an XML-RPC value element.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value)

    $escaped = [System.Security.SecurityElement]::Escape($Value)
    return "<value><string>$escaped</string></value>"
}

function ConvertTo-SAXmlRpcStruct {
    <#
    .SYNOPSIS
        Converts a hashtable to an XML-RPC struct element.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$Hashtable)

    $members = ''
    foreach ($key in $Hashtable.Keys) {
        $val = $Hashtable[$key]
        $escapedKey = [System.Security.SecurityElement]::Escape($key)

        if ($val -is [hashtable] -and $val.ContainsKey('__base64')) {
            $members += "<member><name>$escapedKey</name><value><base64>$($val['__base64'])</base64></value></member>"
        }
        elseif ($val -is [hashtable] -and $val.ContainsKey('__int')) {
            $members += "<member><name>$escapedKey</name><value><int>$($val['__int'])</int></value></member>"
        }
        elseif ($val -is [hashtable]) {
            $innerStruct = ConvertTo-SAXmlRpcStruct -Hashtable $val
            $members += "<member><name>$escapedKey</name>$innerStruct</member>"
        }
        else {
            $escapedVal = [System.Security.SecurityElement]::Escape([string]$val)
            $members += "<member><name>$escapedKey</name><value><string>$escapedVal</string></value></member>"
        }
    }

    return "<value><struct>$members</struct></value>"
}

function Connect-SAOpenSubtitlesXmlRpc {
    <#
    .SYNOPSIS
        Logs in to OpenSubtitles XML-RPC API.
    .PARAMETER Config
        OpenSubtitles configuration hashtable.
    .OUTPUTS
        Session token string, or $null on failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    # Return cached token if available
    if ($script:SAXmlRpcToken) {
        return $script:SAXmlRpcToken
    }

    if ([string]::IsNullOrWhiteSpace($Config.user) -or
        [string]::IsNullOrWhiteSpace($Config.password)) {
        return $null
    }

    $url = $script:SAConstants.OpenSubtitlesXmlRpcUrl

    $params = @(
        (ConvertTo-SAXmlRpcString -Value $Config.user),
        (ConvertTo-SAXmlRpcString -Value $Config.password),
        (ConvertTo-SAXmlRpcString -Value 'en'),
        (ConvertTo-SAXmlRpcString -Value 'Stagearr v2.0')
    )

    $result = Invoke-SAXmlRpcRequest -Url $url -MethodName 'LogIn' -Parameters $params

    if ($result.Success -and $result.Data -is [hashtable] -and $result.Data['token']) {
        $script:SAXmlRpcToken = $result.Data['token']
        Write-SAVerbose -Text "XML-RPC authenticated with OpenSubtitles"
        return $script:SAXmlRpcToken
    }

    $errorMsg = if ($result.ErrorMessage) { $result.ErrorMessage } else { "Unknown error" }
    Write-SAOutcome -Level Warning -Label "OpenSubs" -Text "XML-RPC login failed: $errorMsg" -Indent 1 -ConsoleOnly
    return $null
}

function Send-SAOpenSubtitlesUpload {
    <#
    .SYNOPSIS
        Uploads a single subtitle file via XML-RPC.
    .PARAMETER Config
        OpenSubtitles configuration hashtable.
    .PARAMETER SubtitlePath
        Path to the SRT file.
    .PARAMETER Language
        ISO 639-1 language code.
    .PARAMETER MovieHash
        OpenSubtitles video hash.
    .PARAMETER MovieByteSize
        Video file size in bytes.
    .PARAMETER MovieFileName
        Video filename.
    .PARAMETER XmlRpcToken
        Session token from Connect-SAOpenSubtitlesXmlRpc.
    .PARAMETER ImdbId
        Pre-resolved numeric IMDB ID (e.g. '1234567'). If empty, falls back to TryUpload response.
    .OUTPUTS
        PSCustomObject with Success, Duplicate, Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$SubtitlePath,

        [Parameter()]
        [string]$ImdbId = '',

        [Parameter(Mandatory = $true)]
        [string]$Language,

        [Parameter()]
        [string]$MovieHash = '',

        [Parameter()]
        [long]$MovieByteSize = 0,

        [Parameter()]
        [string]$MovieFileName = '',

        [Parameter(Mandatory = $true)]
        [string]$XmlRpcToken
    )

    $url = $script:SAConstants.OpenSubtitlesXmlRpcUrl
    $subFileName = Split-Path -Path $SubtitlePath -Leaf

    # Compute subtitle MD5 hash
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $subBytes = [System.IO.File]::ReadAllBytes($SubtitlePath)
    $hashBytes = $md5.ComputeHash($subBytes)
    $subHash = [BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()
    $md5.Dispose()

    # Convert language to ISO 639-2/B for XML-RPC API
    $langCode = ConvertTo-SALanguageCode -Code $Language -To 'iso2b'
    if (-not $langCode) { $langCode = $Language }

    Write-SAVerbose -Text "Upload check: $subFileName (lang=$langCode, hash=$MovieHash, size=$MovieByteSize)"

    # Step 1: TryUploadSubtitles - check if already exists
    $cd1Try = @{
        subhash       = $subHash
        subfilename   = $subFileName
        moviehash     = $MovieHash
        moviebytesize = [string]$MovieByteSize
        moviefilename = $MovieFileName
    }

    $tryStruct = ConvertTo-SAXmlRpcStruct -Hashtable @{ cd1 = $cd1Try }
    $tryParams = @(
        (ConvertTo-SAXmlRpcString -Value $XmlRpcToken),
        $tryStruct
    )

    $tryResult = Invoke-SAXmlRpcRequest -Url $url -MethodName 'TryUploadSubtitles' -Parameters $tryParams

    $alreadyInDb = if ($tryResult.Data -is [hashtable]) { $tryResult.Data['alreadyindb'] } else { 'N/A' }
    Write-SAVerbose -Text "TryUpload response: status=$($tryResult.Status), alreadyindb=$alreadyInDb"

    if (-not $tryResult.Success) {
        $msg = if ($tryResult.ErrorMessage) { $tryResult.ErrorMessage } else { "TryUpload failed (status=$($tryResult.Status))" }
        return [PSCustomObject]@{ Success = $false; Duplicate = $false; Message = $msg }
    }

    # Check if already in database
    if ($tryResult.Data -is [hashtable] -and $tryResult.Data['alreadyindb'] -eq 1) {
        return [PSCustomObject]@{ Success = $true; Duplicate = $true; Message = "Already on OpenSubtitles" }
    }

    # Use pre-resolved IMDB ID if available, otherwise try to extract from TryUpload response
    $resolvedImdbId = $ImdbId
    if (-not $resolvedImdbId) {
        if ($tryResult.Data -is [hashtable] -and $tryResult.Data['data'] -is [hashtable]) {
            $resolvedImdbId = [string]$tryResult.Data['data']['IDMovieImdb']
        }
        elseif ($tryResult.Data -is [hashtable] -and $tryResult.Data['data'] -is [array] -and $tryResult.Data['data'].Count -gt 0) {
            $movieInfo = $tryResult.Data['data'][0]
            if ($movieInfo -is [hashtable] -and $movieInfo['IDMovieImdb']) {
                $resolvedImdbId = [string]$movieInfo['IDMovieImdb']
            }
        }
        if ($resolvedImdbId) {
            Write-SAVerbose -Text "TryUpload returned IMDB ID: $resolvedImdbId"
        }
    }

    # Step 2: UploadSubtitles - gzip compress and send
    $ms = [System.IO.MemoryStream]::new()
    $gs = [System.IO.Compression.ZLibStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gs.Write($subBytes, 0, $subBytes.Length)
    $gs.Close()
    $subcontent = [Convert]::ToBase64String($ms.ToArray())
    $ms.Dispose()

    $baseinfo = @{
        sublanguageid = $langCode
    }
    if ($resolvedImdbId) {
        $baseinfo['idmovieimdb'] = @{ __int = [int]$resolvedImdbId }
    }

    $cd1Upload = @{
        subhash       = $subHash
        subfilename   = $subFileName
        moviehash     = $MovieHash
        moviebytesize = [string]$MovieByteSize
        moviefilename = $MovieFileName
        subcontent    = $subcontent
    }

    Write-SAVerbose -Text "Subtitle compressed: $($subcontent.Length) chars base64 (raw=$($subBytes.Length) bytes, hash=$subHash)"

    $uploadStruct = ConvertTo-SAXmlRpcStruct -Hashtable @{
        baseinfo = $baseinfo
        cd1      = $cd1Upload
    }

    $uploadParams = @(
        (ConvertTo-SAXmlRpcString -Value $XmlRpcToken),
        $uploadStruct
    )

    $uploadResult = Invoke-SAXmlRpcRequest -Url $url -MethodName 'UploadSubtitles' -Parameters $uploadParams

    Write-SAVerbose -Text "Upload response: status=$($uploadResult.Status), success=$($uploadResult.Success)"

    if ($uploadResult.Success) {
        return [PSCustomObject]@{ Success = $true; Duplicate = $false; Message = "Uploaded successfully" }
    }

    $msg = if ($uploadResult.ErrorMessage) { $uploadResult.ErrorMessage } else { "Upload failed" }
    return [PSCustomObject]@{ Success = $false; Duplicate = $false; Message = $msg }
}

function Test-SAOpenSubtitlesSubtitleExists {
    <#
    .SYNOPSIS
        Checks if subtitles already exist on OpenSubtitles for a given video and language.
    .DESCRIPTION
        Uses the REST API to search for existing subtitles. Returns $true if any are found,
        preventing duplicate uploads. Fail-open: returns $false on errors.
    .PARAMETER Config
        OpenSubtitles configuration hashtable.
    .PARAMETER MovieHash
        OpenSubtitles video hash.
    .PARAMETER Language
        ISO 639-1 language code.
    .PARAMETER VideoFileName
        Video filename for query and season/episode parsing.
    .OUTPUTS
        Boolean indicating whether subtitles already exist.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter()]
        [string]$MovieHash = '',

        [Parameter(Mandatory = $true)]
        [string]$Language,

        [Parameter()]
        [string]$VideoFileName = ''
    )

    $token = Get-SAOpenSubtitlesToken -Config $Config
    if (-not $token) { return $false }

    $lang = ConvertTo-SALanguageCode -Code $Language -To 'iso1'
    if (-not $lang) { $lang = $Language }

    $queryParams = @{ languages = $lang }
    if ($MovieHash) { $queryParams.moviehash = $MovieHash }
    if ($VideoFileName) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoFileName)
        $queryParams.query = $baseName
        $mediaInfo = Get-SAMediaInfo -FileName $VideoFileName
        if ($mediaInfo.Type -eq 'episode') {
            $queryParams.season_number = $mediaInfo.Season
            $queryParams.episode_number = $mediaInfo.Episode
            $queryParams.type = 'episode'
        }
        elseif ($mediaInfo.Type -eq 'movie' -and $mediaInfo.Year) {
            $queryParams.year = $mediaInfo.Year
            $queryParams.type = 'movie'
        }
    }

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

    $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -MaxRetries 2

    if ($result.Success -and $result.Data.data -and $result.Data.data.Count -gt 0) {
        return $true
    }
    return $false
}

function Resolve-SAOpenSubtitlesImdbId {
    <#
    .SYNOPSIS
        Resolves a numeric IMDB ID for a video using available sources.
    .DESCRIPTION
        Uses cached OMDb data first, then tries OpenSubtitles REST API search (by hash).
        Returns numeric IMDB ID string (e.g. '1234567') or empty string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter()]
        [string]$MovieHash = '',

        [Parameter()]
        [string]$VideoFileName = ''
    )

    $osConfig = $Context.Config.subtitles.openSubtitles

    # Step 0: Use cached OMDb data if available (from early pipeline query)
    if ($Context.State.OmdbData -and $Context.State.OmdbData.ImdbId) {
        $imdbId = $Context.State.OmdbData.ImdbId -replace '^tt', ''
        Write-SAVerbose -Text "Resolved IMDB ID: $imdbId (source: cached OMDb)"
        return $imdbId
    }

    # Step 1: Try OpenSubtitles REST API search by hash + filename
    if ($MovieHash -or $VideoFileName) {
        $token = Get-SAOpenSubtitlesToken -Config $osConfig
        if ($token) {
            $queryParams = @{
                languages = 'en'
            }
            if ($MovieHash) { $queryParams.moviehash = $MovieHash }
            if ($VideoFileName) {
                $queryParams.query = [System.IO.Path]::GetFileNameWithoutExtension($VideoFileName)
            }
            # Use pre-parsed ReleaseInfo from Context for type filtering
            # This data comes from GuessIt (more reliable than re-parsing the filename)
            $releaseInfo = $Context.State.ReleaseInfo
            if ($releaseInfo) {
                if ($releaseInfo.Type -eq 'episode') {
                    $queryParams.type = 'episode'
                    if ($releaseInfo.Season) { $queryParams.season_number = $releaseInfo.Season }
                    if ($releaseInfo.Episode) { $queryParams.episode_number = $releaseInfo.Episode }
                }
                elseif ($releaseInfo.Type -eq 'movie') {
                    $queryParams.type = 'movie'
                    if ($releaseInfo.Year) { $queryParams.year = $releaseInfo.Year }
                }
            }
            $queryString = ($queryParams.GetEnumerator() | ForEach-Object {
                "$($_.Key)=$([System.Uri]::EscapeDataString($_.Value))"
            }) -join '&'

            $uri = "https://api.opensubtitles.com/api/v1/subtitles?$queryString"
            $headers = @{
                'Api-Key'       = $osConfig.apiKey
                'Authorization' = "Bearer $token"
                'Accept'        = 'application/json'
                'User-Agent'    = 'Stagearr v2.0'
            }

            $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -MaxRetries 2
            if ($result.Success -and $result.Data.data -and $result.Data.data.Count -gt 0) {
                $featureDetails = $result.Data.data[0].attributes.feature_details
                if ($featureDetails -and $featureDetails.imdb_id) {
                    # Validate that the result type matches our content type
                    $resultType = $featureDetails.feature_type  # 'Movie', 'Episode', 'Tvshow'
                    $expectedType = if ($releaseInfo) { $releaseInfo.Type } else { $null }

                    $typeMismatch = $false
                    if ($expectedType -eq 'episode' -and $resultType -eq 'Movie') {
                        Write-SAVerbose -Text "IMDB ID rejected: API returned Movie but content is TV episode"
                        $typeMismatch = $true
                    }
                    elseif ($expectedType -eq 'movie' -and $resultType -in @('Episode', 'Tvshow')) {
                        Write-SAVerbose -Text "IMDB ID rejected: API returned $resultType but content is movie"
                        $typeMismatch = $true
                    }

                    if (-not $typeMismatch) {
                        $imdbId = [string]$featureDetails.imdb_id
                        Write-SAVerbose -Text "Resolved IMDB ID: $imdbId (source: OpenSubtitles)"
                        return $imdbId
                    }
                }
            }
        }
    }

    Write-SAVerbose -Text "Could not resolve IMDB ID - upload may fail"
    return ''
}

function Test-SAUploadableSubtitle {
    <#
    .SYNOPSIS
        Validates whether a subtitle's video filename is safe to upload to OpenSubtitles.
    .PARAMETER VideoBaseName
        Video base name (without extension or language suffix).
    .PARAMETER LabelType
        Content type: 'tv', 'movie', or 'passthrough'.
    .OUTPUTS
        PSCustomObject with Allowed (bool) and Reason (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoBaseName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('tv', 'movie', 'passthrough')]
        [string]$LabelType
    )

    $name = $VideoBaseName.Trim()

    # Guard 1: Blocklist - known generic filenames
    $blocklist = $script:SAConstants.OpenSubtitlesUploadBlockedNames
    if ($blocklist -contains $name.ToLower()) {
        return [PSCustomObject]@{ Allowed = $false; Reason = "generic filename '$name'" }
    }

    # Guard 2: Single-character or numeric-only names
    if ($name.Length -le 1 -or $name -match '^\d+$') {
        return [PSCustomObject]@{ Allowed = $false; Reason = "generic filename '$name'" }
    }

    # Guard 3: Content-type-specific metadata validation
    switch ($LabelType) {
        'tv' {
            # Require season+episode pattern: S01E01, s01e01, 1x01
            if ($name -notmatch 'S\d{1,2}E\d{1,2}' -and $name -notmatch '\d{1,2}x\d{1,2}') {
                return [PSCustomObject]@{ Allowed = $false; Reason = "missing episode info in '$name'" }
            }
        }
        'movie' {
            # Require parseable title: must have either multiple words (dot/space separated)
            # or a word + year pattern. Strip known technical tokens first.
            $cleaned = $name -replace '\b(2160p|1080p|720p|480p|BluRay|WEB-DL|WEBRip|HDRip|BRRip|DVDRip|HDTV|REMUX|DTS|DD5|DDP5|AAC|FLAC|x264|x265|H\.?264|H\.?265|HEVC|AVC|HDR|HDR10|DV|Atmos|NF|AMZN|DSNP|HMAX|ATVP|MA)\b', ''
            $cleaned = $cleaned -replace '[-._]', ' '
            $cleaned = $cleaned -replace '\s+', ' '
            $cleaned = $cleaned.Trim()
            $words = @($cleaned -split '\s' | Where-Object { $_ -and $_.Length -gt 1 })
            if ($words.Count -lt 2) {
                return [PSCustomObject]@{ Allowed = $false; Reason = "unparseable title in '$name'" }
            }
        }
        'passthrough' {
            return [PSCustomObject]@{ Allowed = $false; Reason = "unknown content type for '$name'" }
        }
    }

    return [PSCustomObject]@{ Allowed = $true; Reason = '' }
}

function Start-SAOpenSubtitlesUpload {
    <#
    .SYNOPSIS
        Batch orchestrator for uploading cleaned subtitles to OpenSubtitles.
    .PARAMETER Context
        Processing context.
    .PARAMETER SubtitlePaths
        Array of SRT file paths to upload.
    .PARAMETER VideoHashMap
        Hashtable mapping video base name to OpenSubtitles hash.
    .PARAMETER VideoSizeMap
        Hashtable mapping video base name to file size in bytes.
    .OUTPUTS
        PSCustomObject with UploadedCount, DuplicateCount, FailedCount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [string[]]$SubtitlePaths,

        [Parameter()]
        [hashtable]$VideoHashMap = @{},

        [Parameter()]
        [hashtable]$VideoSizeMap = @{}
    )

    $config = $Context.Config.subtitles.openSubtitles

    # ZLibStream requires .NET 6+ (PowerShell 7+)
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-SAVerbose -Text "Subtitle upload requires PowerShell 7+ - skipping"
        return [PSCustomObject]@{ UploadedCount = 0; DuplicateCount = 0; FailedCount = 0 }
    }

    $uploaded = 0
    $duplicates = 0
    $failed = 0

    # Login via XML-RPC
    $token = Connect-SAOpenSubtitlesXmlRpc -Config $config
    if (-not $token) {
        Write-SAOutcome -Level Warning -Label "OpenSubs" -Text "Upload login failed - skipping uploads" -Indent 1 -ConsoleOnly
        return [PSCustomObject]@{ UploadedCount = 0; DuplicateCount = 0; FailedCount = $SubtitlePaths.Count }
    }

    # Resolve IMDB ID once for the batch (using first video's hash + filename)
    $batchImdbId = ''
    $firstVideoBase = if ($VideoHashMap.Count -gt 0) { $VideoHashMap.Keys | Select-Object -First 1 } else { '' }
    $firstHash = if ($firstVideoBase -and $VideoHashMap.ContainsKey($firstVideoBase)) { $VideoHashMap[$firstVideoBase] } else { '' }
    $firstFileName = if ($firstVideoBase) { "$firstVideoBase.mkv" } else { '' }
    if ($firstHash -or $firstFileName) {
        $batchImdbId = Resolve-SAOpenSubtitlesImdbId -Context $Context -MovieHash $firstHash -VideoFileName $firstFileName
    }

    $subWord = Get-SAPluralForm -Count $SubtitlePaths.Count -Singular 'subtitle'
    Write-SAProgress -Label "OpenSubs" -Text "Uploading $($SubtitlePaths.Count) cleaned $subWord to OpenSubtitles..." -Indent 1

    foreach ($srtPath in $SubtitlePaths) {
        $srtName = Split-Path -Path $srtPath -Leaf
        $srtBaseName = [System.IO.Path]::GetFileNameWithoutExtension($srtPath)

        # Extract language from filename (e.g. Movie.en.srt -> en)
        $lang = ''
        if ($srtBaseName -match '\.([a-z]{2})$') {
            $lang = $Matches[1]
        }
        # Also handle numbered duplicates (e.g. Movie.en.1.srt -> en)
        elseif ($srtBaseName -match '\.([a-z]{2})\.\d+$') {
            $lang = $Matches[1]
        }

        if ([string]::IsNullOrWhiteSpace($lang)) {
            Write-SAVerbose -Text "Skipped upload (no language code): $srtName"
            $failed++
            continue
        }

        # Find matching video hash and size by stripping language suffix from SRT base name
        $videoBaseName = $srtBaseName -replace '\.[a-z]{2}(\.\d+)?$', ''
        $movieHash = if ($VideoHashMap.ContainsKey($videoBaseName)) { $VideoHashMap[$videoBaseName] } else { '' }
        $movieSize = if ($VideoSizeMap.ContainsKey($videoBaseName)) { $VideoSizeMap[$videoBaseName] } else { [long]0 }
        $movieFileName = "$videoBaseName.mkv"

        # Pre-check: search REST API for existing subtitles in this language
        $existsOnSite = Test-SAOpenSubtitlesSubtitleExists -Config $config `
            -MovieHash $movieHash `
            -Language $lang `
            -VideoFileName $movieFileName

        if ($existsOnSite) {
            $duplicates++
            Write-SAVerbose -Text "Subtitle already exists on OpenSubtitles for '$lang': $srtName"
            continue
        }

        try {
            $result = Send-SAOpenSubtitlesUpload -Config $config `
                -SubtitlePath $srtPath `
                -ImdbId $batchImdbId `
                -Language $lang `
                -MovieHash $movieHash `
                -MovieByteSize $movieSize `
                -MovieFileName $movieFileName `
                -XmlRpcToken $token

            if ($result.Duplicate) {
                $duplicates++
                Write-SAVerbose -Text "Already on OpenSubtitles: $srtName"
            }
            elseif ($result.Success) {
                $uploaded++
                Write-SAVerbose -Text "Uploaded: $srtName"
            }
            else {
                $failed++
                $detail = if ($result.Message) { "$srtName - $($result.Message)" } else { $srtName }
                Write-SAOutcome -Level Warning -Label "OpenSubs" -Text "Upload failed: $detail" -Indent 1 -ConsoleOnly
            }
        }
        catch {
            $failed++
            Write-SAOutcome -Level Warning -Label "OpenSubs" -Text "Upload error for $($srtName): $_" -Indent 1 -ConsoleOnly
        }

        # Rate limit between uploads
        Start-Sleep -Milliseconds $script:SAConstants.OpenSubtitlesUploadDelayMs
    }

    # Batch summary
    if ($uploaded -gt 0) {
        $subWord = Get-SAPluralForm -Count $uploaded -Singular 'subtitle'
        Write-SAOutcome -Level Success -Label "OpenSubs" -Text "Uploaded $uploaded $subWord to OpenSubtitles" -Indent 1
    }
    if ($duplicates -gt 0) {
        $subWord = Get-SAPluralForm -Count $duplicates -Singular 'subtitle'
        Write-SAOutcome -Level Skip -Label "OpenSubs" -Text "Skipped $duplicates $subWord (already on OpenSubtitles)" -Indent 1
    }

    return [PSCustomObject]@{
        UploadedCount  = $uploaded
        DuplicateCount = $duplicates
        FailedCount    = $failed
    }
}

#endregion
