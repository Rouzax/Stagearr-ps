#Requires -Version 5.1
<#
.SYNOPSIS
    Error handling and user-friendly message translation for Stagearr
.DESCRIPTION
    Translates technical errors from external tools into plain language messages
    following the OUTPUT-STYLE-GUIDE principle: What + Why + What to do.
#>

# Tool-specific error definitions
# Each tool has a hashtable of exit codes -> user-friendly error info
$script:SAToolErrors = @{
    # MKVToolNix (mkvmerge, mkvextract)
    'mkvmerge' = @{
        # Exit code 1 is warnings, not errors - handled separately
        2 = @{
            Problem = 'mkvmerge encountered an error'
            Reason  = 'The file may be corrupted or use an unsupported format'
            Action  = 'Try re-downloading the file or check if it plays correctly'
        }
        3 = @{
            Problem = 'mkvmerge crashed unexpectedly'
            Reason  = 'Internal error or corrupted input file'
            Action  = 'Check if the source file is complete and not corrupted'
        }
    }
    'mkvextract' = @{
        1 = @{
            Problem = 'mkvextract encountered a warning'
            Reason  = 'Some tracks may not have been extracted correctly'
            Action  = 'Check if the extracted subtitle files are valid'
        }
        2 = @{
            Problem = 'mkvextract failed to extract tracks'
            Reason  = 'The MKV file may be corrupted or tracks are in an unsupported format'
            Action  = 'Verify the source file is complete and try again'
        }
    }
    
    # WinRAR / UnRAR
    'rar' = @{
        1 = @{
            Problem = 'WinRAR completed with warnings'
            Reason  = 'Some files may not have extracted correctly'
            Action  = 'Check the extracted files for completeness'
        }
        2 = @{
            Problem = 'A fatal error occurred during extraction'
            Reason  = 'The archive may be severely corrupted'
            Action  = 'Re-download the archive and try again'
        }
        3 = @{
            Problem = 'CRC check failed'
            Reason  = 'The archive is corrupted or the download was incomplete'
            Action  = 'Re-download the file - the current copy is damaged'
        }
        4 = @{
            Problem = 'Archive is locked'
            Reason  = 'Another program is using this file'
            Action  = 'Close any other programs accessing this file and retry'
        }
        5 = @{
            Problem = 'Could not write to disk'
            Reason  = 'Disk may be full or folder is read-only'
            Action  = 'Check available disk space and folder permissions'
        }
        6 = @{
            Problem = 'Could not open archive'
            Reason  = 'File may be corrupted or not a valid RAR archive'
            Action  = 'Verify the file is a valid RAR archive'
        }
        7 = @{
            Problem = 'Invalid command line option'
            Reason  = 'Internal configuration error'
            Action  = 'Report this issue - this is a script bug'
        }
        8 = @{
            Problem = 'Not enough memory'
            Reason  = 'System ran out of memory during extraction'
            Action  = 'Close other applications and try again'
        }
        9 = @{
            Problem = 'Could not create file'
            Reason  = 'Filename may be too long or contain invalid characters'
            Action  = 'Check if the archive contains files with very long names'
        }
        10 = @{
            Problem = 'No files matched the pattern'
            Reason  = 'Archive appears to be empty or corrupted'
            Action  = 'Verify the archive contains the expected files'
        }
        11 = @{
            Problem = 'Archive is password-protected'
            Reason  = 'A password is required to extract this archive'
            Action  = 'Password-protected archives are not supported'
        }
        255 = @{
            Problem = 'User cancelled operation'
            Reason  = 'Extraction was interrupted'
            Action  = 'Run the script again if this was unintentional'
        }
    }
    
    # SubtitleEdit
    'SubtitleEdit' = @{
        1 = @{
            Problem = 'SubtitleEdit encountered an error'
            Reason  = 'The subtitle file may be malformed'
            Action  = 'The original subtitle was preserved - it may still be usable'
        }
    }
    
    # Robocopy (special handling - 0-7 are success)
    'robocopy' = @{
        8 = @{
            Problem = 'Some files could not be copied'
            Reason  = 'Files may be in use or you may lack permission'
            Action  = 'Check if files are open in another program'
        }
        16 = @{
            Problem = 'Serious error - no files were copied'
            Reason  = 'Source or destination may be inaccessible'
            Action  = 'Verify the source path exists and destination is writable'
        }
    }
    
    # ffprobe
    'ffprobe' = @{
        1 = @{
            Problem = 'Could not analyze video file'
            Reason  = 'File may be corrupted or in an unsupported format'
            Action  = 'Check if the video file plays correctly in a media player'
        }
    }
}

