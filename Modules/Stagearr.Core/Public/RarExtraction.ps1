#Requires -Version 5.1
<#
.SYNOPSIS
    RAR archive extraction with security validation.
.DESCRIPTION
    Functions for safely extracting RAR archives:
    - Zip-slip/path traversal prevention
    - Archive entry validation before extraction
    - WinRAR command execution
    
    SECURITY: All archive entries are validated against path traversal
    attacks before extraction. Malicious entries cause immediate abort.
    
    Requires: WinRAR (rar.exe or unrar.exe) in system PATH or configured path
#>

function Test-SARarEntriesSafe {
    <#
    .SYNOPSIS
        Validates RAR archive entries for path traversal attacks (Zip-Slip vulnerability).
    .DESCRIPTION
        Checks all entries in a RAR archive against known unsafe path patterns that could
        be used to write files outside the intended extraction directory. This prevents
        malicious archives from exploiting path traversal to overwrite system files.
        
        Unsafe patterns detected:
        - Windows absolute paths (C:\, D:\, etc.)
        - UNC paths (\\server\share)
        - Unix absolute paths (/etc, /usr, etc.)
        - Parent directory traversal (..\, ../)
    .PARAMETER RarPath
        Path to the RAR archive to validate.
    .PARAMETER WinRarPath
        Path to the WinRAR/UnRAR executable.
    .OUTPUTS
        Hashtable with Safe=$true if archive is safe, or Safe=$false with BadEntry and Pattern
        if a malicious entry is detected.
    .EXAMPLE
        $result = Test-SARarEntriesSafe -RarPath "archive.rar" -WinRarPath "C:\Program Files\WinRAR\Rar.exe"
        if (-not $result.Safe) { Write-Error "Unsafe entry: $($result.BadEntry)" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$RarPath,
        
        [Parameter(Mandatory)]
        [string]$WinRarPath
    )
    
    # Get bare list of archive entries (filenames only, one per line)
    $rarName = Split-Path -Path $RarPath -Leaf
    Write-SAVerbose -Text "Validating archive entries for path traversal: $rarName"
    
    $processArgs = @('lb', $RarPath)
    $result = Invoke-SAProcess -FilePath $WinRarPath -ArgumentList $processArgs
    
    if (-not $result.Success) {
        # If we can't list the archive, fail safe by rejecting it
        Write-SAVerbose -Text "Failed to list archive contents - rejecting as unsafe"
        return @{
            Safe     = $false
            BadEntry = '[Unable to list archive contents]'
            Pattern  = 'N/A'
        }
    }
    
    $entries = $result.StdOut -split "`n" | Where-Object { $_.Trim() -ne '' }
    Write-SAVerbose -Text "Checking $($entries.Count) archive entries against unsafe patterns"
    
    # Patterns that indicate path traversal or absolute path attacks
    $unsafePatterns = @(
        '^[A-Za-z]:',    # Windows absolute path (C:\, D:\, etc.)
        '^\\\\',          # UNC path (\\server\share)
        '^/',             # Unix absolute path
        '\.\.'            # Parent directory traversal (..\ or ../)
    )
    
    foreach ($entry in $entries) {
        foreach ($pattern in $unsafePatterns) {
            if ($entry -match $pattern) {
                Write-SAVerbose -Text "Unsafe entry detected: '$entry' (matched pattern: $pattern)"
                return @{
                    Safe     = $false
                    BadEntry = $entry
                    Pattern  = $pattern
                }
            }
        }
    }
    
    Write-SAVerbose -Text "Archive passed security validation"
    return @{ Safe = $true }
}

