#Requires -Version 5.1
<#
.SYNOPSIS
    Import result parsing functions for Stagearr
.DESCRIPTION
    Parses output from media importers (Radarr, Sonarr, Medusa) into structured
    result objects. Separates parsing logic from business/output logic.
    
    Key functions:
    - ConvertFrom-SAArrErrors: Categorize *arr error log messages
    - ConvertFrom-SAMedusaOutput: Parse Medusa postprocess output
    - Get-SAImportHint: Generate actionable troubleshooting hints
    - Get-SAImportErrorMessage: Build user-friendly error messages
#>

#region Arr Error Patterns

# Error pattern definitions for *arr applications (Radarr/Sonarr)
# Based on arr_downloaded_scan_log_signatures.csv
$script:ArrErrorPatterns = @{
    # Skip patterns (warnings, not errors)
    exists  = 'already on disk|already exists|file exists'
    quality = 'quality cutoff|existing file meets|same quality|lower quality|not an upgrade'
    sample  = 'rejected.*Sample|Sample.*rejected'
    
    # Error patterns
    pathFormat    = 'is not a valid Windows path'
    pathNotFound  = 'path does not exist|not accessible by'
    parse         = 'Unable to parse|parse movie info|parse file'
    permission    = 'Access to the path.*is denied|Access.*denied'
    space         = 'Not enough free space.*to import|free space'
    transfer      = 'File move incomplete|data loss may have occurred'
}

#endregion

#region Medusa Output Patterns

# Video extensions that Medusa can process (from centralized constants)
# Used in patterns that need to anchor on file extension before colon (to avoid matching drive letter C:)
$script:VideoExtensions = $script:SAConstants.VideoExtensionsPattern

# Output patterns for Medusa postprocess parsing
# Based on medusa/process_tv.py and medusa/post_processor.py
$script:MedusaPatterns = @{
    # Success indicators
    succeeded     = 'Processing succeeded for'
    movedVideo    = "Moving file from [^\n]+\.($script:VideoExtensions) to"
    
    # Failure indicators
    failed        = 'Processing failed for'
    aborted       = "Processing aborted for .+\.($script:VideoExtensions):\s*(\S.*)$"
    
    # Skip indicators
    qualityEqual  = 'File exists.+quality is equal|Marking it unsafe to replace.+quality'
    sameSize      = 'same size'
    fileExists    = 'File exists'
    alreadyDone   = 'already been processed|Skipping already processed'
    
    # Special states
    postponed     = 'Processing postponed for|Postponing the post-processing'
    
    # Error patterns (from success=false responses)
    # NOTE: Must anchor on video extension to avoid matching drive letter C: in Windows paths
    failedReason  = "Processing failed for .+\.($script:VideoExtensions):\s*(.+)$"
    fileOperation = 'Unable to (copy|link|reflink) file .+?: (.+)'
    permissionErr = 'Cannot change permissions for .+?\. Error: (.+)'
    unpackError   = 'Failed unpacking archive .+?: (.+)'
    parseRelease  = 'unable to find a valid release name'
    parseInfo     = 'Not enough information to parse release name'
    notFound      = 'Unable to find episode'
}

#endregion

#region Medusa Per-File Detail Extraction

