#Requires -Version 5.1
<#
.SYNOPSIS
    Radarr and Sonarr (Arr) import functions for Stagearr
.DESCRIPTION
    Handles import/scan triggers for *arr applications (Radarr, Sonarr).
    Both applications share the same API structure, so generic functions
    handle both with app-specific configuration.
    
    Uses ManualImport API flow (Phase 3) for:
    - Pre-flight validation: Know rejection reasons before import attempt
    - Rich metadata: Title, year, ratings, poster URL from *arr (no OMDb needed)
    - Clear messaging: Distinguish between all rejected, partial rejection, and success
    - Email enrichment: ArrMetadata available for email notifications
    
    Exported functions:
    - Invoke-SAArrImport: Main import logic using ManualImport flow (generic)
    - Test-SAArrConnection: Connection test (generic)
    - Get-SAArrRecentErrors: Error log retrieval (generic)
    - Invoke-SAArrManualImportScan: Scan folder for importable files with metadata
    - Invoke-SAArrManualImportExecute: Execute import for specific files
    - Get-SAErrorTypeFromRejection: Map rejection reasons to error types
    
    Convenience wrappers (for semantic clarity):
    - Invoke-SARadarrImport, Invoke-SASonarrImport
    - Test-SARadarrConnection, Test-SASonarrConnection
    - Get-SARadarrRecentErrors, Get-SASonarrRecentErrors
    - Invoke-SARadarrManualImportScan, Invoke-SASonarrManualImportScan
    - Invoke-SARadarrManualImportExecute, Invoke-SASonarrManualImportExecute
    
    Internal helpers:
    - Invoke-SAImporterCommand: Send command to API
    - Wait-SAImporterCommand: Poll for command completion
    
    Dependencies:
    - Private/ImportUtility.ps1 (URL building, path translation)
    - Private/ImportResultParser.ps1 (error parsing, hints)
    - Private/ArrMetadata.ps1 (metadata extraction, filtering)
#>

#region Arr App Configuration

# Configuration lookup table for *arr applications (Radarr, Sonarr)
# This enables generic functions to handle both apps with minimal code duplication
# Note: Uses ManualImport API exclusively (legacy DownloadedMoviesScan/DownloadedEpisodesScan removed)
$script:ArrConfig = @{
    Radarr = @{
        Label                = 'Radarr'
        ApiVersion           = 'v3'
        CommandEndpoint      = '/api/v3/command'
        StatusEndpoint       = '/api/v3/system/status'
        LogEndpoint          = '/api/v3/log'
        ManualImportEndpoint = '/api/v3/manualimport'
        MediaIdProperty      = 'movieId'      # Property name for media ID in ManualImport
    }
    Sonarr = @{
        Label                = 'Sonarr'
        ApiVersion           = 'v3'
        CommandEndpoint      = '/api/v3/command'
        StatusEndpoint       = '/api/v3/system/status'
        LogEndpoint          = '/api/v3/log'
        ManualImportEndpoint = '/api/v3/manualimport'
        MediaIdProperty      = 'seriesId'     # Property name for media ID in ManualImport
    }
}

#endregion

#region Generic Arr Functions

