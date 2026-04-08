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
        - Converting overview to plot
        - Detecting content type (movie vs series)

        Poster data is provided separately by OMDb (smaller, more reliable).
    .PARAMETER ScanResult
        A single item from the ManualImport scan response. Should contain either:
        - movie object (Radarr)
        - series object (Sonarr)
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER PlotMaxLength
        Maximum length for plot/overview text (0 = no truncation, default: 150).
    .OUTPUTS
        Hashtable matching OmdbData format, or $null if no metadata available.
        Structure:
        - Title, Year, ImdbId, ImdbRating, RottenTomatoes, Metacritic
        - Genre, Runtime, Plot, Type, TotalSeasons
        - Source = 'arr' (to identify metadata source)
    .EXAMPLE
        $scan = Invoke-SAArrManualImportScan -AppType 'Radarr' -Config $config -ScanPath $path
        $metadata = ConvertTo-SAArrMetadata -ScanResult $scan.ScanResults[0] -AppType 'Radarr'
    .NOTES
        The PosterData property is populated separately from OMDb during email metadata merging.
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
    
    # Determine content type and total seasons (for series)
    $contentType = if ($AppType -eq 'Radarr') { 'movie' } else { 'series' }
    $totalSeasons = $null
    if ($AppType -eq 'Sonarr' -and $null -ne $media.statistics -and $media.statistics.seasonCount -gt 0) {
        $totalSeasons = [string]$media.statistics.seasonCount
    }

    # Build normalized result (poster comes from OMDb, not *arr)
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
        PosterData     = $null
        Type           = $contentType
        TotalSeasons   = $totalSeasons
        Source         = 'arr'
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

    # Comma operator forces array shape preservation across the function boundary.
    # Without it, PowerShell unwraps a single-element array to its scalar element,
    # so a single PSCustomObject scan result would expose its property names via
    # .Count instead of returning 1.
    return , $importable
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
    
    # TBA / missing title rejections
    if ($lower -match 'tba title|does not have a title') {
        return 'Episode title TBA'
    }

    # Missing absolute episode number (anime)
    if ($lower -match 'absolute episode number') {
        return 'Missing absolute episode number'
    }

    # Disk space
    if ($lower -match 'free space|not enough space') {
        return 'Not enough disk space'
    }

    # Scene mapping
    if ($lower -match 'unverified.*scene|xem|scene.*mapping') {
        return 'Unverified scene mapping'
    }

    # No audio tracks
    if ($lower -match 'no audio') {
        return 'No audio tracks'
    }

    # Full season
    if ($lower -match 'full season|all episodes in season') {
        return 'Full season file'
    }

    # Partial season
    if ($lower -match 'partial season') {
        return 'Partial season pack'
    }

    # Episode mismatch
    if ($lower -match 'unexpected.*considering') {
        return 'Unexpected episode'
    }

    # Existing file has more episodes
    if ($lower -match 'more episodes') {
        return 'Existing file has more episodes'
    }

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