function Get-SAMedusaFileDetails {
    <#
    .SYNOPSIS
        Extracts per-file details from Medusa output for episode-level reporting.
    .DESCRIPTION
        Parses Medusa postprocess output to extract individual file results with
        episode information. Used to provide detailed episode-level feedback in
        console and email outputs.
        
        This is a pure function that extracts details from output text.
        
        IMPORTANT: Medusa's "Processing succeeded" does NOT mean a file was imported.
        It means the workflow completed without errors. A file is only truly imported
        if we see "Moving file from X to Y" for that file. "Processing succeeded"
        without a corresponding move indicates a skip (e.g., same size, quality exists).
    .PARAMETER Output
        Output array from Medusa postprocess API response.
    .OUTPUTS
        PSCustomObject with ImportedFiles, SkippedFiles, AbortedFiles arrays.
        Each array contains objects with: Filename, Season, Episode, Reason (for skipped/aborted).
    .EXAMPLE
        $details = Get-SAMedusaFileDetails -Output $pollResult.Data.output
        $details.ImportedFiles  # @( @{Filename='...'; Season=2; Episode=8} )
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Output
    )
    
    # Initialize result
    $result = [PSCustomObject]@{
        ImportedFiles = @()
        SkippedFiles  = @()
        AbortedFiles  = @()
    }
    
    if ($null -eq $Output -or $Output.Count -eq 0) {
        return $result
    }
    
    # Convert output to text for pattern matching skip reasons
    $outputText = if ($Output -is [array]) { $Output -join "`n" } else { [string]$Output }
    
    # FIRST PASS: Build set of files that were actually moved (authoritative for imports)
    # "Moving file from X to Y" is the only reliable indicator that a file was imported
    $movedFiles = @{}
    foreach ($line in $Output) {
        if ($line -match 'Moving file from .+[\\\/]([^\\\/]+\.(?:mkv|mp4|avi|m4v|wmv|ts)) to') {
            $filename = $Matches[1]
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filename)
            
            # Only add if not already seen (avoid duplicates from subtitle moves)
            if (-not $movedFiles.ContainsKey($baseName)) {
                $movedFiles[$baseName] = $filename
            }
        }
    }
    
    # Add actually moved files to ImportedFiles
    foreach ($baseName in $movedFiles.Keys) {
        $filename = $movedFiles[$baseName]
        $fileDetail = Get-SAFileEpisodeInfo -Filename $filename
        if ($null -ne $fileDetail) {
            $result.ImportedFiles += $fileDetail
        }
    }
    
    # SECOND PASS: Process explicit failed/aborted lines
    $processedSucceeded = @{}  # Track files with "Processing succeeded" for later
    foreach ($line in $Output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        
        # Track "Processing succeeded" files for potential skip detection
        if ($line -match 'Processing succeeded for .+[\\\/]([^\\\/]+\.(?:mkv|mp4|avi|m4v|wmv|ts))') {
            $filename = $Matches[1]
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filename)
            $processedSucceeded[$baseName] = $filename
            continue
        }
        
        # Pattern: Processing failed for ...\filename.mkv: reason
        # These are quality skips, not real failures
        if ($line -match 'Processing failed for .+[\\\/]([^\\\/]+\.(?:mkv|mp4|avi|m4v|wmv|ts)):\s*(.+)$') {
            $filename = $Matches[1]
            $reason = $Matches[2].Trim()
            
            # Simplify the reason for display
            $displayReason = Get-SAMedusaSimplifiedReason -Reason $reason
            
            $fileDetail = Get-SAFileEpisodeInfo -Filename $filename -Reason $displayReason
            if ($null -ne $fileDetail) {
                $result.SkippedFiles += $fileDetail
            }
            continue
        }
        
        # Pattern: Processing aborted for ...\filename.mkv: reason
        # Handle both non-empty reason and empty-reason aborts
        if ($line -match 'Processing aborted for .+[\\\/]([^\\\/]+\.(?:mkv|mp4|avi|m4v|wmv|ts)):\s*(\S.*)$') {
            $filename = $Matches[1]
            $reason = $Matches[2].Trim()
            
            # Simplify the reason for display
            $displayReason = Get-SAMedusaSimplifiedReason -Reason $reason
            
            $fileDetail = Get-SAFileEpisodeInfo -Filename $filename -Reason $displayReason
            if ($null -ne $fileDetail) {
                $result.AbortedFiles += $fileDetail
            }
            continue
        }
        
        # Pattern: Processing aborted for ...\filename.mkv:  (empty reason)
        # Medusa sometimes outputs the reason on a preceding line, then an empty-reason abort line
        # Example: "File exists and the new file has the same size, aborting" then "Processing aborted for ...mkv: "
        if ($line -match 'Processing aborted for .+[\\\/]([^\\\/]+\.(?:mkv|mp4|avi|m4v|wmv|ts)):\s*$') {
            $filename = $Matches[1]
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filename)
            
            # Skip if already tracked (file with reason matched the pattern above)
            $alreadyTracked = $result.AbortedFiles | Where-Object { 
                [System.IO.Path]::GetFileNameWithoutExtension($_.Filename) -eq $baseName 
            }
            if ($alreadyTracked) {
                continue
            }
            
            # Look for context in output to determine the actual reason
            # The reason is typically on a preceding line
            $inferredReason = Get-SAMedusaSameSizeSkipReason -OutputText $outputText -Filename $filename
            
            $fileDetail = Get-SAFileEpisodeInfo -Filename $filename -Reason $inferredReason
            if ($null -ne $fileDetail) {
                # "Same size" is really a skip, not an abort
                if ($inferredReason -eq 'Same size' -or $inferredReason -eq 'Quality exists' -or $inferredReason -eq 'File exists') {
                    $result.SkippedFiles += $fileDetail
                }
                else {
                    $result.AbortedFiles += $fileDetail
                }
            }
            continue
        }
    }
    
    # THIRD PASS: Handle "Processing succeeded" without actual move
    # These are skips (same size, quality exists, etc.) that Medusa reports as "succeeded"
    foreach ($baseName in $processedSucceeded.Keys) {
        # Skip if file was actually moved (already in ImportedFiles)
        if ($movedFiles.ContainsKey($baseName)) {
            continue
        }
        
        # Skip if already in SkippedFiles or AbortedFiles (explicit failed/aborted line)
        $alreadyTracked = ($result.SkippedFiles | Where-Object { 
            [System.IO.Path]::GetFileNameWithoutExtension($_.Filename) -eq $baseName 
        }) -or ($result.AbortedFiles | Where-Object { 
            [System.IO.Path]::GetFileNameWithoutExtension($_.Filename) -eq $baseName 
        })
        if ($alreadyTracked) {
            continue
        }
        
        # This file had "Processing succeeded" but no move - it's a skip
        # Determine the skip reason from output context
        $filename = $processedSucceeded[$baseName]
        $skipReason = Get-SAMedusaSameSizeSkipReason -OutputText $outputText -Filename $filename
        
        $fileDetail = Get-SAFileEpisodeInfo -Filename $filename -Reason $skipReason
        if ($null -ne $fileDetail) {
            $result.SkippedFiles += $fileDetail
        }
    }
    
    return $result
}