function Invoke-SAArrImport {
    <#
    .SYNOPSIS
        Triggers a *arr application (Radarr/Sonarr) to scan and import media using ManualImport API.
    .DESCRIPTION
        Generic import function that handles both Radarr and Sonarr using ManualImport API flow:
        
        1. SCAN - Call ManualImport API to get files with metadata and rejections
        2. EXTRACT - Extract normalized metadata early (for email enrichment even on failure)
        3. FILTER - Identify importable files vs rejected files using pre-flight validation
        4. IMPORT - Execute ManualImport for filtered files only
        
        This approach provides significant benefits:
        - Pre-flight validation: Know rejection reasons before import attempt
        - Rich metadata: Title, year, ratings, poster URL from *arr (no OMDb needed)
        - Clear messaging: Distinguish between all rejected, partial rejection, and success
        - Email enrichment: ArrMetadata available for email notifications
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER Config
        Application configuration hashtable (host, port, apiKey, importMode, etc.).
    .PARAMETER StagingPath
        Path to the staging folder containing the media.
    .PARAMETER StagingRoot
        Root staging folder for relative path calculation.
    .PARAMETER DownloadId
        Optional download client ID (torrent hash). Passed to ManualImport to associate the import with the download client history entry.
    .OUTPUTS
        PSCustomObject with:
        - Success: Boolean indicating if import completed (or was intentionally skipped)
        - Message: Status message
        - Duration: Total time taken in seconds
        - ImportedFiles: Array of imported file paths
        - SkippedFiles: Array of rejected file paths
        - SkippedCount: Count of skipped files
        - ArrMetadata: Normalized metadata from scan (for email enrichment)
        - Skipped: $true if all files were intentionally skipped (not an error)
        - QualityRejected: $true if rejection was due to quality/upgrade
        - ErrorType: Categorized error type for hint generation
    .EXAMPLE
        $result = Invoke-SAArrImport -AppType 'Radarr' -Config $config.importers.radarr -StagingPath "C:\Staging\Movie\Film"
        if ($result.ArrMetadata) {
            # Use metadata for email enrichment
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        
        [Parameter()]
        [string]$StagingRoot,
        
        [Parameter()]
        [string]$DownloadId
    )
    
    $startTime = Get-Date
    
    # Get app-specific configuration
    $appConfig = $script:ArrConfig[$AppType]
    $label = $appConfig.Label
    
    # Build base URL (returns object with Url, DisplayUrl, and HostHeader)
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    Write-SAVerbose -Text "$label server: $($urlInfo.DisplayUrl)"
    Write-SAVerbose -Text "Connecting to: $($urlInfo.Url)"
    
    # Helper to calculate duration
    $getDuration = { [int]((Get-Date) - $startTime).TotalSeconds }
    
    # Test API connection
    if (-not (Test-SAArrConnection -AppType $AppType -Config $Config)) {
        Write-SAOutcome -Level Error -Label $label -Text "Cannot connect to API" -Indent 1
        return [PSCustomObject]@{
            Success       = $false
            Message       = 'Connection failed'
            Duration      = (& $getDuration)
            ImportedFiles = @()
            SkippedFiles  = @()
            ArrMetadata   = $null
        }
    }
    
    # Handle remote path mapping
    $importPath = $StagingPath
    if (-not [string]::IsNullOrWhiteSpace($Config.remotePath)) {
        $importPath = Convert-SAToRemotePath -LocalPath $StagingPath -RemotePath $Config.remotePath -StagingRoot $StagingRoot
        if ($importPath -ne $StagingPath) {
            Write-SAVerbose -Text "Path translated: $StagingPath -> $importPath"
        }
    }
    
    # Keep backslashes for *arr apps on Windows - they reject forward slashes
    
    # ==========================================================================
    # STEP 1: SCAN - Get files with metadata and rejections
    # ==========================================================================
    Write-SAProgress -Label $label -Text "Scanning folder..." -Indent 1
    
    $scanResult = Invoke-SAArrManualImportScan -AppType $AppType -Config $Config -ScanPath $importPath
    
    if (-not $scanResult.Success) {
        Write-SAOutcome -Level Error -Label $label -Text "Scan failed: $($scanResult.ErrorMessage)" -Indent 1
        Add-SAEmailException -Message "Scan failed: $($scanResult.ErrorMessage)" -Type Error
        return [PSCustomObject]@{
            Success       = $false
            Message       = "Scan failed: $($scanResult.ErrorMessage)"
            Duration      = (& $getDuration)
            ImportedFiles = @()
            SkippedFiles  = @()
            ArrMetadata   = $null
        }
    }
    
    # Check for empty scan results
    if ($null -eq $scanResult.ScanResults -or $scanResult.ScanResults.Count -eq 0) {
        Write-SAOutcome -Level Warning -Label $label -Text "No files found in folder" -Indent 1
        Add-SAEmailException -Message "No files found in folder" -Type Warning
        return [PSCustomObject]@{
            Success       = $false
            Message       = 'No files found'
            Duration      = (& $getDuration)
            ImportedFiles = @()
            SkippedFiles  = @()
            ArrMetadata   = $null
        }
    }
    
    # ==========================================================================
    # STEP 2: EXTRACT - Get metadata early (available even on rejection/failure)
    # ==========================================================================
    # Wrap in @() for PS5.1 single-element array safety
    $scanItems = @($scanResult.ScanResults)
    if ($scanItems.Count -eq 0) {
        Write-SAOutcome -Level Warning -Label $label -Text "Scan returned empty results" -Indent 1
        return [PSCustomObject]@{
            Success       = $false
            Message       = 'Empty scan results'
            Duration      = (& $getDuration)
            ImportedFiles = @()
            SkippedFiles  = @()
            ArrMetadata   = $null
        }
    }
    $arrMetadata = ConvertTo-SAArrMetadata -ScanResult $scanItems[0] -AppType $AppType
    
    # ==========================================================================
    # STEP 3: FILTER - Identify importable files vs rejected files
    # ==========================================================================
    $importableFiles = Get-SAImportableFiles -ScanResults $scanItems
    $rejectionSummary = Get-SARejectionSummary -ScanResults $scanItems
    
    Write-SAVerbose -Text "Filter results: $($importableFiles.Count) importable, $($rejectionSummary.RejectedCount) rejected"
    
    # Track skipped file paths for return object
    $skippedFilePaths = @()
    foreach ($file in $scanItems) {
        if ($null -ne $file.rejections -and $file.rejections.Count -gt 0) {
            $hasPermanent = $file.rejections | Where-Object { $_.type -eq 'permanent' }
            if ($null -ne $hasPermanent -and @($hasPermanent).Count -gt 0) {
                $skippedFilePaths += $file.path
            }
        }
    }
    
    # ==========================================================================
    # STEP 4: HANDLE REJECTIONS
    # ==========================================================================
    
    # Map rejection reasons to error types for hint compatibility
    $errorType = Get-SAErrorTypeFromRejection -PrimaryReason $rejectionSummary.PrimaryReason
    
    # All files rejected - return warning (not error)
    if ($rejectionSummary.IsAllRejected) {
        Write-SAOutcome -Level Warning -Label $label -Text $rejectionSummary.Message -Duration (& $getDuration) -Indent 1
        Add-SAEmailException -Message $rejectionSummary.Message -Type Warning
        
        # Show hint for quality rejections
        if ($errorType -eq 'quality') {
            $hint = Get-SAImportHint -ErrorType $errorType -ImporterLabel $label
            if ($hint) {
                Write-SAProgress -Label "Hint" -Text $hint -Indent 2
            }
        }
        
        # Determine if this is a quality rejection (still considered success)
        $isQualityRejected = ($errorType -eq 'quality')
        
        return [PSCustomObject]@{
            Success         = $true  # Skip is not an error
            Message         = $rejectionSummary.Message
            Duration        = (& $getDuration)
            ImportedFiles   = @()
            SkippedFiles    = $skippedFilePaths
            SkippedCount    = $rejectionSummary.RejectedCount
            ArrMetadata     = $arrMetadata
            Skipped         = $true
            QualityRejected = $isQualityRejected
            ErrorType       = $errorType
        }
    }
    
    # Partial rejection - log warning, continue with importable files
    if ($rejectionSummary.IsPartialRejected) {
        Write-SAOutcome -Level Warning -Label $label -Text $rejectionSummary.Message -Indent 1
        Add-SAEmailException -Message $rejectionSummary.Message -Type Warning
    }
    
    # ==========================================================================
    # STEP 5: IMPORT - Execute ManualImport for filtered files
    # ==========================================================================
    Write-SAProgress -Label $label -Text "Sending for import..." -Indent 1
    
    # Get import mode from config (default: move)
    $importMode = if ($Config.importMode) { $Config.importMode } else { 'move' }
    
    $importResult = Invoke-SAArrManualImportExecute -AppType $AppType -Config $Config -Files $importableFiles -ImportMode $importMode -DownloadId $DownloadId
    
    # Track imported file paths
    $importedFilePaths = @()
    if ($importResult.Success) {
        foreach ($file in $importableFiles) {
            $importedFilePaths += $file.path
        }
    }
    
    # ==========================================================================
    # STEP 6: BUILD RESULT
    # ==========================================================================
    
    if ($importResult.Success) {
        $successMsg = "Imported"
        if ($rejectionSummary.IsPartialRejected) {
            $fileWord = Get-SAPluralForm -Count $importableFiles.Count -Singular 'file'
            $successMsg = "Imported $($importableFiles.Count) $fileWord"
        }
        Write-SAOutcome -Level Success -Label $label -Text $successMsg -Duration $importResult.Duration -Indent 1
        
        return [PSCustomObject]@{
            Success         = $true
            Message         = $successMsg
            Duration        = $importResult.Duration
            ImportedFiles   = $importedFilePaths
            SkippedFiles    = $skippedFilePaths
            SkippedCount    = $rejectionSummary.RejectedCount
            ArrMetadata     = $arrMetadata
            Skipped         = $false
            QualityRejected = $false
            ErrorType       = $null
        }
    } else {
        # Import command failed
        Write-SAOutcome -Level Error -Label $label -Text $importResult.Message -Duration $importResult.Duration -Indent 1
        
        # Show hint if we can identify the error type
        $hint = Get-SAImportHint -ErrorType 'unknown' -ImporterLabel $label
        if ($hint) {
            Write-SAProgress -Label "Hint" -Text $hint -Indent 2
        }
        
        Add-SAEmailException -Message $importResult.Message -Type Error
        
        return [PSCustomObject]@{
            Success         = $false
            Message         = $importResult.Message
            Duration        = $importResult.Duration
            ImportedFiles   = @()
            SkippedFiles    = $skippedFilePaths
            SkippedCount    = $rejectionSummary.RejectedCount
            ArrMetadata     = $arrMetadata
            Skipped         = $false
            QualityRejected = $false
            ErrorType       = 'unknown'
        }
    }
}

