#Requires -Version 5.1
<#
.SYNOPSIS
    *arr metadata extraction and normalization for Stagearr
.DESCRIPTION
    Functions for extracting and normalizing metadata from Radarr/Sonarr ManualImport scan results
    into a format compatible with the existing email system (OmdbData structure).
    
    This enables rich email notifications (poster, ratings, genre) without requiring a separate
    OMDb API call for users with Radarr/Sonarr.
    
    Pure helper functions:
    - ConvertTo-SAArrMetadata: Extract metadata from scan result into OmdbData format
    - Get-SAImportableFiles: Filter scan results to importable files only
    - Get-SARejectionSummary: Get rejection counts and reasons for logging/email
    
    HTTP functions:
    - Get-SAArrPosterData: Download poster from TMDb URL
    
    Design principles:
    - Output format matches existing OmdbData for drop-in replacement
    - Pure functions where possible (no I/O) for unit testability
    - Graceful failure: Returns $null or empty results on errors
    - Verbose-only output: No console output, only verbose for troubleshooting
#>

#region Pure Helper Functions

function ConvertTo-SAArrMetadata {
    <#
    .SYNOPSIS
        Extracts metadata from a *arr scan result into OmdbData-compatible format.
    .DESCRIPTION
        Pure function - converts scan result metadata into the normalized format used by
        the email system. The output structure matches Get-SAOmdbMetadata for drop-in use.
        
        Handles:
        - Extracting movie/series metadata (title, year, IMDb ID)
        - Normalizing ratings from ratings object (IMDb, Rotten Tomatoes, Metacritic)
        - Building TMDb poster URL with configurable size
        - Converting overview to plot
        - Detecting content type (movie vs series)
        
        Does NOT download the poster - use Get-SAArrPosterData for that.
    .PARAMETER ScanResult
        A single item from the ManualImport scan response. Should contain either:
        - movie object (Radarr)
        - series object (Sonarr)
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER PosterSize
        TMDb poster size: 'w92', 'w185', 'w500', or 'original' (default: 'w185').
    .PARAMETER PlotMaxLength
        Maximum length for plot/overview text (0 = no truncation, default: 150).
    .OUTPUTS
        Hashtable matching OmdbData format, or $null if no metadata available.
        Structure:
        - Title, Year, ImdbId, ImdbRating, RottenTomatoes, Metacritic
        - Genre, Runtime, Plot, Type, TotalSeasons
        - PosterUrl (TMDb URL - not yet downloaded)
        - Source = 'arr' (to identify metadata source)
    .EXAMPLE
        $scan = Invoke-SAArrManualImportScan -AppType 'Radarr' -Config $config -ScanPath $path
        $metadata = ConvertTo-SAArrMetadata -ScanResult $scan.ScanResults[0] -AppType 'Radarr'
    .NOTES
        The PosterData property is NOT populated by this function. Use Get-SAArrPosterData
        separately to download the poster after checking if poster display is enabled.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$ScanResult,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,
        
        [Parameter()]
        [ValidateSet('w92', 'w185', 'w500', 'original')]
        [string]$PosterSize = 'w185',
        
        [Parameter()]
        [int]$PlotMaxLength = 150
    )
    
    # Validate input
    if ($null -eq $ScanResult) {
        return $null
    }
    
    # Get the media object based on app type
    $media = if ($AppType -eq 'Radarr') { $ScanResult.movie } else { $ScanResult.series }
    
    if ($null -eq $media) {
        return $null
    }
    
    # Helper to normalize empty/whitespace to $null
    $normalizeValue = {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $null
        }
        return $Value.Trim()
    }
    
    # Extract ratings from the ratings object
    # Structure: ratings.imdb.value, ratings.rottenTomatoes.value, ratings.metacritic.value
    $imdbRating = $null
    $rottenTomatoes = $null
    $metacritic = $null
    
    if ($null -ne $media.ratings) {
        # IMDb rating (format: decimal like 7.4)
        if ($null -ne $media.ratings.imdb -and $null -ne $media.ratings.imdb.value) {
            $imdbRating = [string]$media.ratings.imdb.value
        }
        
        # Rotten Tomatoes (format: percentage like 85)
        if ($null -ne $media.ratings.rottenTomatoes -and $null -ne $media.ratings.rottenTomatoes.value) {
            $rtValue = $media.ratings.rottenTomatoes.value
            if ($rtValue -gt 0) {
                $rottenTomatoes = "$rtValue%"
            }
        }
        
        # Metacritic (format: score like 80)
        if ($null -ne $media.ratings.metacritic -and $null -ne $media.ratings.metacritic.value) {
            $mcValue = $media.ratings.metacritic.value
            if ($mcValue -gt 0) {
                $metacritic = [string]$mcValue
            }
        }
    }
    
    # Extract genres - array of strings
    $genre = $null
    if ($null -ne $media.genres -and $media.genres.Count -gt 0) {
        $genre = ($media.genres -join ', ')
    }
    
    # Extract runtime (in minutes)
    $runtime = $null
    if ($media.runtime -gt 0) {
        $runtime = "$($media.runtime) min"
    }
    
    # Extract plot/overview with optional truncation
    $plot = & $normalizeValue $media.overview
    if ($null -ne $plot -and $PlotMaxLength -gt 0 -and $plot.Length -gt $PlotMaxLength) {
        $plot = $plot.Substring(0, $PlotMaxLength - 3).TrimEnd() + '...'
    }
    
    # Extract poster URLs
    # remoteUrl: CDN URL (TMDb/TheTVDB) — kept as fallback reference
    # url: local *arr proxy path (e.g. /MediaCover/123/poster.jpg) — preferred source
    $posterUrl = $null
    $posterLocalPath = $null
    if ($null -ne $media.images -and $media.images.Count -gt 0) {
        $posterImage = $media.images | Where-Object { $_.coverType -eq 'poster' } | Select-Object -First 1
        if ($null -ne $posterImage) {
            if (-not [string]::IsNullOrWhiteSpace($posterImage.remoteUrl)) {
                $posterUrl = $posterImage.remoteUrl -replace '/original/', "/$PosterSize/"
            }
            if (-not [string]::IsNullOrWhiteSpace($posterImage.url)) {
                $posterLocalPath = $posterImage.url
            }
        }
    }
    
    # Determine content type and total seasons (for series)
    $contentType = if ($AppType -eq 'Radarr') { 'movie' } else { 'series' }
    $totalSeasons = $null
    if ($AppType -eq 'Sonarr' -and $null -ne $media.statistics -and $media.statistics.seasonCount -gt 0) {
        $totalSeasons = [string]$media.statistics.seasonCount
    }
    
    # Build normalized result
    $result = @{
        Title          = & $normalizeValue $media.title
        Year           = if ($media.year -gt 0) { [string]$media.year } else { $null }
        ImdbId         = & $normalizeValue $media.imdbId
        ImdbRating     = $imdbRating
        RottenTomatoes = $rottenTomatoes
        Metacritic     = $metacritic
        Genre          = $genre
        Runtime        = $runtime
        Plot           = $plot
        PosterUrl       = $posterUrl       # CDN URL — fallback reference
        PosterLocalPath = $posterLocalPath  # Local *arr path — preferred for download
        PosterData      = $null            # Will be populated by Get-SAArrPosterData
        Type           = $contentType
        TotalSeasons   = $totalSeasons
        Source         = 'arr'           # Indicates metadata source (not OMDb)
    }
    
    return $result
}