function Get-SAMedusaSameSizeSkipReason {
    <#
    .SYNOPSIS
        Extracts skip reason for files that had "Processing succeeded" but no move.
    .DESCRIPTION
        Internal helper to determine why Medusa reported success but didn't move the file.
        Common reasons: same size (aborting post-processing), quality exists.
    .PARAMETER OutputText
        Full Medusa output text for context matching.
    .PARAMETER Filename
        The filename to find context for.
    .OUTPUTS
        Simplified skip reason string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputText,
        
        [Parameter(Mandatory = $true)]
        [string]$Filename
    )
    
    # Look for same-size abort pattern (most common case for "succeeded" without move)
    # Pattern: "File exists and the new file has the same size, aborting post-processing"
    # This appears before "Processing succeeded" when file is identical
    if ($OutputText -match 'same size.*aborting|aborting post-processing') {
        return 'Same size'
    }
    
    # Look for quality-related patterns
    if ($OutputText -match 'quality is equal|Marking it unsafe to replace.*quality') {
        return 'Quality exists'
    }
    
    # Look for file exists patterns
    if ($OutputText -match 'File exists') {
        return 'File exists'
    }
    
    # Default: unknown skip reason
    return 'Already exists'
}

function Get-SAMedusaSimplifiedReason {
    <#
    .SYNOPSIS
        Simplifies verbose Medusa reason text into display-friendly message.
    .DESCRIPTION
        Internal helper that converts long Medusa error messages into
        concise, user-friendly text for console and email output.
    .PARAMETER Reason
        The raw reason text from Medusa output.
    .OUTPUTS
        Simplified reason string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )
    
    # Quality/exists skips
    if ($Reason -match 'File exists.*quality is equal|Marking it unsafe to replace.*quality|New quality is equal') {
        return 'Quality exists'
    }
    if ($Reason -match 'same size') {
        return 'Same size'
    }
    if ($Reason -match 'File exists') {
        return 'File exists'
    }
    if ($Reason -match 'already been processed|Skipping already processed') {
        return 'Already processed'
    }
    
    # Archived status
    if ($Reason -match 'status of Archived') {
        return 'Archived'
    }
    
    # Postponed
    if ($Reason -match 'Postponing|postponed') {
        return 'Postponed'
    }
    
    # Default: return truncated original if too long
    if ($Reason.Length -gt 50) {
        return $Reason.Substring(0, 47) + '...'
    }
    
    return $Reason
}

#endregion

#region Arr Error Parsing

