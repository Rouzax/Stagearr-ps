#Requires -Version 5.1
<#
.SYNOPSIS
    OMDb API client for Stagearr
.DESCRIPTION
    Provides OMDb API integration for enriching email notifications with movie/TV metadata.
    Fetches poster images, ratings (IMDb, Rotten Tomatoes, Metacritic), genre, runtime, etc.
    
    Design principles:
    - Graceful failure: Returns $null on any error (timeout, not found, API error)
    - Verbose-only output: No console output, only verbose for troubleshooting
    - Short timeout: Optional enrichment shouldn't delay job completion
    - Pure helper function: ConvertTo-SAOmdbDisplayData is unit-testable
    
    API Reference: https://www.omdbapi.com/
#>

#region Constants

$script:SAOmdbBaseUrl = 'https://www.omdbapi.com/'

#endregion

#region Pure Helper Functions

function ConvertTo-SAOmdbDisplayData {
    <#
    .SYNOPSIS
        Normalizes OMDb API response into display-ready data.
    .DESCRIPTION
        Pure function - no I/O. Extracts and normalizes data from the raw OMDb API 
        response into a consistent hashtable for display in emails.
        
        Handles:
        - Extracting ratings from the Ratings array (IMDb, Rotten Tomatoes, Metacritic)
        - Normalizing "N/A" values to $null
        - Truncating plot to configured max length
        - Converting IMDb rating format (e.g., "7.4/10" to "7.4")
    .PARAMETER Response
        Raw response hashtable/object from OMDb API.
    .PARAMETER PlotMaxLength
        Maximum length for plot text (0 = no truncation).
    .OUTPUTS
        Hashtable with normalized display data, or $null if response is invalid.
    .EXAMPLE
        $displayData = ConvertTo-SAOmdbDisplayData -Response $apiResponse -PlotMaxLength 150
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Response,
        
        [Parameter()]
        [int]$PlotMaxLength = 0
    )
    
    # Validate response
    if ($null -eq $Response) {
        return $null
    }
    
    # Check for API error response
    if ($Response.Response -eq 'False') {
        return $null
    }
    
    # Helper to normalize N/A values
    $normalizeValue = {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'N/A') {
            return $null
        }
        return $Value.Trim()
    }
    
    # Extract ratings from the Ratings array
    $imdbRating = $null
    $rottenTomatoes = $null
    $metacritic = $null
    
    # First try the Ratings array (more reliable)
    if ($Response.Ratings -and $Response.Ratings.Count -gt 0) {
        foreach ($rating in $Response.Ratings) {
            switch ($rating.Source) {
                'Internet Movie Database' {
                    # Format: "7.4/10" -> "7.4"
                    if ($rating.Value -match '^([\d.]+)/10$') {
                        $imdbRating = $Matches[1]
                    }
                }
                'Rotten Tomatoes' {
                    # Format: "85%" -> "85%"
                    $rottenTomatoes = $rating.Value
                }
                'Metacritic' {
                    # Format: "80/100" -> "80"
                    if ($rating.Value -match '^(\d+)/100$') {
                        $metacritic = $Matches[1]
                    }
                }
            }
        }
    }
    
    # Fallback to top-level fields if not in Ratings array
    if ($null -eq $imdbRating -and $Response.imdbRating) {
        $imdbRating = & $normalizeValue $Response.imdbRating
    }
    if ($null -eq $metacritic -and $Response.Metascore) {
        $metacritic = & $normalizeValue $Response.Metascore
    }
    
    # Process plot with optional truncation
    $plot = & $normalizeValue $Response.Plot
    if ($null -ne $plot -and $PlotMaxLength -gt 0 -and $plot.Length -gt $PlotMaxLength) {
        $plot = $plot.Substring(0, $PlotMaxLength - 3).TrimEnd() + '...'
    }
    
    # Build normalized result
    $result = @{
        Title          = & $normalizeValue $Response.Title
        Year           = & $normalizeValue $Response.Year
        ImdbId         = & $normalizeValue $Response.imdbID
        ImdbRating     = $imdbRating
        RottenTomatoes = $rottenTomatoes
        Metacritic     = $metacritic
        Genre          = & $normalizeValue $Response.Genre
        Runtime        = & $normalizeValue $Response.Runtime
        Plot           = $plot
        Poster         = & $normalizeValue $Response.Poster
        Type           = & $normalizeValue $Response.Type
        TotalSeasons   = & $normalizeValue $Response.totalSeasons
        Director       = & $normalizeValue $Response.Director
        Actors         = & $normalizeValue $Response.Actors
    }
    
    return $result
}

