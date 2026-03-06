#Requires -Version 5.1
<#
.SYNOPSIS
    Display formatting utilities for Stagearr output
.DESCRIPTION
    Provides consistent formatting functions for durations, sizes, timestamps,
    and pluralization throughout the codebase.
    
    Per OUTPUT-STYLE-GUIDE.md:
    - "Use proper pluralization: 1 file, 3 files (never file(s))"
    - "Round appropriately: 2.1 GB not 2,147,483,648 bytes"
    - Duration format: "47 seconds" or "1m 02s"
#>

#region Pluralization

function Get-SAPluralForm {
    <#
    .SYNOPSIS
        Returns the singular or plural form of a word based on count.
    .DESCRIPTION
        Provides consistent pluralization throughout the codebase.
        Per OUTPUT-STYLE-GUIDE: "Use proper pluralization: 1 file, 3 files (never file(s))"
    .PARAMETER Count
        The count to check.
    .PARAMETER Singular
        The singular form of the word.
    .PARAMETER Plural
        The plural form (optional - defaults to adding 's' to singular).
    .EXAMPLE
        Get-SAPluralForm -Count 1 -Singular 'file'
        # Returns: 'file'
    .EXAMPLE
        Get-SAPluralForm -Count 3 -Singular 'file'
        # Returns: 'files'
    .EXAMPLE
        Get-SAPluralForm -Count 2 -Singular 'entry' -Plural 'entries'
        # Returns: 'entries'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Count,
        
        [Parameter(Mandatory = $true)]
        [string]$Singular,
        
        [Parameter()]
        [string]$Plural = $null
    )
    
    if ($null -eq $Plural -or [string]::IsNullOrWhiteSpace($Plural)) {
        $Plural = "${Singular}s"
    }
    
    return $(if ($Count -eq 1) { $Singular } else { $Plural })
}

#endregion

#region Size Formatting

function Format-SASize {
    <#
    .SYNOPSIS
        Formats a byte count into human-readable size string.
    .DESCRIPTION
        Following OUTPUT-STYLE-GUIDE: round appropriately (e.g., "2.1 GB" not "2,147,483,648 bytes").
    .PARAMETER SizeInBytes
        The size in bytes to format.
    .PARAMETER Decimals
        Number of decimal places (default: 1 for cleaner output).
    .EXAMPLE
        Format-SASize -SizeInBytes 1073741824
        # Returns: "1.0 GB"
    .EXAMPLE
        Format-SASize -SizeInBytes 2252341248
        # Returns: "2.1 GB"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$SizeInBytes,
        
        [Parameter()]
        [int]$Decimals = 1
    )
    
    process {
        if ($null -eq $SizeInBytes) {
            return '0 B'
        }
        
        try {
            [double]$bytes = [double]$SizeInBytes
        } catch {
            return '0 B'
        }
        
        if ($bytes -lt 0) { $bytes = 0 }
        
        $sizes = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
        $index = 0
        
        while ($bytes -ge 1024 -and $index -lt ($sizes.Count - 1)) {
            $bytes = $bytes / 1024
            $index++
        }
        
        if ($index -eq 0) {
            return "$([math]::Round($bytes, 0)) $($sizes[$index])"
        }
        
        return "$([math]::Round($bytes, $Decimals)) $($sizes[$index])"
    }
}

#endregion

#region Timestamp Formatting

function Get-SATimestamp {
    <#
    .SYNOPSIS
        Returns the current timestamp in ISO 8601 format.
    .PARAMETER Format
        Custom format string (default: ISO 8601 with Z suffix).
    .EXAMPLE
        Get-SATimestamp
        # Returns: "2024-01-15T10:30:00Z"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Format = 'yyyy-MM-ddTHH:mm:ssZ'
    )
    
    return (Get-Date).ToUniversalTime().ToString($Format)
}

#endregion

#region Duration Formatting