# Common exception patterns and their translations
$script:SAExceptionPatterns = @(
    @{
        Pattern = 'Access.*denied|EPERM|permission'
        Problem = 'Access denied'
        Reason  = 'The script lacks permission to access a file or folder'
        Action  = 'Run as administrator or check folder permissions'
    }
    @{
        Pattern = 'disk.*full|not enough space|no space|ENOSPC'
        Problem = 'Disk is full'
        Reason  = 'Not enough free space to complete the operation'
        Action  = 'Free up disk space and try again'
    }
    @{
        Pattern = 'file.*not found|ENOENT|FileNotFoundException'
        Problem = 'File not found'
        Reason  = 'A required file is missing or was moved'
        Action  = 'Verify the source files still exist'
    }
    @{
        Pattern = 'network.*path|UNC.*path|cannot find.*path'
        Problem = 'Network path not accessible'
        Reason  = 'Network drive may be disconnected or unavailable'
        Action  = 'Check that network drives are connected and accessible'
    }
    @{
        Pattern = 'timed? ?out|timeout'
        Problem = 'Operation timed out'
        Reason  = 'The tool took too long to respond'
        Action  = 'The system may be under heavy load - try again later'
    }
    @{
        Pattern = 'process.*terminated|killed|SIGKILL|SIGTERM'
        Problem = 'Process was terminated unexpectedly'
        Reason  = 'The tool crashed or was killed by the system'
        Action  = 'This may indicate a corrupted file or system issue'
    }
    @{
        Pattern = 'out of memory|OutOfMemoryException|not enough memory'
        Problem = 'Out of memory'
        Reason  = 'Not enough RAM available to complete the operation'
        Action  = 'Close other applications and try again'
    }
    @{
        Pattern = 'corrupt|invalid.*data|bad.*format'
        Problem = 'File appears corrupted'
        Reason  = 'The file data is invalid or damaged'
        Action  = 'Re-download the file - this copy is damaged'
    }
)

function Get-SAToolErrorInfo {
    <#
    .SYNOPSIS
        Gets user-friendly error information for a tool failure.
    .DESCRIPTION
        Translates exit codes and error messages into plain language
        with actionable guidance for the user.
    .PARAMETER ToolName
        Name of the tool (mkvmerge, rar, SubtitleEdit, etc.).
    .PARAMETER ExitCode
        The exit code returned by the tool.
    .PARAMETER ErrorMessage
        The stderr or exception message from the tool.
    .PARAMETER FilePath
        Optional path to the file being processed (for context).
    .OUTPUTS
        PSCustomObject with Problem, Reason, Action, and formatted Message.
    .EXAMPLE
        $errorInfo = Get-SAToolErrorInfo -ToolName 'rar' -ExitCode 11
        Write-SAOutcome -Level Error -Label "Extract" -Text $errorInfo.Problem
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName,
        
        [Parameter()]
        [int]$ExitCode = -1,
        
        [Parameter()]
        [string]$ErrorMessage = '',
        
        [Parameter()]
        [string]$FilePath = ''
    )
    
    $problem = $null
    $reason = $null
    $action = $null
    
    # Normalize tool name (handle full paths)
    $toolBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ToolName).ToLower()
    
    # Map common tool variants
    $toolKey = switch -Regex ($toolBaseName) {
        'mkvmerge'      { 'mkvmerge' }
        'mkvextract'    { 'mkvextract' }
        'rar|unrar|winrar' { 'rar' }
        'subtitleedit'  { 'SubtitleEdit' }
        'robocopy'      { 'robocopy' }
        'ffprobe'       { 'ffprobe' }
        default         { $toolBaseName }
    }
    
    # Try to find a specific exit code mapping
    if ($script:SAToolErrors.ContainsKey($toolKey)) {
        $toolErrors = $script:SAToolErrors[$toolKey]
        if ($toolErrors.ContainsKey($ExitCode)) {
            $errorDef = $toolErrors[$ExitCode]
            $problem = $errorDef.Problem
            $reason = $errorDef.Reason
            $action = $errorDef.Action
        }
    }
    
    # If no specific mapping, try to match exception patterns
    if (-not $problem -and -not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        foreach ($pattern in $script:SAExceptionPatterns) {
            if ($ErrorMessage -match $pattern.Pattern) {
                $problem = $pattern.Problem
                $reason = $pattern.Reason
                $action = $pattern.Action
                break
            }
        }
    }
    
    # Fallback to generic error based on exit code
    if (-not $problem) {
        $problem = switch ($ExitCode) {
            -1      { "$toolKey failed to start or crashed" }
            -2      { "$toolKey timed out" }
            0       { "$toolKey reported success but something went wrong" }
            default { "$toolKey failed (exit code: $ExitCode)" }
        }
        
        if (-not $reason) {
            $reason = if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
                # Truncate very long error messages (keep end for filenames/specifics)
                if ($ErrorMessage.Length -gt 200) {
                    '...' + $ErrorMessage.Substring($ErrorMessage.Length - 197)
                } else {
                    $ErrorMessage
                }
            } else {
                'The tool encountered an unexpected error'
            }
        }
        
        if (-not $action) {
            $action = 'Check that the tool is installed correctly and the input file is valid'
        }
    }
    
    # Build formatted message for logging
    $formattedMessage = $problem
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        $fileName = Split-Path -Path $FilePath -Leaf
        $formattedMessage = "$problem - $fileName"
    }
    
    return [PSCustomObject]@{
        Problem   = $problem
        Reason    = $reason
        Action    = $action
        Message   = $formattedMessage
        ToolName  = $toolKey
        ExitCode  = $ExitCode
        RawError  = $ErrorMessage
    }
}