function Get-SAImportableFiles {
    <#
    .SYNOPSIS
        Filters scan results to only files that can be imported.
    .DESCRIPTION
        Pure function - filters an array of scan results to return only files without
        permanent rejections. Temporary rejections are allowed through (they may resolve).
        
        Rejection types:
        - permanent: File cannot be imported (sample, quality exists, parse error)
        - temporary: Issue may resolve (downloading, locked, etc.)
        
        Files with empty rejections array or no rejections property are considered importable.
    .PARAMETER ScanResults
        Array of file objects from Invoke-SAArrManualImportScan.
    .PARAMETER AllowTemporaryRejections
        If $true (default), files with only temporary rejections are included.
        If $false, any rejection excludes the file.
    .OUTPUTS
        Array of importable file objects (may be empty).
    .EXAMPLE
        $scan = Invoke-SAArrManualImportScan -AppType 'Radarr' -Config $config -ScanPath $path
        $importable = Get-SAImportableFiles -ScanResults $scan.ScanResults
        if ($importable.Count -eq 0) {
            Write-SAOutcome -Level Warning -Label 'Radarr' -Text 'No importable files found'
        }
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$ScanResults,
        
        [Parameter()]
        [bool]$AllowTemporaryRejections = $true
    )
    
    # Handle null or empty input
    if ($null -eq $ScanResults -or $ScanResults.Count -eq 0) {
        return @()
    }
    
    $importable = @()
    
    foreach ($file in $ScanResults) {
        # No rejections property or empty array = importable
        if ($null -eq $file.rejections -or $file.rejections.Count -eq 0) {
            $importable += $file
            continue
        }
        
        if ($AllowTemporaryRejections) {
            # Check if ALL rejections are temporary (none permanent)
            $hasPermanent = $file.rejections | Where-Object { $_.type -eq 'permanent' }
            if ($null -eq $hasPermanent -or @($hasPermanent).Count -eq 0) {
                $importable += $file
            }
        }
        # If AllowTemporaryRejections is $false, any rejection excludes the file
    }
    
    return $importable
}