function Get-SAErrorTypeFromRejection {
    <#
    .SYNOPSIS
        Maps rejection reasons to error types for hint compatibility.
    .DESCRIPTION
        Converts simplified rejection reasons from Get-SARejectionSummary to error types
        that work with the existing Get-SAImportHint function.
    .PARAMETER PrimaryReason
        Primary rejection reason from Get-SARejectionSummary.
    .OUTPUTS
        Error type string compatible with Get-SAImportHint.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$PrimaryReason
    )
    
    if ([string]::IsNullOrWhiteSpace($PrimaryReason)) {
        return 'unknown'
    }
    
    # Map simplified reasons to error types
    switch -Regex ($PrimaryReason.ToLower()) {
        'quality exists'    { return 'quality' }
        'sample'            { return 'sample' }
        'cannot parse'      { return 'parse-error' }
        'already imported'  { return 'already-exists' }
        'file locked'       { return 'permission' }
        'path not found'    { return 'path-not-found' }
        default             { return 'unknown' }
    }
}

function Test-SAArrConnection {
    <#
    .SYNOPSIS
        Tests connection to a *arr application API (Radarr/Sonarr).
    .DESCRIPTION
        Generic connection test that works with both Radarr and Sonarr
        using their shared API structure.
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER Config
        Application configuration hashtable.
    .OUTPUTS
        Boolean indicating connection success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $appConfig = $script:ArrConfig[$AppType]
    $label = $appConfig.Label
    
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $uri = "$($urlInfo.Url)$($appConfig.StatusEndpoint)"
    
    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    
    # Add Host header for reverse proxy compatibility
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }
    
    Write-SAVerbose -Text "Testing $label connection..."
    
    # Use shorter timeout for connection test
    $timeout = $script:SAConstants.ConnectionTestTimeoutSeconds
    $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -MaxRetries 1 -TimeoutSeconds $timeout
    
    if ($result.Success) {
        Write-SAVerbose -Text "$label connection OK"
    } else {
        Write-SAVerbose -Text "$label connection failed: $($result.ErrorMessage)"
    }
    
    return $result.Success
}

