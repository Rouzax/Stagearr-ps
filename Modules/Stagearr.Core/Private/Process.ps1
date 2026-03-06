#Requires -Version 5.1
<#
.SYNOPSIS
    Process runner wrapper for Stagearr
.DESCRIPTION
    Provides a consistent interface for running external tools (mkvmerge, rar, etc.)
    with proper output capture, error handling, and logging.
#>

function Get-SAEscapedArgument {
    <#
    .SYNOPSIS
        Escapes a command-line argument for safe use with ProcessStartInfo.Arguments.
    .DESCRIPTION
        Properly escapes arguments containing spaces or quotes by doubling embedded quotes
        and wrapping in outer quotes. This ensures safe handling of paths like:
        - "C:\Program Files\Test"
        - 'Movie "Director's Cut" 2024'
        - "File & Name (2024)"
    .PARAMETER Arg
        The argument to escape.
    .OUTPUTS
        The escaped argument string.
    .EXAMPLE
        Get-SAEscapedArgument -Arg 'C:\Program Files\Test'
        # Returns: "C:\Program Files\Test"
    .EXAMPLE
        Get-SAEscapedArgument -Arg 'Movie "Director''s Cut" 2024'
        # Returns: "Movie ""Director's Cut"" 2024"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Arg
    )
    
    # Empty string needs to be quoted to preserve it as an argument
    if ([string]::IsNullOrEmpty($Arg)) {
        return '""'
    }
    
    # Strip newlines/carriage returns - these break command lines
    $Arg = $Arg -replace '[\r\n]+', ' '

    # If argument contains spaces, quotes, backticks, or special shell chars, escape and wrap
    if ($Arg -match '[\s"&|<>^`]') {
        # Escape existing quotes by doubling them
        $escaped = $Arg -replace '"', '""'
        return "`"$escaped`""
    }

    return $Arg
}

function Invoke-SAProcess {
    <#
    .SYNOPSIS
        Runs an external process and captures output.
    .DESCRIPTION
        Executes an external program with arguments, capturing stdout, stderr, and exit code.
        Provides consistent handling across PS 5.1 and 7.x.
    .PARAMETER FilePath
        Path to the executable.
    .PARAMETER ArgumentList
        Array of arguments to pass.
    .PARAMETER WorkingDirectory
        Working directory for the process (optional).
    .PARAMETER TimeoutSeconds
        Timeout in seconds (default: 0 = no timeout).
    .OUTPUTS
        PSCustomObject with: ExitCode, StdOut, StdErr, Success, Duration
    .EXAMPLE
        $result = Invoke-SAProcess -FilePath "mkvmerge" -ArgumentList @("-J", "file.mkv")
        if ($result.Success) { $json = $result.StdOut | ConvertFrom-Json }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        
        [Parameter()]
        [string[]]$ArgumentList = @(),
        
        [Parameter()]
        [string]$WorkingDirectory,
        
        [Parameter()]
        [int]$TimeoutSeconds = 0
    )
    
    # Validate executable exists
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        # Try to find in PATH
        $found = Get-Command -Name $FilePath -ErrorAction SilentlyContinue
        if ($found) {
            $FilePath = $found.Source
        } else {
            return [PSCustomObject]@{
                ExitCode = -1
                StdOut   = ''
                StdErr   = "Executable not found: $FilePath"
                Success  = $false
                Duration = [TimeSpan]::Zero
            }
        }
    }
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        # Create process start info
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        # UTF-8 assumption: all external tools used by Stagearr (mkvmerge, mkvextract,
        # WinRAR, SubtitleEdit) output UTF-8. Non-UTF-8 tools would produce garbled output.
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        
        if ($ArgumentList.Count -gt 0) {
            # Escape arguments properly for the command line
            # Each argument is escaped individually to handle spaces and quotes
            $escapedArgs = $ArgumentList | ForEach-Object { Get-SAEscapedArgument -Arg $_ }
            $startInfo.Arguments = $escapedArgs -join ' '
        }
        
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $startInfo.WorkingDirectory = $WorkingDirectory
        }
        
        # Create and start process
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        
        $process.Start() | Out-Null
        
        # Read stdout and stderr synchronously but in parallel to avoid deadlocks
        # For large outputs, we need to read before WaitForExit to prevent buffer deadlock
        $stdOutTask = $process.StandardOutput.ReadToEndAsync()
        $stdErrTask = $process.StandardError.ReadToEndAsync()
        
        # Wait for exit with optional timeout
        if ($TimeoutSeconds -gt 0) {
            $exited = $process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $exited) {
                $process.Kill()
                $stopwatch.Stop()
                
                # Try to get partial output for debugging
                $partialOut = ''
                $partialErr = ''
                try {
                    if ($stdOutTask.Wait(1000)) { $partialOut = $stdOutTask.Result }
                    if ($stdErrTask.Wait(1000)) { $partialErr = $stdErrTask.Result }
                } catch { }
                
                # Include partial stderr in error message if available
                $timeoutMessage = "Process timed out after $TimeoutSeconds seconds"
                if (-not [string]::IsNullOrWhiteSpace($partialErr)) {
                    $timeoutMessage = "$timeoutMessage`n$partialErr"
                }
                
                return [PSCustomObject]@{
                    ExitCode = -2
                    StdOut   = $partialOut
                    StdErr   = $timeoutMessage
                    Success  = $false
                    Duration = $stopwatch.Elapsed
                }
            }
        } else {
            $process.WaitForExit()
        }
        
        # Wait for async reads to complete (they should be done since process exited)
        $stdout = $stdOutTask.GetAwaiter().GetResult()
        $stderr = $stdErrTask.GetAwaiter().GetResult()
        
        $stopwatch.Stop()
        
        $exitCode = $process.ExitCode
        
        return [PSCustomObject]@{
            ExitCode = $exitCode
            StdOut   = if ($stdout) { $stdout.TrimEnd() } else { '' }
            StdErr   = if ($stderr) { $stderr.TrimEnd() } else { '' }
            Success  = ($exitCode -eq 0)
            Duration = $stopwatch.Elapsed
        }
        
    } catch {
        $stopwatch.Stop()
        return [PSCustomObject]@{
            ExitCode = -1
            StdOut   = ''
            StdErr   = $_.Exception.Message
            Success  = $false
            Duration = $stopwatch.Elapsed
        }
    } finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}
