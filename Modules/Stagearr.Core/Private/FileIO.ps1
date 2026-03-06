#Requires -Version 5.1
<#
.SYNOPSIS
    File system I/O utilities.
.DESCRIPTION
    Standardized file operations with consistent encoding:
    - UTF-8 without BOM (cross-platform compatibility)
    - Atomic writes (prevent corruption)
    - Directory creation with validation
    
    All write operations use UTF-8 encoding without BOM for
    maximum compatibility with external tools (SubtitleEdit, mkvmerge, etc.).
    
    Used by: Queue.ps1, Lock.ps1, FileLogRenderer.ps1, Subtitles.ps1
#>

function New-SADirectory {
    <#
    .SYNOPSIS
        Creates a directory if it doesn't exist.
    .DESCRIPTION
        Safe directory creation with existence check. Uses -Force to handle
        race conditions and nested path creation.
    .PARAMETER Path
        The directory path to create.
    .PARAMETER PassThru
        Returns the DirectoryInfo object if specified.
    .EXAMPLE
        New-SADirectory -Path "C:\Logs\Archive"
    .EXAMPLE
        $dir = New-SADirectory -Path "C:\Processing\Job123" -PassThru
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter()]
        [switch]$PassThru
    )
    
    if (-not (Test-Path -LiteralPath $Path)) {
        $dir = New-Item -ItemType Directory -Path $Path -Force
        if ($PassThru) {
            return $dir
        }
    } elseif ($PassThru) {
        return Get-Item -LiteralPath $Path
    }
}

function Write-SAFileUtf8NoBom {
    <#
    .SYNOPSIS
        Writes content to a file using UTF-8 without BOM (PS 5.1 and 7.x compatible).
    .DESCRIPTION
        Standard file write function for text content. Uses UTF-8 encoding without
        the Byte Order Mark (BOM) for maximum compatibility with external tools.
        
        PowerShell version differences:
        - PS 7.x: Uses -Encoding utf8NoBOM parameter
        - PS 5.1: Uses .NET UTF8Encoding class directly
    .PARAMETER Path
        The file path to write to.
    .PARAMETER Content
        The content to write.
    .EXAMPLE
        Write-SAFileUtf8NoBom -Path "C:\Output\file.srt" -Content $subtitleContent
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )
    
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Set-Content -LiteralPath $Path -Value $Content -Encoding utf8NoBOM -NoNewline
    } else {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    }
}

function Write-SAFileAtomicUtf8NoBom {
    <#
    .SYNOPSIS
        Atomically writes content to a file using UTF-8 without BOM.
    .DESCRIPTION
        Uses a write-then-rename pattern to ensure file integrity. Content is first
        written to a temporary file, then atomically moved to the destination. This
        prevents file corruption if the process crashes or loses power mid-write.
        
        On Windows, Move-Item with -Force will overwrite the destination atomically
        at the filesystem level (NTFS provides this guarantee).
        
        The temp file is created in the same directory as the destination to ensure
        both files are on the same filesystem (required for atomic rename).
    .PARAMETER Path
        The destination file path.
    .PARAMETER Content
        The content to write.
    .EXAMPLE
        Write-SAFileAtomicUtf8NoBom -Path "C:\Queue\job.json" -Content $jobJson
    .NOTES
        This function should be used for all critical data files (queue jobs, lock files, etc.)
        where corruption would cause data loss or incorrect behavior.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )
    
    # Create temp file in same directory (ensures same filesystem for atomic rename)
    $directory = Split-Path -Path $Path -Parent
    $fileName = Split-Path -Path $Path -Leaf
    $tempPath = Join-Path -Path $directory -ChildPath ".tmp.$PID.$fileName"
    
    try {
        # Write to temp file
        Write-SAFileUtf8NoBom -Path $tempPath -Content $Content
        
        # Atomic rename (Move-Item -Force overwrites atomically on NTFS)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } catch {
        # Clean up temp file on failure
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Write-SAFileLinesUtf8NoBom {
    <#
    .SYNOPSIS
        Writes an array of lines to a file using UTF-8 without BOM.
    .DESCRIPTION
        Similar to Write-SAFileUtf8NoBom but accepts an array of strings
        and writes them as lines with proper line endings.
        
        Used primarily by FileLogRenderer for log files where content
        is accumulated as an array of lines.
    .PARAMETER Path
        The file path to write to.
    .PARAMETER Lines
        Array of strings to write as lines.
    .EXAMPLE
        Write-SAFileLinesUtf8NoBom -Path "C:\Logs\job.log" -Lines @("Line 1", "Line 2")
    .EXAMPLE
        $logEntries = @("[17:00:01] Starting", "[17:00:02] Complete")
        Write-SAFileLinesUtf8NoBom -Path $logPath -Lines $logEntries
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$Lines
    )
    
    # Handle null/empty - write empty file
    if ($null -eq $Lines) {
        $Lines = @()
    }
    
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Set-Content -LiteralPath $Path -Value $Lines -Encoding utf8NoBOM
    } else {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
    }
}