function ConvertFrom-SAArrErrors {
    <#
    .SYNOPSIS
        Categorizes *arr error log messages into structured result.
    .DESCRIPTION
        Analyzes error messages from Radarr/Sonarr log API to determine
        the type of failure or skip condition. Returns a structured object
        with error categorization and counts.
    .PARAMETER ErrorMessages
        Array of error message strings from Get-SAArrRecentErrors.
    .OUTPUTS
        PSCustomObject with properties:
        - ErrorType: Primary error category (exists, quality, sample, path-format, etc.)
        - IsSkipped: True if all files were skipped (not a failure)
        - IsQualityRejected: True if rejected due to quality
        - SkippedCount: Number of files skipped
        - ErrorCounts: Hashtable of error counts by category
    .EXAMPLE
        $errors = Get-SAArrRecentErrors -AppType 'Radarr' -Config $config -StagingPath $path
        $parsed = ConvertFrom-SAArrErrors -ErrorMessages $errors
        if ($parsed.IsSkipped) { Write-Host "Files skipped: $($parsed.SkippedCount)" }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ErrorMessages
    )
    
    # Initialize result
    $result = [PSCustomObject]@{
        ErrorType         = $null
        IsSkipped         = $false
        IsQualityRejected = $false
        SkippedCount      = 0
        ErrorCounts       = @{}
    }
    
    if ($ErrorMessages.Count -eq 0) {
        $result.ErrorType = 'unknown'
        return $result
    }
    
    # Categorize each error message
    $counts = @{
        exists      = 0
        quality     = 0
        sample      = 0
        pathFormat  = 0
        pathNotFound = 0
        parse       = 0
        permission  = 0
        space       = 0
        transfer    = 0
    }
    
    foreach ($msg in $ErrorMessages) {
        # Skip patterns
        if ($msg -match $script:ArrErrorPatterns.exists) { $counts.exists++ }
        if ($msg -match $script:ArrErrorPatterns.quality) { $counts.quality++ }
        if ($msg -match $script:ArrErrorPatterns.sample) { $counts.sample++ }
        
        # Error patterns
        if ($msg -match $script:ArrErrorPatterns.pathFormat) { $counts.pathFormat++ }
        if ($msg -match $script:ArrErrorPatterns.pathNotFound) { $counts.pathNotFound++ }
        if ($msg -match $script:ArrErrorPatterns.parse) { $counts.parse++ }
        if ($msg -match $script:ArrErrorPatterns.permission) { $counts.permission++ }
        if ($msg -match $script:ArrErrorPatterns.space) { $counts.space++ }
        if ($msg -match $script:ArrErrorPatterns.transfer) { $counts.transfer++ }
    }
    
    $result.ErrorCounts = $counts
    $result.SkippedCount = $counts.exists + $counts.quality + $counts.sample
    
    # Determine primary error type (priority order)
    # Skip patterns first
    if ($counts.exists -gt 0) {
        $result.IsSkipped = $true
        $result.ErrorType = 'exists'
    }
    if ($counts.quality -gt 0) {
        $result.IsQualityRejected = $true
        $result.ErrorType = 'quality'
    }
    if ($counts.sample -gt 0 -and -not $result.IsSkipped -and -not $result.IsQualityRejected) {
        $result.IsSkipped = $true
        $result.ErrorType = 'sample'
    }
    
    # Error patterns (only if not a skip)
    if (-not $result.IsSkipped -and -not $result.IsQualityRejected) {
        if ($counts.pathFormat -gt 0) { $result.ErrorType = 'path-format' }
        elseif ($counts.pathNotFound -gt 0) { $result.ErrorType = 'path-not-found' }
        elseif ($counts.permission -gt 0) { $result.ErrorType = 'permission' }
        elseif ($counts.space -gt 0) { $result.ErrorType = 'space' }
        elseif ($counts.parse -gt 0) { $result.ErrorType = 'parse' }
        elseif ($counts.transfer -gt 0) { $result.ErrorType = 'transfer' }
        else { $result.ErrorType = 'unknown' }
    }
    
    return $result
}

#endregion

#region Medusa Output Parsing