function Get-SAArrRecentErrors {
    <#
    .SYNOPSIS
        Fetches recent error logs from a *arr application that match a staging path.
    .DESCRIPTION
        Queries the *arr log API for recent errors and filters for messages
        containing the staging path. Used to get detailed failure reasons.
        Works with both Radarr and Sonarr.
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER Config
        Application configuration hashtable.
    .PARAMETER StagingPath
        Path to filter log messages by.
    .PARAMETER MaxMinutesAgo
        Only look at logs from the last N minutes (default: 5).
    .OUTPUTS
        Array of error message strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        
        [Parameter()]
        [int]$MaxMinutesAgo = 5
    )
    
    $appConfig = $script:ArrConfig[$AppType]
    $label = $appConfig.Label
    
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $uri = "$($urlInfo.Url)$($appConfig.LogEndpoint)?pageSize=50&sortKey=time&sortDirection=descending"
    
    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }
    
    $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -TimeoutSeconds 10 -MaxRetries 1
    
    if (-not $result.Success) {
        Write-SAVerbose -Text "Failed to fetch $label logs: $($result.ErrorMessage)"
        return @()
    }
    
    $errors = @()
    # Use UTC for comparison since *arr apps return UTC timestamps
    $cutoffTime = (Get-Date).ToUniversalTime().AddMinutes(-$MaxMinutesAgo)
    
    # Use simple wildcard pattern for -like matching
    $pathPattern = "*$StagingPath*"
    
    foreach ($record in $result.Data.records) {
        # Check if log is recent enough
        # Parse using invariant culture (*arr apps return ISO 8601 format)
        try {
            $logTime = [datetime]::Parse($record.time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch {
            Write-SAVerbose -Text "Failed to parse log time: $($record.time)"
            continue
        }
        if ($logTime -lt $cutoffTime) {
            continue
        }
        
        # Check if it's an error/warn level
        if ($record.level -notin @('error', 'warn', 'Error', 'Warn')) {
            continue
        }
        
        # Check if message contains our staging path (case-insensitive)
        if ($record.message -like $pathPattern) {
            $errors += $record.message
        }
    }
    
    # Return unique errors only
    return $errors | Select-Object -Unique
}

#endregion

#region ManualImport API Functions

function Invoke-SAArrManualImportScan {
    <#
    .SYNOPSIS
        Scans a folder using the *arr ManualImport API and returns importable files with metadata.
    .DESCRIPTION
        Uses GET /api/v3/manualimport to scan a folder and retrieve detailed information about
        files that can be imported, including:
        - Movie/Series metadata (title, year, IMDb ID, poster URL, ratings)
        - Quality information
        - Rejection reasons (permanent vs temporary)
        
        This enables pre-flight validation before import and rich metadata for email notifications
        without requiring a separate OMDb API call.
        
        Works with both Radarr and Sonarr using their shared API structure.
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER Config
        Application configuration hashtable (host, port, apiKey, etc.).
    .PARAMETER ScanPath
        Path to scan for importable files. Should be the remote/translated path if path mapping is used.
    .PARAMETER FilterExistingFiles
        Whether to filter out files that already exist in the library (default: true).
    .OUTPUTS
        PSCustomObject with:
        - Success: Boolean indicating if the scan completed
        - ScanResults: Array of file objects with movie/series metadata and rejections
        - ErrorMessage: Error message if scan failed
    .EXAMPLE
        $scan = Invoke-SAArrManualImportScan -AppType 'Radarr' -Config $config -ScanPath "\\server\downloads\Movie"
        if ($scan.Success) {
            $importable = $scan.ScanResults | Where-Object { $_.rejections.Count -eq 0 }
        }
    .NOTES
        Phase 1 of ManualImport Migration - adds API functions without changing existing flow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$ScanPath,
        
        [Parameter()]
        [bool]$FilterExistingFiles = $true
    )
    
    $appConfig = $script:ArrConfig[$AppType]
    $label = $appConfig.Label
    
    # Build base URL
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $baseUrl = $urlInfo.Url
    
    # URL-encode the path for query string
    $encodedPath = [System.Uri]::EscapeDataString($ScanPath)
    $filterParam = if ($FilterExistingFiles) { 'true' } else { 'false' }
    $uri = "$baseUrl/api/v3/manualimport?folder=$encodedPath&filterExistingFiles=$filterParam"
    
    Write-SAVerbose -Text "$label ManualImport scan: $ScanPath"
    Write-SAVerbose -Text "Request: GET $uri"
    
    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    
    # Add Host header for reverse proxy compatibility
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }
    
    # Use longer timeout for scan - folder scanning can take time for large directories
    $timeout = if ($Config.scanTimeoutSeconds) { $Config.scanTimeoutSeconds } else { 60 }
    
    $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -TimeoutSeconds $timeout
    
    if (-not $result.Success) {
        Write-SAVerbose -Text "$label ManualImport scan failed: $($result.ErrorMessage)"
        return [PSCustomObject]@{
            Success      = $false
            ScanResults  = @()
            ErrorMessage = $result.ErrorMessage
        }
    }
    
    # The API returns an array of file objects
    $scanResults = @()
    if ($null -ne $result.Data) {
        # Ensure we always have an array
        if ($result.Data -is [array]) {
            $scanResults = $result.Data
        } else {
            $scanResults = @($result.Data)
        }
    }
    
    # Verbose logging of scan results
    $totalFiles = $scanResults.Count
    $importableCount = ($scanResults | Where-Object { $null -eq $_.rejections -or $_.rejections.Count -eq 0 }).Count
    $rejectedCount = $totalFiles - $importableCount
    
    Write-SAVerbose -Text "$label ManualImport scan complete: $totalFiles files found"
    Write-SAVerbose -Text "  Importable: $importableCount, Rejected: $rejectedCount"
    
    # Log rejection details at verbose level
    foreach ($file in $scanResults) {
        if ($null -ne $file.rejections -and $file.rejections.Count -gt 0) {
            $fileName = Split-Path -Path $file.path -Leaf
            foreach ($rejection in $file.rejections) {
                $rejectionType = if ($rejection.type) { $rejection.type } else { 'unknown' }
                Write-SAVerbose -Text "  Rejection [$rejectionType]: $fileName - $($rejection.reason)"
            }
        }
    }
    
    # Log metadata availability for first file (helps debug)
    if ($scanResults.Count -gt 0) {
        $firstFile = $scanResults[0]
        $mediaObject = if ($AppType -eq 'Radarr') { $firstFile.movie } else { $firstFile.series }
        if ($null -ne $mediaObject) {
            $metaTitle = "$($mediaObject.title) ($($mediaObject.year))"
            $metaImdb = if ($mediaObject.imdbId) { " [$($mediaObject.imdbId)]" } else { '' }
            Write-SAVerbose -Text "  Metadata: $metaTitle$metaImdb"
        } else {
            Write-SAVerbose -Text "  No metadata attached to scan results"
        }
    }
    
    return [PSCustomObject]@{
        Success      = $true
        ScanResults  = $scanResults
        ErrorMessage = $null
    }
}

