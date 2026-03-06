#Requires -Version 5.1
<#
.SYNOPSIS
    Miscellaneous utility functions for Stagearr.
.DESCRIPTION
    General-purpose utilities that don't fit other categories:
    - Hash computation (SHA256)
    - Platform detection (Windows/cross-platform)
    - Type conversion (PSCustomObject to hashtable)
    - Job state management (reset between jobs)
    
    These are the remaining "catch-all" utilities after domain-specific
    functions were extracted to focused modules:
    - Path security → PathSecurity.ps1
    - File I/O → FileIO.ps1
    - Episode formatting → EpisodeFormatting.ps1
    - Media parsing → MediaParsing.ps1
    
    Used by: Various modules throughout Stagearr
#>

#region Hashing Functions

function Get-SAHash {
    <#
    .SYNOPSIS
        Generates a SHA256 hash of the input string.
    .DESCRIPTION
        Computes a cryptographic hash for string input. Used for generating
        unique identifiers, cache keys, and verification purposes.
        
        The hash is returned as a lowercase hexadecimal string.
    .PARAMETER InputString
        The string to hash.
    .PARAMETER Length
        Truncate the hash to this many characters (default: full 64).
        Useful when only a portion of the hash is needed for identification.
    .EXAMPLE
        Get-SAHash -InputString "test" -Length 16
        # Returns: "9f86d081884c7d65"
    .EXAMPLE
        Get-SAHash -InputString "unique-identifier"
        # Returns: full 64-character SHA256 hash
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputString,
        
        [Parameter()]
        [int]$Length = 64
    )
    
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
        $hashBytes = $sha256.ComputeHash($bytes)
        $hashString = [BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()
        
        if ($Length -gt 0 -and $Length -lt $hashString.Length) {
            return $hashString.Substring(0, $Length)
        }
        return $hashString
    } finally {
        $sha256.Dispose()
    }
}

#endregion

#region Platform Detection

function Get-SAIsWindows {
    <#
    .SYNOPSIS
        Returns $true if running on Windows (PS 5.1 and 7.x compatible).
    .DESCRIPTION
        Cross-version compatible function to detect Windows platform.
        
        PowerShell version handling:
        - PS 5.1 (Desktop): Always Windows, $IsWindows doesn't exist
        - PS 6+/7.x (Core): Uses automatic $IsWindows variable
        
        Useful for conditional logic around path separators, file permissions,
        and platform-specific tool behavior.
    .EXAMPLE
        if (Get-SAIsWindows) {
            # Windows-specific logic
        }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    # PowerShell 5.1 on Windows doesn't have $IsWindows
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return $true
    }
    
    # PowerShell 7.x
    if ($null -ne $IsWindows) {
        return $IsWindows
    }
    
    # Fallback
    return ($env:OS -eq 'Windows_NT')
}

#endregion

#region Type Conversion

function ConvertTo-SAHashtable {
    <#
    .SYNOPSIS
        Converts a PSCustomObject to a hashtable recursively.
    .DESCRIPTION
        Transforms PSCustomObject (from JSON deserialization or other sources)
        into native PowerShell hashtables. Handles nested objects and arrays.
        
        Useful when:
        - Configuration needs to be modified (PSCustomObjects are read-only)
        - Splatting parameters from JSON config
        - Comparing objects (hashtables have different equality semantics)
    .PARAMETER InputObject
        The object to convert. Accepts pipeline input.
    .EXAMPLE
        $config = Get-Content config.toml -Raw | ConvertFrom-SAToml
    .EXAMPLE
        $obj | ConvertTo-SAHashtable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$InputObject
    )
    
    if ($null -eq $InputObject) {
        return $null
    }
    
    if ($InputObject -is [System.Collections.Hashtable]) {
        return $InputObject
    }
    
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $array = @()
        foreach ($item in $InputObject) {
            $array += ConvertTo-SAHashtable -InputObject $item
        }
        return $array
    }
    
    if ($InputObject -is [PSCustomObject]) {
        $hashtable = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hashtable[$prop.Name] = ConvertTo-SAHashtable -InputObject $prop.Value
        }
        return $hashtable
    }
    
    return $InputObject
}

#endregion

#region Job State Management

function Reset-SAJobState {
    <#
    .SYNOPSIS
        Resets all module-level state between jobs to prevent memory leaks.
    .DESCRIPTION
        In worker mode, the PowerShell process persists across multiple jobs.
        Script-scope variables can accumulate data (especially log entries),
        causing memory growth and potential data leakage between jobs.
        
        Call this function at the START of each job to ensure clean state.
        
        This function resets:
        - Output system state (event collection, job metadata, batch state)
        - Console renderer state (Unicode/color detection cache)
        - File log renderer state (log file path and buffer)
        - Email renderer state (summary data and exceptions)
        - Subtitles state (OpenSubtitles token cache - memory only, not disk)
    .EXAMPLE
        Reset-SAJobState
        # Called at the start of each job in worker mode
    .NOTES
        This is the master reset function that coordinates all component resets.
        Individual reset functions are also available if finer control is needed.
    #>
    [CmdletBinding()]
    param()
    
    # Reset output system state (event collection, job metadata, batch state)
    Reset-SAOutputState
    
    # Reset individual renderers
    Reset-SAConsoleRenderer
    Reset-SAFileLogRenderer
    Reset-SAEmailRenderer
    
    # Reset subtitles state (clears in-memory token cache)
    # Note: We keep disk-cached tokens as they're shared across sessions
    Reset-SASubtitlesState
    
    # Note: Intentionally no verbose here - internal state reset is not useful for troubleshooting
}

#endregion