function ConvertFrom-SAMedusaOutput {
    <#
    .SYNOPSIS
        Parses Medusa postprocess output into structured result.
    .DESCRIPTION
        Analyzes the output array from Medusa's postprocess API to determine
        the actual result of the import operation. Medusa returns success=true
        even when files are skipped or aborted, so this parses the output
        to determine the real outcome.
        
        Includes per-file episode details for episode-level reporting in
        console and email outputs.
    .PARAMETER Output
        Output array from Medusa postprocess API response.
    .PARAMETER ApiSuccess
        The success field from Medusa API response (true/false/null).
    .OUTPUTS
        PSCustomObject with properties:
        - Success: True if import actually succeeded
        - Status: completed, skipped, partial, failed, mixed
        - ErrorType: Specific error category if failed
        - Message: Human-readable result message
        - ImportedCount: Number of files successfully imported
        - SkippedCount: Number of files skipped (quality/exists)
        - AbortedCount: Number of files aborted (errors)
        - TotalCount: Total files processed
        - SkipReason: Reason for skips
        - AbortReason: Reason for aborts
        - ImportedFiles: Array of imported file details (Filename, Season, Episode)
        - SkippedFiles: Array of skipped file details (Filename, Season, Episode, Reason)
        - AbortedFiles: Array of aborted file details (Filename, Season, Episode, Reason)
    .EXAMPLE
        $pollResult = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers
        $parsed = ConvertFrom-SAMedusaOutput -Output $pollResult.Data.output -ApiSuccess $pollResult.Data.success
        
        # Access episode-level details
        $parsed.ImportedFiles | ForEach-Object { "$($_.Season)x$($_.Episode)" }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Output,
        
        [Parameter()]
        [AllowNull()]
        $ApiSuccess
    )
    
    # Convert output to text for pattern matching
    $outputText = if ($Output -is [array]) { $Output -join "`n" } else { [string]$Output }
    
    # Extract per-file details first
    $fileDetails = Get-SAMedusaFileDetails -Output $Output
    
    # Initialize result with new file detail properties
    $result = [PSCustomObject]@{
        Success       = $false
        Status        = 'unknown'
        ErrorType     = $null
        Message       = ''
        ImportedCount = 0
        SkippedCount  = 0
        AbortedCount  = 0
        TotalCount    = 0
        SkipReason    = ''
        AbortReason   = ''
        ImportedFiles = $fileDetails.ImportedFiles
        SkippedFiles  = $fileDetails.SkippedFiles
        AbortedFiles  = $fileDetails.AbortedFiles
        Output        = $Output
    }
    
    # Handle API failure (success = false)
    if ($ApiSuccess -eq $false) {
        return ConvertFrom-SAMedusaFailure -OutputText $outputText -Output $Output
    }
    
    # API reports success=true, but we need to check what actually happened
    # Count individual file results
    
    # Prefer file details counts (more accurate - filters spurious empty-reason lines)
    # Fall back to regex counting if file details unavailable
    $hasFileDetails = ($fileDetails.ImportedFiles.Count + $fileDetails.SkippedFiles.Count + $fileDetails.AbortedFiles.Count) -gt 0
    
    if ($hasFileDetails) {
        # Use file detail counts (these correctly filter empty-reason abort lines)
        $succeededCount = $fileDetails.ImportedFiles.Count
        $failedCount = $fileDetails.SkippedFiles.Count
        $abortedCount = $fileDetails.AbortedFiles.Count
        
        # Extract abort reason from first aborted file
        $abortReason = ''
        if ($fileDetails.AbortedFiles.Count -gt 0) {
            $abortReason = $fileDetails.AbortedFiles[0].Reason
        }
    }
    else {
        # Fallback to regex counting
        # Success: explicit "Processing succeeded" or "Moving file from .mkv to"
        $explicitSucceeded = ([regex]::Matches($outputText, $script:MedusaPatterns.succeeded)).Count
        $movedVideoFiles = ([regex]::Matches($outputText, $script:MedusaPatterns.movedVideo)).Count
        
        # Failures
        $failedCount = ([regex]::Matches($outputText, $script:MedusaPatterns.failed)).Count
        
        # Aborted - extract count and reason
        $abortMatches = [regex]::Matches($outputText, $script:MedusaPatterns.aborted, [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $abortedCount = $abortMatches.Count
        $abortReason = ''
        if ($abortMatches.Count -gt 0) {
            $abortReason = $abortMatches[0].Groups[2].Value.Trim()
        }
        
        # Calculate succeeded count (prefer moved files as authoritative)
        $succeededCount = if ($movedVideoFiles -gt 0) { $movedVideoFiles } else { $explicitSucceeded }
    }
    
    $totalFailed = $failedCount + $abortedCount
    $totalFiles = $succeededCount + $totalFailed
    
    $result.ImportedCount = $succeededCount
    $result.AbortedCount = $abortedCount
    $result.TotalCount = $totalFiles
    $result.AbortReason = $abortReason
    
    # Determine if failed files are quality skips
    # Prefer file details reason over regex extraction
    $skipReason = ''
    if ($hasFileDetails -and $fileDetails.SkippedFiles.Count -gt 0) {
        $skipReason = $fileDetails.SkippedFiles[0].Reason
    }
    else {
        $skipReason = Get-SAMedusaSkipReason -OutputText $outputText
    }
    $isQualitySkip = ($skipReason -ne '') -or ($failedCount -gt 0 -and $hasFileDetails)
    
    if ($isQualitySkip) {
        $result.SkippedCount = $failedCount
        $result.SkipReason = $skipReason
    }
    
    # Determine outcome based on counts
    
    # Mixed: quality skips AND aborts, nothing imported
    if ($failedCount -gt 0 -and $abortedCount -gt 0 -and $isQualitySkip -and $succeededCount -eq 0) {
        $result.Status = 'mixed'
        $result.ErrorType = 'mixed'
        $errorMessage = if ($abortReason) { $abortReason } else { 'Processing aborted' }
        $result.Message = "$abortedCount aborted ($errorMessage), $failedCount skipped ($skipReason)"
        return $result
    }
    
    # All aborted (no quality skips, nothing imported)
    if ($abortedCount -gt 0 -and $succeededCount -eq 0 -and ($failedCount -eq 0 -or -not $isQualitySkip)) {
        $result.Status = 'failed'
        $result.ErrorType = 'aborted'
        $result.Message = if ($abortReason) { $abortReason } else { 'Processing aborted' }
        return $result
    }
    
    # All skipped (quality/exists reasons, no aborts)
    if ($succeededCount -eq 0 -and $failedCount -gt 0 -and $abortedCount -eq 0 -and $isQualitySkip) {
        $result.Success = $true
        $result.Status = 'skipped'
        $result.Message = $skipReason
        return $result
    }
    
    # Partial import (some succeeded, some failed/aborted)
    if ($succeededCount -gt 0 -and $totalFailed -gt 0) {
        $result.Success = $true
        $result.Status = 'partial'
        $result.Message = "Imported $succeededCount, skipped $totalFailed"
        return $result
    }
    
    # Check for special patterns (single file cases)
    $specialResult = Get-SAMedusaSpecialPattern -OutputText $outputText -Output $Output
    if ($specialResult) {
        return $specialResult
    }
    
    # Default: all succeeded
    $result.Success = $true
    $result.Status = 'completed'
    $result.Message = 'Import completed successfully'
    return $result
}

function ConvertFrom-SAMedusaFailure {
    <#
    .SYNOPSIS
        Parses Medusa output when API returns success=false.
    .DESCRIPTION
        Internal helper to extract error details from failed Medusa responses.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputText,
        
        [Parameter()]
        $Output
    )
    
    # Extract per-file details even for failures
    $fileDetails = Get-SAMedusaFileDetails -Output $Output
    
    $result = [PSCustomObject]@{
        Success       = $false
        Status        = 'failed'
        ErrorType     = 'generic'
        Message       = 'Import failed'
        ImportedFiles = $fileDetails.ImportedFiles
        SkippedFiles  = $fileDetails.SkippedFiles
        AbortedFiles  = $fileDetails.AbortedFiles
        Output        = $Output
    }
    
    # Try to extract specific error
    if ($OutputText -match $script:MedusaPatterns.failedReason) {
        $result.Message = $Matches[2].Trim()
    }
    elseif ($OutputText -match $script:MedusaPatterns.fileOperation) {
        $result.Message = "Unable to $($Matches[1]) file: $($Matches[2])"
        $result.ErrorType = 'file-operation'
    }
    elseif ($OutputText -match $script:MedusaPatterns.permissionErr) {
        $result.Message = "Permission error: $($Matches[1])"
        $result.ErrorType = 'permission'
    }
    elseif ($OutputText -match $script:MedusaPatterns.unpackError) {
        $result.Message = "Unpack failed: $($Matches[1])"
        $result.ErrorType = 'unpack'
    }
    elseif ($OutputText -match $script:MedusaPatterns.parseRelease) {
        $result.Message = 'Could not determine release name'
        $result.ErrorType = 'parse'
    }
    elseif ($OutputText -match $script:MedusaPatterns.parseInfo) {
        $result.Message = 'Could not parse show/episode from release name'
        $result.ErrorType = 'parse'
    }
    elseif ($OutputText -match $script:MedusaPatterns.notFound) {
        $result.Message = 'Episode not found in database'
        $result.ErrorType = 'not-found'
    }
    elseif ($Output -is [array] -and $Output.Count -gt 0) {
        # Fallback: use last line
        $result.Message = $Output[-1]
    }
    
    return $result
}