function Invoke-SAArrManualImportExecute {
    <#
    .SYNOPSIS
        Executes a ManualImport command for specific files in a *arr application.
    .DESCRIPTION
        Uses POST /api/v3/command with the ManualImport command to import specific files
        that were identified by a prior scan. This is the second step of the two-step
        ManualImport flow (Scan → Filter → Import).
        
        ManualImport provides fine-grained control over which files to import, unlike
        automatic scan commands. This enables pre-flight rejection detection and
        partial import handling.
        
        Works with both Radarr and Sonarr using their shared API structure.
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER Config
        Application configuration hashtable (host, port, apiKey, etc.).
    .PARAMETER Files
        Array of file objects from Invoke-SAArrManualImportScan. Each file must have:
        - path: Full path to the file
        - movieId (Radarr) or seriesId (Sonarr): ID of the matched media
        - quality: Quality object from scan
        - languages: Languages array from scan (Sonarr)
        - episodes: Episodes array (Sonarr only)
    .PARAMETER ImportMode
        How to handle the source files after import: 'move' or 'copy' (default: 'move').
    .PARAMETER DownloadId
        Optional download client ID (torrent hash). When provided, included in the command body
        so *arr can associate the import with the correct download client history entry.
    .OUTPUTS
        PSCustomObject with:
        - Success: Boolean indicating if the import completed successfully
        - Message: Status message
        - Duration: Time taken in seconds
        - CommandId: The command ID for reference
    .EXAMPLE
        $scan = Invoke-SAArrManualImportScan -AppType 'Radarr' -Config $config -ScanPath $path
        $importable = $scan.ScanResults | Where-Object { $_.rejections.Count -eq 0 }
        if ($importable.Count -gt 0) {
            $result = Invoke-SAArrManualImportExecute -AppType 'Radarr' -Config $config -Files $importable
        }
    .NOTES
        Phase 1 of ManualImport Migration - adds API functions without changing existing flow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [array]$Files,
        
        [Parameter()]
        [ValidateSet('move', 'copy')]
        [string]$ImportMode = 'move',

        [Parameter()]
        [string]$DownloadId
    )

    $appConfig = $script:ArrConfig[$AppType]
    $label = $appConfig.Label

    if ($Files.Count -eq 0) {
        Write-SAVerbose -Text "$label ManualImport: No files to import"
        return [PSCustomObject]@{
            Success   = $false
            Message   = 'No files to import'
            Duration  = 0
            CommandId = $null
        }
    }
    
    Write-SAVerbose -Text "$label ManualImport: Preparing $($Files.Count) files for import (mode: $ImportMode)"
    
    # Build the files array for the API request
    # Structure differs slightly between Radarr and Sonarr
    $importFiles = @()
    
    foreach ($file in $Files) {
        $importFile = @{
            path    = $file.path
            quality = $file.quality
        }
        
        if ($AppType -eq 'Radarr') {
            # Radarr uses movieId
            if ($null -ne $file.movie -and $file.movie.id) {
                $importFile.movieId = $file.movie.id
            } elseif ($file.movieId) {
                $importFile.movieId = $file.movieId
            }
            
            # Languages (if present)
            if ($null -ne $file.languages) {
                $importFile.languages = $file.languages
            }
        } else {
            # Sonarr uses seriesId and episodes
            if ($null -ne $file.series -and $file.series.id) {
                $importFile.seriesId = $file.series.id
            } elseif ($file.seriesId) {
                $importFile.seriesId = $file.seriesId
            }
            
            # Episode IDs are required for Sonarr (API expects episodeIds, not episodes)
            if ($null -ne $file.episodes -and @($file.episodes).Count -gt 0) {
                $importFile.episodeIds = @($file.episodes | ForEach-Object { $_.id })
            }

            # Languages (if present)
            if ($null -ne $file.languages) {
                $importFile.languages = $file.languages
            }

            # Season/Episode info (if present)
            if ($null -ne $file.seasonNumber) {
                $importFile.seasonNumber = $file.seasonNumber
            }

            # Skip files without required Sonarr fields
            if (-not $importFile.seriesId -or -not $importFile.episodeIds) {
                $fileName = Split-Path -Path $file.path -Leaf
                Write-SAVerbose -Text "  Skipping $fileName (missing seriesId or episodeIds)"
                continue
            }
        }

        # Folder name for better matching (optional but helpful)
        if ($null -ne $file.folderName) {
            $importFile.folderName = $file.folderName
        }

        # Release group for correct CF scoring and rename (from scan result)
        if (-not [string]::IsNullOrWhiteSpace($file.releaseGroup)) {
            $importFile.releaseGroup = $file.releaseGroup
        }

        # Indexer flags (freeleech, etc.) for CF matching
        if ($null -ne $file.indexerFlags) {
            $importFile.indexerFlags = $file.indexerFlags
        }

        # Release type (single episode, season pack, etc.)
        if ($null -ne $file.releaseType) {
            $importFile.releaseType = $file.releaseType
        }

        $importFiles += $importFile
        
        $fileName = Split-Path -Path $file.path -Leaf
        Write-SAVerbose -Text "  File: $fileName"
    }
    
    # Build command body
    $commandBody = @{
        name       = 'ManualImport'
        files      = $importFiles
        importMode = $ImportMode
    }
    if (-not [string]::IsNullOrWhiteSpace($DownloadId)) {
        $commandBody.downloadId = $DownloadId
    }
    
    Write-SAVerbose -Text "$label ManualImport: Sending command..."
    
    # Send command using existing helper
    $commandResult = Invoke-SAImporterCommand -Config $Config -Body $commandBody
    
    if (-not $commandResult.Success) {
        Write-SAVerbose -Text "$label ManualImport command failed: $($commandResult.Message)"
        return [PSCustomObject]@{
            Success   = $false
            Message   = $commandResult.Message
            Duration  = 0
            CommandId = $null
        }
    }
    
    Write-SAVerbose -Text "$label ManualImport command ID: $($commandResult.CommandId)"
    
    # Poll for completion using existing helper
    $timeout = if ($Config.timeoutMinutes) { $Config.timeoutMinutes } else { $script:SAConstants.DefaultImportTimeoutMinutes }
    $pollResult = Wait-SAImporterCommand -Config $Config -CommandId $commandResult.CommandId -TimeoutMinutes $timeout
    
    return [PSCustomObject]@{
        Success   = $pollResult.Success
        Message   = $pollResult.Message
        Duration  = $pollResult.Duration
        CommandId = $commandResult.CommandId
        Status    = $pollResult.Status
        Result    = $pollResult.Result
    }
}