function Format-SADuration {
    <#
    .SYNOPSIS
        Formats a TimeSpan as a human-readable duration.
    .DESCRIPTION
        Per OUTPUT-STYLE-GUIDE.md:
        - Operations < 1 second: "< 1 second"
        - Operations 1-59 seconds: "X seconds" (with proper pluralization)
        - Operations >= 60 seconds: "Xm Ys" (e.g., "1m 05s")
    .PARAMETER Duration
        The TimeSpan to format.
    .EXAMPLE
        Format-SADuration -Duration ([TimeSpan]::FromSeconds(47))
        # Returns: "47 seconds"
    .EXAMPLE
        Format-SADuration -Duration ([TimeSpan]::FromSeconds(125))
        # Returns: "2m 05s"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Duration
    )
    
    if ($Duration.TotalMinutes -ge 1) {
        # Format as "Xm Ys" for durations >= 60 seconds
        $minutes = [math]::Floor($Duration.TotalMinutes)
        $seconds = $Duration.Seconds
        return "${minutes}m $($seconds.ToString('00'))s"
    } elseif ($Duration.TotalSeconds -ge 1) {
        # Format as "X seconds" or "1 second" for durations 1-59 seconds
        $roundedSeconds = [math]::Round($Duration.TotalSeconds)
        $secWord = Get-SAPluralForm -Count $roundedSeconds -Singular 'second'
        return "$roundedSeconds $secWord"
    } else {
        # Format as "< 1 second" for sub-second durations
        return '< 1 second'
    }
}

function ConvertTo-SAHumanDuration {
    <#
    .SYNOPSIS
        Converts various duration formats to human-readable format.
    .DESCRIPTION
        Ensures duration is displayed as "Xm Ys" or "X seconds" 
        regardless of input format (MM:SS, TimeSpan, already formatted, etc.)
        
        Per OUTPUT-STYLE-GUIDE: Duration should use format "47 seconds" or "1m 02s"
    .PARAMETER Duration
        Duration value in various formats:
        - TimeSpan object
        - "MM:SS" string (e.g., "01:02")
        - "HH:MM:SS" string (e.g., "01:02:45")
        - Already formatted string (e.g., "1m 02s", "47 seconds")
        - Total seconds as integer
    .OUTPUTS
        Human-readable duration string
    .EXAMPLE
        ConvertTo-SAHumanDuration -Duration "01:02"
        # Returns: "1m 02s"
    .EXAMPLE
        ConvertTo-SAHumanDuration -Duration 47
        # Returns: "47 seconds"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        $Duration
    )
    
    # Handle null/empty
    if ([string]::IsNullOrWhiteSpace($Duration)) {
        return ''
    }
    
    # If already a TimeSpan, format it
    if ($Duration -is [TimeSpan]) {
        return Format-SADuration -Duration $Duration
    }
    
    # If already in correct format (contains 'm ', 'seconds', or '< 1 second'), return as-is
    $durationStr = $Duration.ToString()
    if ($durationStr -match '\d+m \d+s$' -or $durationStr -match '\d+ seconds?$' -or $durationStr -eq '< 1 second') {
        return $durationStr
    }
    
    # Parse MM:SS or HH:MM:SS format
    if ($durationStr -match '^(\d{1,2}):(\d{2})$') {
        # MM:SS format (e.g., "01:02")
        $minutes = [int]$Matches[1]
        $seconds = [int]$Matches[2]
        $ts = [TimeSpan]::new(0, $minutes, $seconds)
        return Format-SADuration -Duration $ts
    }
    
    if ($durationStr -match '^(\d{1,2}):(\d{2}):(\d{2})$') {
        # HH:MM:SS format (e.g., "01:02:45")
        $hours = [int]$Matches[1]
        $minutes = [int]$Matches[2]
        $seconds = [int]$Matches[3]
        $ts = [TimeSpan]::new($hours, $minutes, $seconds)
        return Format-SADuration -Duration $ts
    }
    
    # Try parsing as total seconds (integer)
    if ($durationStr -match '^\d+$') {
        $totalSeconds = [int]$durationStr
        $ts = [TimeSpan]::FromSeconds($totalSeconds)
        return Format-SADuration -Duration $ts
    }
    
    # Try parsing as a TimeSpan string (e.g., "00:01:02")
    $parsed = [TimeSpan]::Zero
    if ([TimeSpan]::TryParse($durationStr, [ref]$parsed)) {
        return Format-SADuration -Duration $parsed
    }
    
    # Fallback: return as-is if we can't parse it
    return $durationStr
}

#endregion