function Get-SAMedusaSkipReason {
    <#
    .SYNOPSIS
        Extracts skip reason from Medusa output.
    .DESCRIPTION
        Internal helper to detect quality/exists skip patterns.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputText
    )
    
    if ($OutputText -match $script:MedusaPatterns.qualityEqual) {
        return 'Same or better quality exists'
    }
    if ($OutputText -match $script:MedusaPatterns.sameSize) {
        return 'File already exists (same size)'
    }
    if ($OutputText -match $script:MedusaPatterns.fileExists) {
        return 'File already exists'
    }
    if ($OutputText -match $script:MedusaPatterns.alreadyDone) {
        return 'Already processed'
    }
    
    return ''
}

function Get-SAMedusaSpecialPattern {
    <#
    .SYNOPSIS
        Checks for special Medusa patterns (postponed, aborted, etc.).
    .DESCRIPTION
        Internal helper for edge cases not handled by count-based logic.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputText,
        
        [Parameter()]
        $Output
    )
    
    # Extract per-file details for special patterns
    $fileDetails = Get-SAMedusaFileDetails -Output $Output
    
    # Already processed
    if ($OutputText -match 'already been processed, skipping|Skipping already processed file') {
        return [PSCustomObject]@{
            Success       = $true
            Status        = 'skipped'
            Message       = 'Already processed'
            SkipReason    = 'Already processed'
            ImportedFiles = $fileDetails.ImportedFiles
            SkippedFiles  = $fileDetails.SkippedFiles
            AbortedFiles  = $fileDetails.AbortedFiles
            Output        = $Output
        }
    }
    
    # Same size
    if ($OutputText -match 'same size.*aborting|aborting post-processing') {
        return [PSCustomObject]@{
            Success       = $true
            Status        = 'skipped'
            Message       = 'File already exists (same size)'
            SkipReason    = 'File already exists (same size)'
            ImportedFiles = $fileDetails.ImportedFiles
            SkippedFiles  = $fileDetails.SkippedFiles
            AbortedFiles  = $fileDetails.AbortedFiles
            Output        = $Output
        }
    }
    
    # Postponed (error, not skip)
    if ($OutputText -match $script:MedusaPatterns.postponed) {
        return [PSCustomObject]@{
            Success       = $false
            Status        = 'failed'
            Message       = 'Postponed (waiting for subtitles)'
            ErrorType     = 'postponed'
            ImportedFiles = $fileDetails.ImportedFiles
            SkippedFiles  = $fileDetails.SkippedFiles
            AbortedFiles  = $fileDetails.AbortedFiles
            Output        = $Output
        }
    }
    
    # Aborted fallback
    if ($OutputText -match 'Processing aborted for') {
        # Extract reason using video extension anchor to avoid Windows drive letter C:
        $abortReason = 'Processing aborted'
        if ($OutputText -match "Processing aborted for .+\.($script:VideoExtensions):\s*(\S.*)$") {
            $abortReason = $Matches[2].Trim()
        }
        return [PSCustomObject]@{
            Success       = $false
            Status        = 'failed'
            Message       = $abortReason
            ErrorType     = 'aborted'
            ImportedFiles = $fileDetails.ImportedFiles
            SkippedFiles  = $fileDetails.SkippedFiles
            AbortedFiles  = $fileDetails.AbortedFiles
            Output        = $Output
        }
    }
    
    return $null
}