#endregion

#region Radarr Backward-Compatibility Wrappers

function Invoke-SARadarrImport {
    <#
    .SYNOPSIS
        Triggers Radarr to scan and import a downloaded movie using ManualImport API.
    .DESCRIPTION
        Convenience wrapper around Invoke-SAArrImport for Radarr.
        Uses ManualImport API for pre-flight validation and rich metadata extraction.
        
        The ManualImport flow provides:
        - Pre-flight rejection detection (quality exists, sample files, parse errors)
        - Rich metadata for email enrichment (title, year, ratings, poster URL)
        - Clear skip vs error distinction
    .PARAMETER Config
        Radarr configuration hashtable (host, port, apiKey, importMode, etc.).
    .PARAMETER StagingPath
        Path to the staging folder containing the movie.
    .PARAMETER StagingRoot
        Root staging folder for relative path calculation.
    .PARAMETER DownloadId
        Optional download client ID (torrent hash) for download history association.
    .OUTPUTS
        PSCustomObject with:
        - Success: Boolean (skips are considered success)
        - Message: Status message
        - Duration: Time taken in seconds
        - ImportedFiles: Array of imported file paths
        - SkippedFiles: Array of rejected file paths
        - SkippedCount: Count of skipped files
        - ArrMetadata: Normalized metadata for email enrichment
        - Skipped: $true if all files were skipped
        - QualityRejected: $true if rejection was due to quality
        - ErrorType: Categorized error type
    .EXAMPLE
        $result = Invoke-SARadarrImport -Config $config.importers.radarr -StagingPath "C:\Staging\Movie\Film" -StagingRoot "C:\Staging"
        if ($result.ArrMetadata) {
            # Use $result.ArrMetadata.Title, .Year, .ImdbRating for email
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        
        [Parameter()]
        [string]$StagingRoot,
        
        [Parameter()]
        [string]$DownloadId
    )
    
    return Invoke-SAArrImport -AppType 'Radarr' -Config $Config -StagingPath $StagingPath -StagingRoot $StagingRoot -DownloadId $DownloadId
}

function Test-SARadarrConnection {
    <#
    .SYNOPSIS
        Tests connection to Radarr API.
    .DESCRIPTION
        Convenience wrapper around Test-SAArrConnection for Radarr.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    return Test-SAArrConnection -AppType 'Radarr' -Config $Config
}

function Get-SARadarrRecentErrors {
    <#
    .SYNOPSIS
        Fetches recent error logs from Radarr that match a staging path.
    .DESCRIPTION
        Convenience wrapper around Get-SAArrRecentErrors for Radarr.
    .PARAMETER Config
        Radarr configuration hashtable.
    .PARAMETER StagingPath
        Path to filter log messages by.
    .PARAMETER MaxMinutesAgo
        Only look at logs from the last N minutes (default: 5).
    .OUTPUTS
        Array of error message strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        
        [Parameter()]
        [int]$MaxMinutesAgo = 5
    )
    
    return Get-SAArrRecentErrors -AppType 'Radarr' -Config $Config -StagingPath $StagingPath -MaxMinutesAgo $MaxMinutesAgo
}

function Invoke-SARadarrManualImportScan {
    <#
    .SYNOPSIS
        Scans a folder using Radarr's ManualImport API.
    .DESCRIPTION
        Convenience wrapper around Invoke-SAArrManualImportScan for Radarr.
        Returns detailed file information including movie metadata, quality, and rejections.
    .PARAMETER Config
        Radarr configuration hashtable.
    .PARAMETER ScanPath
        Path to scan for importable files.
    .PARAMETER FilterExistingFiles
        Whether to filter out files that already exist in the library (default: true).
    .OUTPUTS
        PSCustomObject with Success, ScanResults array, and ErrorMessage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$ScanPath,
        
        [Parameter()]
        [bool]$FilterExistingFiles = $true
    )
    
    return Invoke-SAArrManualImportScan -AppType 'Radarr' -Config $Config -ScanPath $ScanPath -FilterExistingFiles $FilterExistingFiles
}