#endregion

#region HTTP Functions

function Invoke-SAOmdbRequest {
    <#
    .SYNOPSIS
        Makes an HTTP request to the OMDb API.
    .DESCRIPTION
        Lightweight HTTP wrapper specifically for OMDb requests.
        Unlike Invoke-SAWebRequest, this does NOT retry on failure - OMDb enrichment
        is optional and shouldn't delay job completion.
        
        Returns $null on any failure (timeout, network error, API error).
    .PARAMETER Uri
        Full request URI including query parameters.
    .PARAMETER TimeoutSeconds
        Request timeout (default: 5).
    .OUTPUTS
        PSCustomObject with API response, or $null on failure.
    .EXAMPLE
        $response = Invoke-SAOmdbRequest -Uri "https://www.omdbapi.com/?t=Inception&y=2010&apikey=xxx"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        
        [Parameter()]
        [int]$TimeoutSeconds = 5
    )
    
    # Ensure TLS 1.2 for PowerShell 5.1
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    
    try {
        $requestParams = @{
            Uri             = $Uri
            Method          = 'GET'
            TimeoutSec      = $TimeoutSeconds
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
        }
        
        # Make request (suppress built-in verbose)
        $response = Invoke-WebRequest @requestParams -Verbose:$false
        
        if ($response.StatusCode -ne 200) {
            Write-SAVerbose -Label 'OMDb' -Text "HTTP $($response.StatusCode)"
            return $null
        }
        
        # Parse JSON response
        $data = $response.Content | ConvertFrom-Json
        
        # Check for OMDb error response
        if ($data.Response -eq 'False') {
            $errorMsg = if ($data.Error) { $data.Error } else { 'Unknown error' }
            Write-SAVerbose -Label 'OMDb' -Text "API error: $errorMsg"
            return $null
        }
        
        return $data
        
    } catch [System.Net.WebException] {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match 'timed out') {
            Write-SAVerbose -Label 'OMDb' -Text "Request timed out after $TimeoutSeconds seconds"
        } else {
            Write-SAVerbose -Label 'OMDb' -Text "Network error: $errorMsg"
        }
        return $null
        
    } catch {
        Write-SAVerbose -Label 'OMDb' -Text "Request failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-SAOmdbPosterData {
    <#
    .SYNOPSIS
        Downloads a poster image and returns structured data for CID attachment.
    .DESCRIPTION
        Downloads the poster from the given URL and returns a hashtable with:
        - Bytes: Raw image bytes for attachment
        - MimeType: MIME type (image/jpeg, image/png, etc.)
        - ContentId: Unique CID for email attachment reference
        
        This data structure supports CID (Content-ID) inline attachments in HTML emails,
        which are the industry standard for displaying images in email clients.
        Gmail and most modern email clients block inline base64 images for security,
        but properly support CID-referenced attachments.
        
        Returns $null on any failure (timeout, 404, network error).
    .PARAMETER PosterUrl
        URL to the poster image (typically from OMDb Poster field).
    .PARAMETER TimeoutSeconds
        Request timeout (default: 5).
    .OUTPUTS
        Hashtable with Bytes, MimeType, ContentId properties, or $null on failure.
    .EXAMPLE
        $posterData = Get-SAOmdbPosterData -PosterUrl "https://m.media-amazon.com/images/M/..."
        # Returns: @{ Bytes = [byte[]]; MimeType = 'image/jpeg'; ContentId = 'poster-abc123' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PosterUrl,
        
        [Parameter()]
        [int]$TimeoutSeconds = 5
    )
    
    # Validate URL
    if ([string]::IsNullOrWhiteSpace($PosterUrl) -or $PosterUrl -eq 'N/A') {
        return $null
    }
    
    # Ensure TLS 1.2 for PowerShell 5.1
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    
    try {
        $requestParams = @{
            Uri             = $PosterUrl
            Method          = 'GET'
            TimeoutSec      = $TimeoutSeconds
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
        }
        
        # Make request (suppress built-in verbose)
        $response = Invoke-WebRequest @requestParams -Verbose:$false
        
        if ($response.StatusCode -ne 200) {
            Write-SAVerbose -Label 'OMDb' -Text "Poster download failed: HTTP $($response.StatusCode)"
            return $null
        }
        
        # Get raw bytes - handle PS5.1 vs PS7 differences
        # In PS7, Content may be returned as string for some content-types
        # Use RawContentStream for reliable binary access across versions
        $imageBytes = $null
        
        if ($response.RawContentStream) {
            # PS5.1+ with RawContentStream available - most reliable method
            $response.RawContentStream.Position = 0
            $memStream = New-Object System.IO.MemoryStream
            $response.RawContentStream.CopyTo($memStream)
            $imageBytes = $memStream.ToArray()
            $memStream.Dispose()
        } elseif ($response.Content -is [byte[]]) {
            # PS7 with binary content properly typed
            $imageBytes = $response.Content
        } elseif ($response.Content -is [string]) {
            # PS7 may return string for some scenarios - try to decode
            # This shouldn't happen for images but handle defensively
            Write-SAVerbose -Label 'OMDb' -Text 'Content returned as string, attempting byte conversion'
            $imageBytes = [System.Text.Encoding]::ISO88591.GetBytes($response.Content)
        } else {
            # Fallback - try direct assignment
            $imageBytes = $response.Content
        }
        
        if ($null -eq $imageBytes -or $imageBytes.Length -eq 0) {
            Write-SAVerbose -Label 'OMDb' -Text 'Poster download returned empty content'
            return $null
        }
        
        # Determine MIME type from URL or default to JPEG
        $mimeType = 'image/jpeg'
        if ($PosterUrl -match '\.png($|\?)') {
            $mimeType = 'image/png'
        } elseif ($PosterUrl -match '\.gif($|\?)') {
            $mimeType = 'image/gif'
        } elseif ($PosterUrl -match '\.webp($|\?)') {
            $mimeType = 'image/webp'
        }
        
        # Generate unique Content-ID with extension for Mailozaurr compatibility
        # Mailozaurr uses filename as Content-ID, so we include extension
        # Format: poster-{short-guid}.{ext} (e.g., poster-a1b2c3d4.jpg)
        $ext = switch ($mimeType) {
            'image/png'  { '.png' }
            'image/gif'  { '.gif' }
            'image/webp' { '.webp' }
            default      { '.jpg' }
        }
        $contentId = "poster-$([guid]::NewGuid().ToString('N').Substring(0, 8))$ext"
        
        $sizeKb = [math]::Round($imageBytes.Length / 1024, 0)
        Write-SAVerbose -Label 'OMDb' -Text "Poster downloaded ($sizeKb KB, CID: $contentId)"
        
        return @{
            Bytes     = $imageBytes
            MimeType  = $mimeType
            ContentId = $contentId
        }
        
    } catch [System.Net.WebException] {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match 'timed out') {
            Write-SAVerbose -Label 'OMDb' -Text "Poster download timed out after $TimeoutSeconds seconds"
        } elseif ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            Write-SAVerbose -Label 'OMDb' -Text 'Poster not found (404)'
        } else {
            Write-SAVerbose -Label 'OMDb' -Text "Poster download failed: $errorMsg"
        }
        return $null
        
    } catch {
        Write-SAVerbose -Label 'OMDb' -Text "Poster download failed: $($_.Exception.Message)"
        return $null
    }
}