function Get-SARejectionSummary {
    <#
    .SYNOPSIS
        Summarizes rejections from scan results for logging and email.
    .DESCRIPTION
        Pure function - analyzes rejection reasons across all scan results and produces
        a summary suitable for console output, email notes, and logging.
        
        Groups rejections by reason and provides:
        - Total file count
        - Importable count
        - Rejected count by type (permanent vs temporary)
        - Unique reasons with counts
        - Human-readable summary message
    .PARAMETER ScanResults
        Array of file objects from Invoke-SAArrManualImportScan.
    .OUTPUTS
        PSCustomObject with:
        - TotalFiles: Total number of files scanned
        - ImportableCount: Files without permanent rejections
        - RejectedCount: Files with at least one permanent rejection
        - PermanentCount: Count of files with permanent rejections
        - TemporaryCount: Count of files with only temporary rejections
        - Reasons: Hashtable of reason -> count
        - PrimaryReason: Most common rejection reason
        - Message: Human-readable summary (e.g., "7 files skipped (Quality exists)")
        - IsAllRejected: $true if no files are importable
        - IsPartialRejected: $true if some (but not all) files rejected
    .EXAMPLE
        $scan = Invoke-SAArrManualImportScan -AppType 'Radarr' -Config $config -ScanPath $path
        $summary = Get-SARejectionSummary -ScanResults $scan.ScanResults
        if ($summary.IsAllRejected) {
            Write-SAOutcome -Level Warning -Label 'Radarr' -Text $summary.Message
        }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$ScanResults
    )
    
    # Initialize result
    $result = [PSCustomObject]@{
        TotalFiles        = 0
        ImportableCount   = 0
        RejectedCount     = 0
        PermanentCount    = 0
        TemporaryCount    = 0
        Reasons           = @{}
        PrimaryReason     = $null
        Message           = $null
        IsAllRejected     = $false
        IsPartialRejected = $false
    }
    
    # Handle null or empty input
    if ($null -eq $ScanResults -or $ScanResults.Count -eq 0) {
        $result.Message = 'No files found'
        $result.IsAllRejected = $true
        return $result
    }
    
    $result.TotalFiles = $ScanResults.Count
    
    # Track rejection reasons
    $reasonCounts = @{}
    $permanentFiles = @()
    $temporaryOnlyFiles = @()
    $cleanFiles = @()
    
    foreach ($file in $ScanResults) {
        if ($null -eq $file.rejections -or $file.rejections.Count -eq 0) {
            $cleanFiles += $file
            continue
        }
        
        # Check for permanent rejections
        $permanentRejections = $file.rejections | Where-Object { $_.type -eq 'permanent' }
        $temporaryRejections = $file.rejections | Where-Object { $_.type -eq 'temporary' -or $_.type -ne 'permanent' }
        
        if ($null -ne $permanentRejections -and @($permanentRejections).Count -gt 0) {
            $permanentFiles += $file
            # Count each unique permanent rejection reason
            foreach ($rejection in $permanentRejections) {
                $reason = Get-SASimplifiedRejectionReason -Reason $rejection.reason
                if (-not $reasonCounts.ContainsKey($reason)) {
                    $reasonCounts[$reason] = 0
                }
                $reasonCounts[$reason]++
            }
        } elseif ($null -ne $temporaryRejections -and @($temporaryRejections).Count -gt 0) {
            $temporaryOnlyFiles += $file
        } else {
            $cleanFiles += $file
        }
    }
    
    # Calculate counts
    $result.ImportableCount = $cleanFiles.Count + $temporaryOnlyFiles.Count
    $result.RejectedCount = $permanentFiles.Count
    $result.PermanentCount = $permanentFiles.Count
    $result.TemporaryCount = $temporaryOnlyFiles.Count
    $result.Reasons = $reasonCounts
    
    # Determine primary reason (most common)
    if ($reasonCounts.Count -gt 0) {
        $result.PrimaryReason = ($reasonCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
    }
    
    # Set flags
    $result.IsAllRejected = ($result.ImportableCount -eq 0)
    $result.IsPartialRejected = ($result.RejectedCount -gt 0 -and $result.ImportableCount -gt 0)
    
    # Build human-readable message
    if ($result.IsAllRejected) {
        $fileWord = Get-SAPluralForm -Count $result.TotalFiles -Singular 'file'
        if ($result.PrimaryReason) {
            $result.Message = "$($result.TotalFiles) $fileWord skipped ($($result.PrimaryReason))"
        } else {
            $result.Message = "All $($result.TotalFiles) $fileWord rejected"
        }
    } elseif ($result.IsPartialRejected) {
        $fileWord = Get-SAPluralForm -Count $result.RejectedCount -Singular 'file'
        if ($result.PrimaryReason) {
            $result.Message = "$($result.RejectedCount) $fileWord skipped ($($result.PrimaryReason))"
        } else {
            $result.Message = "$($result.RejectedCount) $fileWord rejected"
        }
    } else {
        $fileWord = Get-SAPluralForm -Count $result.ImportableCount -Singular 'file'
        $result.Message = "$($result.ImportableCount) $fileWord ready for import"
    }
    
    return $result
}