#endregion

#region Hint Generation

function Get-SAImportHint {
    <#
    .SYNOPSIS
        Generates actionable troubleshooting hint for import errors.
    .DESCRIPTION
        Returns a user-friendly hint based on the error type and importer.
        Follows OUTPUT-STYLE-GUIDE principle: "What to do" guidance.
    .PARAMETER ErrorType
        The categorized error type (path-format, permission, parse, etc.).
    .PARAMETER ImporterLabel
        The importer name for context (Radarr, Sonarr, Medusa).
    .PARAMETER Path
        Optional path for context in hint.
    .OUTPUTS
        String with actionable hint, or empty string if no hint available.
    .EXAMPLE
        $hint = Get-SAImportHint -ErrorType 'permission' -ImporterLabel 'Radarr'
        # Returns: "Check Radarr service account has read/write permissions"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ErrorType,
        
        [Parameter()]
        [string]$ImporterLabel = 'importer',
        
        [Parameter()]
        [string]$Path
    )
    
    switch ($ErrorType) {
        'path-format' {
            return "Use full Windows path like C:\Downloads\ReleaseFolder (escape backslashes in JSON)"
        }
        'path-not-found' {
            return "Check Remote Path Mapping in $ImporterLabel; verify folder exists and is accessible"
        }
        'permission' {
            return "Check $ImporterLabel service account has read/write permissions"
        }
        'space' {
            return "Free up space on destination drive or adjust minimum free space setting"
        }
        'parse' {
            if ($ImporterLabel -eq 'Medusa') {
                return "Check release naming or add scene exception"
            }
            return "Check release naming; use Manual Import in $ImporterLabel to see rejections"
        }
        'transfer' {
            return "Ensure download is complete and file not in use; check disk/network stability"
        }
        'postponed' {
            return "Medusa is waiting for subtitles before processing"
        }
        'aborted' {
            return "Episode is archived in Medusa - change status to Wanted or Skipped"
        }
        'not-found' {
            return "Ensure show exists in $ImporterLabel"
        }
        'unknown' {
            return "Check $ImporterLabel logs for details"
        }
        default {
            return ''
        }
    }
}