#endregion

#region Main Entry Point

function Get-SAOmdbMetadata {
    <#
    .SYNOPSIS
        Fetches movie/TV metadata from OMDb API.
    .DESCRIPTION
        Main entry point for OMDb integration. Fetches metadata including ratings,
        genre, runtime, and optionally downloads the poster as base64.
        
        Lookup strategy:
        1. Try exact title + year match
        2. If fails, return $null (graceful degradation)
        
        Returns $null on any failure - email renders normally without OMDb data.
    .PARAMETER Title
        Movie or TV show title to search for.
    .PARAMETER Year
        Release year (optional but recommended for accuracy).
    .PARAMETER Type
        Content type: 'movie' or 'series' (default: movie).
    .PARAMETER Config
        OMDb configuration hashtable with:
        - apiKey: OMDb API key (required)
        - timeoutSeconds: Request timeout (default: 5)
        - poster.enabled: Whether to download poster (default: true)
        - display.plot: Whether to include plot (default: false)
        - display.plotMaxLength: Max plot length (default: 150)
    .OUTPUTS
        Hashtable with metadata, or $null on failure.
    .EXAMPLE
        $omdb = Get-SAOmdbMetadata -Title "Inception" -Year "2010" -Config $config.omdb
    .EXAMPLE
        $omdb = Get-SAOmdbMetadata -Title "Breaking Bad" -Type "series" -Config $config.omdb
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        
        [Parameter()]
        [string]$Year,
        
        [Parameter()]
        [ValidateSet('movie', 'series')]
        [string]$Type = 'movie',
        
        [Parameter()]
        [hashtable]$Config
    )
    
    # Validate config
    if ($null -eq $Config) {
        Write-SAVerbose -Label 'OMDb' -Text 'No configuration provided'
        return $null
    }
    
    if (-not $Config.enabled) {
        Write-SAVerbose -Label 'OMDb' -Text 'Feature disabled in configuration'
        return $null
    }
    
    $apiKey = $Config.apiKey
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-SAVerbose -Label 'OMDb' -Text 'No API key configured'
        return $null
    }
    
    # Get configuration options with defaults
    $timeoutSeconds = if ($Config.timeoutSeconds -gt 0) { $Config.timeoutSeconds } else { 5 }
    $posterEnabled = if ($null -ne $Config.poster -and $null -ne $Config.poster.enabled) { $Config.poster.enabled } else { $true }
    $plotEnabled = if ($null -ne $Config.display -and $null -ne $Config.display.plot) { $Config.display.plot } else { $false }
    $plotMaxLength = if ($null -ne $Config.display -and $Config.display.plotMaxLength -gt 0) { $Config.display.plotMaxLength } else { 150 }
    
    # Build request URL
    $encodedTitle = [System.Web.HttpUtility]::UrlEncode($Title)
    $url = "${script:SAOmdbBaseUrl}?apikey=$apiKey&t=$encodedTitle&type=$Type"
    
    if (-not [string]::IsNullOrWhiteSpace($Year)) {
        $url += "&y=$Year"
    }
    
    # Add plot if enabled
    if ($plotEnabled) {
        $url += '&plot=short'
    }
    
    # Log search
    $searchDesc = if (-not [string]::IsNullOrWhiteSpace($Year)) { "`"$Title`" ($Year)" } else { "`"$Title`"" }
    Write-SAVerbose -Label 'OMDb' -Text "Fetching metadata for $searchDesc"
    
    # Make API request
    $response = Invoke-SAOmdbRequest -Uri $url -TimeoutSeconds $timeoutSeconds
    
    if ($null -eq $response) {
        Write-SAVerbose -Label 'OMDb' -Text "No match found for $searchDesc"
        return $null
    }
    
    # Convert to display data
    $plotMax = if ($plotEnabled) { $plotMaxLength } else { 0 }
    $displayData = ConvertTo-SAOmdbDisplayData -Response $response -PlotMaxLength $plotMax
    
    if ($null -eq $displayData) {
        Write-SAVerbose -Label 'OMDb' -Text 'Failed to parse API response'
        return $null
    }
    
    # Clear plot if not enabled (in case API returned it anyway)
    if (-not $plotEnabled) {
        $displayData.Plot = $null
    }
    
    # Log success
    $ratingInfo = if ($displayData.ImdbRating) { "IMDb $($displayData.ImdbRating)" } else { 'no rating' }
    $genreInfo = if ($displayData.Genre) { $displayData.Genre } else { 'unknown genre' }
    Write-SAVerbose -Label 'OMDb' -Text "Found - $ratingInfo, $genreInfo"
    
    # Download poster if enabled
    if ($posterEnabled -and $displayData.Poster) {
        Write-SAVerbose -Label 'OMDb' -Text 'Downloading poster...'
        $posterData = Get-SAOmdbPosterData -PosterUrl $displayData.Poster -TimeoutSeconds $timeoutSeconds
        $displayData.PosterData = $posterData
    } else {
        $displayData.PosterData = $null
    }
    
    # Remove raw poster URL from output (we have PosterData now)
    $displayData.Remove('Poster')
    
    return $displayData
}

#endregion