function Get-SASimplifiedRejectionReason {
    <#
    .SYNOPSIS
        Simplifies verbose rejection reasons to user-friendly text.
    .DESCRIPTION
        Pure function - converts verbose *arr rejection reasons to concise,
        user-friendly messages suitable for console output and email.
    .PARAMETER Reason
        Raw rejection reason string from *arr API.
    .OUTPUTS
        Simplified reason string.
    .EXAMPLE
        Get-SASimplifiedRejectionReason -Reason "Not an upgrade for existing movie file(s)"
        # Returns: "Quality exists"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Reason
    )
    
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return 'Unknown'
    }
    
    # Normalize: lowercase for matching
    $lower = $Reason.ToLower()
    
    # Quality/upgrade rejections
    if ($lower -match 'not.*upgrade|existing.*file|cutoff.*met|quality.*met') {
        return 'Quality exists'
    }
    
    # Sample file rejections
    if ($lower -match 'sample') {
        return 'Sample file'
    }
    
    # Parse failures
    if ($lower -match 'unable.*parse|cannot.*parse|unrecognized|unknown.*series|unknown.*movie') {
        return 'Cannot parse'
    }
    
    # Already imported
    if ($lower -match 'already.*imported|imported.*file') {
        return 'Already imported'
    }
    
    # File in use/locked
    if ($lower -match 'in use|locked|access.*denied') {
        return 'File locked'
    }
    
    # Path/folder issues
    if ($lower -match 'path.*not.*exist|folder.*not.*exist|not.*found') {
        return 'Path not found'
    }
    
    # No match - return truncated original (first 30 chars)
    if ($Reason.Length -gt 30) {
        return $Reason.Substring(0, 27) + '...'
    }
    
    return $Reason
}