#endregion

#region Error Message Building

function Get-SAImportErrorMessage {
    <#
    .SYNOPSIS
        Builds user-friendly error message from error type.
    .DESCRIPTION
        Returns a clean error message suitable for display and email.
        Optionally includes path context.
    .PARAMETER ErrorType
        The categorized error type.
    .PARAMETER Path
        Optional path to include in message.
    .PARAMETER DefaultMessage
        Fallback message if error type not recognized.
    .OUTPUTS
        String with user-friendly error message.
    .EXAMPLE
        $msg = Get-SAImportErrorMessage -ErrorType 'path-not-found' -Path '\\server\path'
        # Returns: "Path not accessible: \\server\path"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ErrorType,
        
        [Parameter()]
        [string]$Path,
        
        [Parameter()]
        [string]$DefaultMessage = 'Import failed'
    )
    
    $msg = switch ($ErrorType) {
        'path-format'    { if ($Path) { "Invalid path format: $Path" } else { "Invalid path format" } }
        'path-not-found' { if ($Path) { "Path not accessible: $Path" } else { "Path not accessible" } }
        'permission'     { "Permission denied accessing path" }
        'space'          { "Not enough free space to import" }
        'parse'          { "Unable to parse release name" }
        'transfer'       { "File move incomplete - possible data loss" }
        'postponed'      { "Postponed (waiting for subtitles)" }
        'aborted'        { "Processing aborted" }
        'not-found'      { "Episode not found in database" }
        'file-operation' { "File operation failed" }
        'unpack'         { "Unpack failed" }
        default          { $DefaultMessage }
    }
    
    return $msg
}

function Get-SAImportSkipMessage {
    <#
    .SYNOPSIS
        Builds user-friendly skip message from error type.
    .DESCRIPTION
        Returns a clean skip message for quality/exists conditions.
    .PARAMETER ErrorType
        The skip error type (exists, quality, sample).
    .PARAMETER Count
        Optional file count for batch messages.
    .OUTPUTS
        String with user-friendly skip message.
    .EXAMPLE
        $msg = Get-SAImportSkipMessage -ErrorType 'quality' -Count 3
        # Returns: "Skipped (quality exists) (3 files)"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ErrorType,
        
        [Parameter()]
        [int]$Count = 0
    )
    
    $reason = switch ($ErrorType) {
        'quality' { 'Skipped (quality exists)' }
        'sample'  { 'Skipped (sample file)' }
        'exists'  { 'File already exists' }
        default   { 'Skipped' }
    }
    
    $countText = if ($Count -gt 1) { " ($Count files)" } else { '' }
    
    return "$reason$countText"
}

#endregion