function Write-SAToolError {
    <#
    .SYNOPSIS
        Writes a user-friendly error message for a tool failure.
    .DESCRIPTION
        Combines Get-SAToolErrorInfo with console output to provide
        clear, actionable error messages following the style guide.
    .PARAMETER Label
        Console output label (e.g., "Extract", "Remux").
    .PARAMETER ToolName
        Name of the tool that failed.
    .PARAMETER ExitCode
        Exit code from the tool.
    .PARAMETER ErrorMessage
        Error message from stderr or exception.
    .PARAMETER FilePath
        Optional file path for context.
    .PARAMETER ShowAction
        Show the suggested action (default: true).
    .PARAMETER Indent
        Indentation level for console hierarchy (0-2).
    .EXAMPLE
        Write-SAToolError -Label "Extract" -ToolName "rar" -ExitCode 3 -FilePath "movie.rar" -Indent 2
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        
        [Parameter(Mandatory = $true)]
        [string]$ToolName,
        
        [Parameter()]
        [int]$ExitCode = -1,
        
        [Parameter()]
        [string]$ErrorMessage = '',
        
        [Parameter()]
        [string]$FilePath = '',
        
        [Parameter()]
        [bool]$ShowAction = $true,
        
        [Parameter()]
        [ValidateRange(0, 2)]
        [int]$Indent = 1
    )
    
    $errorInfo = Get-SAToolErrorInfo -ToolName $ToolName `
        -ExitCode $ExitCode `
        -ErrorMessage $ErrorMessage `
        -FilePath $FilePath
    
    # Primary error line
    Write-SAOutcome -Level Error -Label $Label -Text $errorInfo.Problem -Indent $Indent
    
    # Reason (as info line) - use same or next indent level
    $detailIndent = [Math]::Min(2, $Indent + 1)
    if (-not [string]::IsNullOrWhiteSpace($errorInfo.Reason)) {
        Write-SAProgress -Label "Reason" -Text $errorInfo.Reason -Indent $detailIndent
    }
    
    # Action guidance
    if ($ShowAction -and -not [string]::IsNullOrWhiteSpace($errorInfo.Action)) {
        Write-SAProgress -Label "Action" -Text $errorInfo.Action -Indent $detailIndent
    }
    
    # Verbose: raw error for debugging (simplified message - full details in log file)
    if (-not [string]::IsNullOrWhiteSpace($errorInfo.RawError)) {
        Write-SAVerbose -Label "Error" -Text "Raw: $($errorInfo.RawError)"
    }
    
    return $errorInfo
}

function Invoke-SAProcessWithRetry {
    <#
    .SYNOPSIS
        Runs an external process with automatic retry on transient failures.
    .DESCRIPTION
        Wraps Invoke-SAProcess with retry logic for recoverable errors
        like timeouts or temporary file locks.
    .PARAMETER FilePath
        Path to the executable.
    .PARAMETER ArgumentList
        Arguments to pass.
    .PARAMETER MaxRetries
        Maximum retry attempts (default: 2).
    .PARAMETER RetryDelaySeconds
        Seconds to wait between retries (default: 3).
    .PARAMETER TimeoutSeconds
        Timeout per attempt (default: 0 = no timeout).
    .PARAMETER RetryExitCodes
        Exit codes that should trigger a retry (default: @(-2, 4, 5)).
        -2 = timeout, 4 = locked (rar), 5 = write error (rar)
    .OUTPUTS
        Process result object from Invoke-SAProcess.
    .EXAMPLE
        $result = Invoke-SAProcessWithRetry -FilePath "rar" -ArgumentList @("x", "file.rar")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        
        [Parameter()]
        [string[]]$ArgumentList = @(),
        
        [Parameter()]
        [int]$MaxRetries = 2,
        
        [Parameter()]
        [int]$RetryDelaySeconds = 3,
        
        [Parameter()]
        [int]$TimeoutSeconds = 0,
        
        [Parameter()]
        [int[]]$RetryExitCodes = @(-2, 4, 5),
        
        [Parameter()]
        [string]$WorkingDirectory
    )
    
    $attempt = 0
    $result = $null
    
    do {
        $attempt++
        
        $processParams = @{
            FilePath     = $FilePath
            ArgumentList = $ArgumentList
        }
        
        if ($TimeoutSeconds -gt 0) {
            $processParams.TimeoutSeconds = $TimeoutSeconds
        }
        
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $processParams.WorkingDirectory = $WorkingDirectory
        }
        
        $result = Invoke-SAProcess @processParams
        
        # Check if we should retry
        if ($result.Success) {
            break
        }
        
        $shouldRetry = ($result.ExitCode -in $RetryExitCodes) -and ($attempt -lt $MaxRetries + 1)
        
        if ($shouldRetry) {
            $toolName = Split-Path -Path $FilePath -Leaf
            Write-SAVerbose -Label $toolName -Text "Failed (exit: $($result.ExitCode)), retrying in ${RetryDelaySeconds}s..."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
        
    } while ($shouldRetry)
    
    return $result
}

function Test-SAProcessResult {
    <#
    .SYNOPSIS
        Tests a process result and optionally logs errors.
    .DESCRIPTION
        Provides a simple way to check process results and log
        user-friendly errors in one step.
    .PARAMETER Result
        The result object from Invoke-SAProcess.
    .PARAMETER ToolName
        Name of the tool for error messages.
    .PARAMETER Label
        Console label for error output.
    .PARAMETER FilePath
        Optional file path for context.
    .PARAMETER SuccessCodes
        Additional exit codes to treat as success (e.g., @(1) for mkvmerge warnings).
    .PARAMETER LogError
        Whether to log errors automatically (default: true).
    .OUTPUTS
        $true if successful, $false otherwise.
    .EXAMPLE
        $result = Invoke-SAProcess -FilePath "mkvmerge" -ArgumentList @("-o", $out, $in)
        if (-not (Test-SAProcessResult -Result $result -ToolName "mkvmerge" -Label "Remux" -SuccessCodes @(1))) {
            return $false
        }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result,
        
        [Parameter(Mandatory = $true)]
        [string]$ToolName,
        
        [Parameter()]
        [string]$Label = 'Process',
        
        [Parameter()]
        [string]$FilePath = '',
        
        [Parameter()]
        [int[]]$SuccessCodes = @(),
        
        [Parameter()]
        [bool]$LogError = $true
    )
    
    # Check for success
    $isSuccess = $Result.Success -or ($Result.ExitCode -in $SuccessCodes)
    
    if (-not $isSuccess -and $LogError) {
        Write-SAToolError -Label $Label `
            -ToolName $ToolName `
            -ExitCode $Result.ExitCode `
            -ErrorMessage $Result.StdErr `
            -FilePath $FilePath
    }
    
    return $isSuccess
}