#endregion

#region HTTP Functions

function Get-SAArrPosterData {
    <#
    .SYNOPSIS
        Downloads poster image from TMDb URL.
    .DESCRIPTION
        Downloads a poster image from a TMDb URL and returns it in the format expected
        by the email system (Bytes, MimeType, ContentId).
        
        Reuses the same pattern as Get-SAOmdbPosterData for consistency:
        - Short timeout (5s default) - poster is optional
        - Graceful failure - returns $null on any error
        - Handles PS5.1 vs PS7 binary response differences
        - Generates unique Content-ID for CID embedding
    .PARAMETER PosterUrl
        TMDb poster URL (e.g., https://image.tmdb.org/t/p/w185/abc123.jpg).
    .PARAMETER TimeoutSeconds
        Request timeout (default: 5).
    .OUTPUTS
        Hashtable with Bytes, MimeType, ContentId - or $null on failure.
    .EXAMPLE
        $metadata = ConvertTo-SAArrMetadata -ScanResult $file -AppType 'Radarr'
        if ($metadata.PosterUrl) {
            $metadata.PosterData = Get-SAArrPosterData -PosterUrl $metadata.PosterUrl
        }
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
    if ([string]::IsNullOrWhiteSpace($PosterUrl)) {
        return $null
    }
    
    # Quick validation that this looks like a known poster source
    if ($PosterUrl -notmatch 'image\.tmdb\.org|themoviedb\.org|thetvdb\.com') {
        Write-SAVerbose -Label 'Poster' -Text "Unexpected poster URL format: $PosterUrl"
        # Still try to download - may be a different image host
    }

    Write-SAVerbose -Label 'Poster' -Text "Downloading poster..."
    
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
            Write-SAVerbose -Label 'Poster' -Text "Poster download failed: HTTP $($response.StatusCode)"
            return $null
        }
        
        # Get raw bytes - handle PS5.1 vs PS7 differences
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
            Write-SAVerbose -Label 'Poster' -Text 'Content returned as string, attempting byte conversion'
            $imageBytes = [System.Text.Encoding]::ISO88591.GetBytes($response.Content)
        } else {
            # Fallback - try direct assignment
            $imageBytes = $response.Content
        }
        
        if ($null -eq $imageBytes -or $imageBytes.Length -eq 0) {
            Write-SAVerbose -Label 'Poster' -Text 'Poster download returned empty content'
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
        # Format: poster-{short-guid}.{ext}
        $ext = switch ($mimeType) {
            'image/png'  { '.png' }
            'image/gif'  { '.gif' }
            'image/webp' { '.webp' }
            default      { '.jpg' }
        }
        $contentId = "poster-$([guid]::NewGuid().ToString('N').Substring(0, 8))$ext"
        
        $sizeKb = [math]::Round($imageBytes.Length / 1024, 0)
        Write-SAVerbose -Label 'Poster' -Text "Downloaded ($sizeKb KB, CID: $contentId)"
        
        return @{
            Bytes     = $imageBytes
            MimeType  = $mimeType
            ContentId = $contentId
        }
        
    } catch [System.Net.WebException] {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match 'timed out') {
            Write-SAVerbose -Label 'Poster' -Text "Poster download timed out after $TimeoutSeconds seconds"
        } elseif ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            Write-SAVerbose -Label 'Poster' -Text 'Poster not found (404)'
        } else {
            Write-SAVerbose -Label 'Poster' -Text "Poster download failed: $errorMsg"
        }
        return $null
        
    } catch {
        Write-SAVerbose -Label 'Poster' -Text "Poster download failed: $($_.Exception.Message)"
        return $null
    }
}