function Start-SAUnrar {
    <#
    .SYNOPSIS
        Extracts RAR archive to staging folder.
    .DESCRIPTION
        Safely extracts RAR archives after validating against path traversal attacks.
        Archives containing entries with absolute paths or parent directory references
        are rejected to prevent Zip-Slip vulnerabilities.
        
        Per OUTPUT-STYLE-GUIDE.md, displays progress indication:
        - Source: Shows count and total size of archive parts
        - Extracting with WinRAR... before long operation
        - Extracted: Shows count and size of extracted files on success
    .PARAMETER Context
        Processing context.
    .PARAMETER RarPath
        Path to the RAR file (first part for multi-part archives).
    .PARAMETER OutputFolder
        Destination folder for extraction.
    .OUTPUTS
        $true if successful, $false otherwise.
    .EXAMPLE
        Console output for single RAR:
        [17:00:01]   Source: 1 RAR file (3.7 GB)
        [17:00:01]   Extracting with WinRAR...
        [17:00:17] ✓ Extracted: 1 file (3.7 GB)
    .EXAMPLE
        Console output for multi-part archive:
        [17:00:01]   Source: 47 RAR files (4.2 GB)
        [17:00:01]   Extracting with WinRAR...
        [17:00:17] ✓ Extracted: 1 file (4.2 GB)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [string]$RarPath,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputFolder
    )
    
    $winrar = $Context.Tools.WinRar
    $rarName = Split-Path -Path $RarPath -Leaf
    
    Write-SAPhaseHeader -Title "RAR Extraction"
    Write-SAVerbose -Text "Archive: $rarName"
    
    # Count RAR parts and calculate total archive size for progress indication
    # Per OUTPUT-STYLE-GUIDE.md: Show source info before long operations
    $rarDir = Split-Path -Path $RarPath -Parent
    $rarBaseName = [System.IO.Path]::GetFileNameWithoutExtension($RarPath)
    
    # Handle multi-part naming: archive.part01.rar, archive.part02.rar, etc.
    # Remove .partNN suffix if present to get true base name
    if ($rarBaseName -match '^(.+)\.part\d+$') {
        $rarBaseName = $Matches[1]
    }
    
    # Find all archive parts:
    # - Old format: archive.rar, archive.r00, archive.r01, ...
    # - New format: archive.part01.rar, archive.part02.rar, ...
    $archiveParts = @(Get-ChildItem -LiteralPath $rarDir -File -ErrorAction SilentlyContinue | Where-Object {
        $name = $_.Name
        # Match the exact base name followed by:
        # - .rar, .r00, .r01, etc. (old format)
        # - .part01.rar, .part02.rar, etc. (new format)
        $name -match "^$([regex]::Escape($rarBaseName))\.(rar|r\d{2,3}|part\d+\.rar)$"
    })
    
    # Fallback: if no parts found, just use the input file
    if ($archiveParts.Count -eq 0) {
        $archiveParts = @(Get-Item -LiteralPath $RarPath -ErrorAction SilentlyContinue)
    }
    
    $partCount = $archiveParts.Count
    $totalArchiveSize = ($archiveParts | Measure-Object -Property Length -Sum).Sum
    if (-not $totalArchiveSize) { $totalArchiveSize = 0 }
    
    # Show source info per OUTPUT-STYLE-GUIDE.md progress indication rules
    $fileWord = Get-SAPluralForm -Count $partCount -Singular 'RAR file'
    Write-SAProgress -Label "Source" -Text "$partCount $fileWord ($(Format-SASize $totalArchiveSize))" -Indent 1
    
    # SECURITY: Validate archive entries before extraction (Zip-Slip protection)
    # Malicious archives can contain entries like "../../../Windows/System32/evil.dll"
    # that would write outside the staging directory. We must validate BEFORE extracting
    # because the -o+ flag will overwrite existing files without prompting.
    $safetyCheck = Test-SARarEntriesSafe -RarPath $RarPath -WinRarPath $winrar
    
    if (-not $safetyCheck.Safe) {
        Write-SAOutcome -Level Error -Label "Security" -Text "Malicious archive detected - path traversal attack" -Indent 1
        Write-SAProgress -Label "BadEntry" -Text $safetyCheck.BadEntry -Indent 2
        Write-SAProgress -Label "Pattern" -Text $safetyCheck.Pattern -Indent 2
        Write-SAVerbose -Text "Archive '$rarName' contains unsafe entry: $($safetyCheck.BadEntry) (matched: $($safetyCheck.Pattern))"
        return $false
    }
    
    # Ensure output folder exists
    New-SADirectory -Path $OutputFolder
    
    # rar x = extract with full paths
    # -y = assume yes to all queries
    # -p- = do NOT prompt for password (fail immediately if archive is encrypted)
    #       Without this flag, WinRAR hangs waiting for user input.
    #
    # SECURITY NOTE: -o+ (overwrite existing) is dangerous because it allows archives
    # to overwrite files without confirmation. We mitigate this risk by:
    # 1. Validating all entries with Test-SARarEntriesSafe before extraction
    # 2. Extracting only to an isolated staging directory
    # The safety check above MUST run before this extraction to prevent Zip-Slip attacks.
    $processArgs = @(
        'x',
        '-o+',
        '-y',
        '-p-',
        $RarPath,
        "$OutputFolder\"  # Trailing backslash is important
    )
    
    # Show progress indication before long operation per OUTPUT-STYLE-GUIDE.md
    Write-SAProgress -Text "Extracting with WinRAR..." -Indent 1
    
    # Use retry wrapper for transient failures (locked files, write errors)
    $result = Invoke-SAProcessWithRetry -FilePath $winrar `
        -ArgumentList $processArgs `
        -MaxRetries 2 `
        -RetryDelaySeconds 5 `
        -RetryExitCodes @(4, 5)  # 4 = locked, 5 = write error
    
    if ($result.Success) {
        # Count extracted files
        $extractedFiles = Get-ChildItem -LiteralPath $OutputFolder -Recurse -File
        $totalSize = ($extractedFiles | Measure-Object -Property Length -Sum).Sum
        $fileWord = Get-SAPluralForm -Count $extractedFiles.Count -Singular 'file'
        
        Write-SAOutcome -Level Success -Label "Extracted" -Text "$($extractedFiles.Count) $fileWord ($(Format-SASize $totalSize))" -Indent 1
        
        $Context.Results.FilesExtracted += $extractedFiles.Count
        return $true
    } else {
        # Log user-friendly error with guidance
        Write-SAToolError -Label "Extract" `
            -ToolName 'rar' `
            -ExitCode $result.ExitCode `
            -ErrorMessage $result.StdErr `
            -FilePath $RarPath
        
        return $false
    }
}