function Invoke-SARadarrManualImportExecute {
    <#
    .SYNOPSIS
        Executes a ManualImport command in Radarr for specific files.
    .DESCRIPTION
        Convenience wrapper around Invoke-SAArrManualImportExecute for Radarr.
        Imports files identified by a prior scan.
    .PARAMETER Config
        Radarr configuration hashtable.
    .PARAMETER Files
        Array of file objects from Invoke-SARadarrManualImportScan.
    .PARAMETER ImportMode
        How to handle source files: 'move' or 'copy' (default: 'move').
    .OUTPUTS
        PSCustomObject with Success, Message, Duration, and CommandId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [array]$Files,
        
        [Parameter()]
        [ValidateSet('move', 'copy')]
        [string]$ImportMode = 'move'
    )
    
    return Invoke-SAArrManualImportExecute -AppType 'Radarr' -Config $Config -Files $Files -ImportMode $ImportMode
}

#endregion

#region Sonarr Backward-Compatibility Wrappers

function Invoke-SASonarrImport {
    <#
    .SYNOPSIS
        Triggers Sonarr to scan and import downloaded TV episodes using ManualImport API.
    .DESCRIPTION
        Convenience wrapper around Invoke-SAArrImport for Sonarr.
        Uses ManualImport API for pre-flight validation and rich metadata extraction.
        
        The ManualImport flow provides:
        - Pre-flight rejection detection (quality exists, sample files, parse errors)
        - Rich metadata for email enrichment (series title, year, ratings, poster URL)
        - Clear skip vs error distinction
        - Support for partial imports (some episodes rejected, others imported)
    .PARAMETER Config
        Sonarr configuration hashtable (host, port, apiKey, importMode, etc.).
    .PARAMETER StagingPath
        Path to the staging folder containing the episode(s).
    .PARAMETER StagingRoot
        Root staging folder for relative path calculation.
    .PARAMETER DownloadId
        Optional download client ID (torrent hash) for download history association.
    .OUTPUTS
        PSCustomObject with:
        - Success: Boolean (skips are considered success)
        - Message: Status message
        - Duration: Time taken in seconds
        - ImportedFiles: Array of imported file paths
        - SkippedFiles: Array of rejected file paths
        - SkippedCount: Count of skipped files
        - ArrMetadata: Normalized metadata for email enrichment
        - Skipped: $true if all files were skipped
        - QualityRejected: $true if rejection was due to quality
        - ErrorType: Categorized error type
    .EXAMPLE
        $result = Invoke-SASonarrImport -Config $config.importers.sonarr -StagingPath "C:\Staging\TV\Show" -StagingRoot "C:\Staging"
        if ($result.ArrMetadata) {
            # Use $result.ArrMetadata.Title, .Year, .ImdbRating for email
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        
        [Parameter()]
        [string]$StagingRoot,
        
        [Parameter()]
        [string]$DownloadId
    )
    
    return Invoke-SAArrImport -AppType 'Sonarr' -Config $Config -StagingPath $StagingPath -StagingRoot $StagingRoot -DownloadId $DownloadId
}

function Test-SASonarrConnection {
    <#
    .SYNOPSIS
        Tests connection to Sonarr API.
    .DESCRIPTION
        Convenience wrapper around Test-SAArrConnection for Sonarr.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    return Test-SAArrConnection -AppType 'Sonarr' -Config $Config
}

function Get-SASonarrRecentErrors {
    <#
    .SYNOPSIS
        Fetches recent error logs from Sonarr that match a staging path.
    .DESCRIPTION
        Convenience wrapper around Get-SAArrRecentErrors for Sonarr.
    .PARAMETER Config
        Sonarr configuration hashtable.
    .PARAMETER StagingPath
        Path to filter log messages by.
    .PARAMETER MaxMinutesAgo
        Only look at logs from the last N minutes (default: 5).
    .OUTPUTS
        Array of error message strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        
        [Parameter()]
        [int]$MaxMinutesAgo = 5
    )
    
    return Get-SAArrRecentErrors -AppType 'Sonarr' -Config $Config -StagingPath $StagingPath -MaxMinutesAgo $MaxMinutesAgo
}

function Invoke-SASonarrManualImportScan {
    <#
    .SYNOPSIS
        Scans a folder using Sonarr's ManualImport API.
    .DESCRIPTION
        Convenience wrapper around Invoke-SAArrManualImportScan for Sonarr.
        Returns detailed file information including series/episode metadata, quality, and rejections.
    .PARAMETER Config
        Sonarr configuration hashtable.
    .PARAMETER ScanPath
        Path to scan for importable files.
    .PARAMETER FilterExistingFiles
        Whether to filter out files that already exist in the library (default: true).
    .OUTPUTS
        PSCustomObject with Success, ScanResults array, and ErrorMessage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$ScanPath,
        
        [Parameter()]
        [bool]$FilterExistingFiles = $true
    )
    
    return Invoke-SAArrManualImportScan -AppType 'Sonarr' -Config $Config -ScanPath $ScanPath -FilterExistingFiles $FilterExistingFiles
}

function Invoke-SASonarrManualImportExecute {
    <#
    .SYNOPSIS
        Executes a ManualImport command in Sonarr for specific files.
    .DESCRIPTION
        Convenience wrapper around Invoke-SAArrManualImportExecute for Sonarr.
        Imports files identified by a prior scan.
    .PARAMETER Config
        Sonarr configuration hashtable.
    .PARAMETER Files
        Array of file objects from Invoke-SASonarrManualImportScan.
    .PARAMETER ImportMode
        How to handle source files: 'move' or 'copy' (default: 'move').
    .OUTPUTS
        PSCustomObject with Success, Message, Duration, and CommandId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [array]$Files,
        
        [Parameter()]
        [ValidateSet('move', 'copy')]
        [string]$ImportMode = 'move'
    )
    
    return Invoke-SAArrManualImportExecute -AppType 'Sonarr' -Config $Config -Files $Files -ImportMode $ImportMode
}