#endregion

#region Convenience Functions

function Get-SAArrMetadataFromScan {
    <#
    .SYNOPSIS
        Extracts metadata from scan results and optionally downloads poster.
    .DESCRIPTION
        Convenience function that combines ConvertTo-SAArrMetadata and Get-SAArrPosterData.
        Extracts metadata from the first scan result with media information and optionally
        downloads the poster.
    .PARAMETER ScanResults
        Array of file objects from Invoke-SAArrManualImportScan.
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER DownloadPoster
        Whether to download the poster image (default: $true).
    .PARAMETER PosterSize
        TMDb poster size: 'w92', 'w185', 'w500', or 'original' (default: 'w185').
    .PARAMETER PlotMaxLength
        Maximum length for plot/overview text (0 = no truncation, default: 150).
    .OUTPUTS
        Hashtable matching OmdbData format with PosterData populated, or $null.
    .EXAMPLE
        $scan = Invoke-SAArrManualImportScan -AppType 'Radarr' -Config $config -ScanPath $path
        $metadata = Get-SAArrMetadataFromScan -ScanResults $scan.ScanResults -AppType 'Radarr'
        # $metadata now has PosterData populated (if available)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$ScanResults,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,
        
        [Parameter()]
        [bool]$DownloadPoster = $true,
        
        [Parameter()]
        [ValidateSet('w92', 'w185', 'w500', 'original')]
        [string]$PosterSize = 'w185',
        
        [Parameter()]
        [int]$PlotMaxLength = 150
    )
    
    # Handle null or empty input
    if ($null -eq $ScanResults -or $ScanResults.Count -eq 0) {
        return $null
    }
    
    # Find first file with media metadata
    $fileWithMetadata = $null
    foreach ($file in $ScanResults) {
        $media = if ($AppType -eq 'Radarr') { $file.movie } else { $file.series }
        if ($null -ne $media -and -not [string]::IsNullOrWhiteSpace($media.title)) {
            $fileWithMetadata = $file
            break
        }
    }
    
    if ($null -eq $fileWithMetadata) {
        Write-SAVerbose -Label 'TMDb' -Text 'No files with metadata found in scan results'
        return $null
    }
    
    # Extract metadata
    $metadata = ConvertTo-SAArrMetadata -ScanResult $fileWithMetadata -AppType $AppType -PosterSize $PosterSize -PlotMaxLength $PlotMaxLength
    
    if ($null -eq $metadata) {
        return $null
    }
    
    # Download poster if enabled and URL available
    if ($DownloadPoster -and -not [string]::IsNullOrWhiteSpace($metadata.PosterUrl)) {
        $metadata.PosterData = Get-SAArrPosterData -PosterUrl $metadata.PosterUrl
    }
    
    # Log metadata summary
    $title = if ($metadata.Title) { $metadata.Title } else { 'Unknown' }
    $year = if ($metadata.Year) { " ($($metadata.Year))" } else { '' }
    $rating = if ($metadata.ImdbRating) { "IMDb $($metadata.ImdbRating)" } else { 'no rating' }
    $checkmark = [char]0x2713
    $poster = if ($metadata.PosterData) { "poster $checkmark" } else { 'no poster' }
    Write-SAVerbose -Label 'TMDb' -Text "Extracted: $title$year - $rating, $poster"
    
    return $metadata
}

#endregion