#endregion

#region Internal Helper Functions

function Invoke-SAImporterCommand {
    <#
    .SYNOPSIS
        Sends a command to Radarr/Sonarr API.
    .DESCRIPTION
        Posts to /api/v3/command endpoint and returns command ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Body
    )
    
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $uri = "$($urlInfo.Url)/api/v3/command"
    
    $headers = @{
        'X-Api-Key'    = $Config.apiKey
        'Content-Type' = 'application/json'
        'Accept'       = 'application/json'
    }
    
    # Add Host header for reverse proxy compatibility
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }
    
    $result = Invoke-SAWebRequest -Uri $uri -Method POST -Headers $headers -Body $Body
    
    if ($result.Success -and $result.Data.id) {
        return [PSCustomObject]@{
            Success   = $true
            CommandId = $result.Data.id
            Status    = $result.Data.status
            Message   = $null
        }
    }
    
    return [PSCustomObject]@{
        Success   = $false
        CommandId = $null
        Status    = $null
        Message   = $result.ErrorMessage
    }
}

function Wait-SAImporterCommand {
    <#
    .SYNOPSIS
        Polls for command completion in Radarr/Sonarr.
    .DESCRIPTION
        Polls /api/v3/command/{id} until status is 'completed' or 'failed'.
        Uses Write-SAPollingStatus for consistent heartbeat pattern:
        - Shows immediately on state change
        - Shows heartbeat every ~15 seconds if state unchanged
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [int]$CommandId,
        
        [Parameter()]
        [int]$TimeoutMinutes = 10,
        
        [Parameter()]
        [int]$PollIntervalSeconds = 5
    )
    
    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $uri = "$($urlInfo.Url)/api/v3/command/$CommandId"
    
    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    
    # Add Host header for reverse proxy compatibility
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddMinutes($TimeoutMinutes)
    
    while ((Get-Date) -lt $timeoutTime) {
        Start-Sleep -Seconds $PollIntervalSeconds
        
        $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers
        
        if (-not $result.Success) {
            continue
        }
        
        $status = $result.Data.status
        $commandResult = $result.Data.result  # 'successful', 'unsuccessful', or 'unknown'
        $exception = $result.Data.exception
        $completionMessage = $result.Data.body.completionMessage
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        
        Write-SAVerbose -Text "Attempt: status=$status, result=$commandResult"
        
        switch ($status) {
            'completed' {
                # Check the result field - status can be 'completed' but result 'unsuccessful'
                if ($commandResult -eq 'unsuccessful') {
                    # Build error message from available fields
                    $errorMsg = 'Command completed but no files imported'
                    if (-not [string]::IsNullOrWhiteSpace($exception)) {
                        $errorMsg = $exception
                    } elseif (-not [string]::IsNullOrWhiteSpace($completionMessage)) {
                        $errorMsg = $completionMessage
                    }
                    return [PSCustomObject]@{
                        Success  = $false
                        Status   = 'completed'
                        Result   = 'unsuccessful'
                        Message  = $errorMsg
                        Duration = $elapsed
                    }
                }
                # Check for exception even on successful result
                if (-not [string]::IsNullOrWhiteSpace($exception)) {
                    Write-SAVerbose -Text "Command completed with exception: $exception"
                }
                return [PSCustomObject]@{
                    Success  = $true
                    Status   = 'completed'
                    Result   = 'successful'
                    Message  = 'Command completed successfully'
                    Duration = $elapsed
                }
            }
            'failed' {
                $errorMsg = if (-not [string]::IsNullOrWhiteSpace($exception)) { 
                    $exception 
                } elseif ($result.Data.message) { 
                    $result.Data.message 
                } else { 
                    'Command failed' 
                }
                return [PSCustomObject]@{
                    Success  = $false
                    Status   = 'failed'
                    Result   = $commandResult
                    Message  = $errorMsg
                    Duration = $elapsed
                }
            }
            { $_ -in @('aborted', 'cancelled', 'orphaned') } {
                # Terminal failure states - don't keep polling
                $errorMsg = if (-not [string]::IsNullOrWhiteSpace($exception)) {
                    $exception
                } else {
                    "Command $status"
                }
                return [PSCustomObject]@{
                    Success  = $false
                    Status   = $status
                    Result   = $commandResult
                    Message  = $errorMsg
                    Duration = $elapsed
                }
            }
            default {
                # Still running (queued, started, etc.)
                # Use centralized polling status with rate limiting
                # Defensive: skip polling status output if status is empty
                if (-not [string]::IsNullOrWhiteSpace($status)) {
                    # Normalize "started" to "Processing" for consistency with Medusa
                    $displayStatus = if ($status -eq 'started') { 
                        'Processing' 
                    } else { 
                        (Get-Culture).TextInfo.ToTitleCase($status) 
                    }
                    Write-SAPollingStatus -Status $displayStatus -ElapsedSeconds $elapsed
                }
            }
        }
    }
    
    # Timeout
    $duration = [int]((Get-Date) - $startTime).TotalSeconds
    return [PSCustomObject]@{
        Success  = $false
        Status   = 'timeout'
        Message  = "Command timed out after $TimeoutMinutes minutes"
        Duration = $duration
    }
}

#endregion
