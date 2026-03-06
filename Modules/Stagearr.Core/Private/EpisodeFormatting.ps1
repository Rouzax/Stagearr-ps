#Requires -Version 5.1
<#
.SYNOPSIS
    Episode number formatting and grouping utilities.
.DESCRIPTION
    Functions for formatting episode information in console and email output:
    - Group consecutive episodes into ranges (E01, E02, E03 → E01-E03)
    - Format episode lists compactly
    - Format episode outcomes for display
    
    These functions follow OUTPUT-STYLE-GUIDE principles:
    - ≤3 episodes: Show inline (e.g., "S02E01-E03")
    - >3 episodes: Show count (e.g., "6 files")
    
    All functions are pure with no side effects - input → output only.
    
    Used by: ImportMedusa.ps1, JobProcessor.ps1, EmailRenderer.ps1
#>

function Group-SAConsecutiveEpisodes {
    <#
    .SYNOPSIS
        Groups episode numbers into consecutive ranges.
    .DESCRIPTION
        Takes an array of episode numbers and groups consecutive episodes into ranges.
        Non-consecutive episodes are kept separate. This is a pure function with no side effects.
        
        Used by Format-SAEpisodeList to create compact episode displays.
    .PARAMETER Episodes
        Array of episode numbers (integers) to group. Order does not matter.
    .OUTPUTS
        Array of PSCustomObjects with Start and End properties representing ranges.
        Single episodes have Start equal to End.
    .EXAMPLE
        Group-SAConsecutiveEpisodes -Episodes @(1, 2, 3, 7, 8)
        # Returns: @(@{Start=1; End=3}, @{Start=7; End=8})
    .EXAMPLE
        Group-SAConsecutiveEpisodes -Episodes @(1, 3, 5)
        # Returns: @(@{Start=1; End=1}, @{Start=3; End=3}, @{Start=5; End=5})
    .EXAMPLE
        Group-SAConsecutiveEpisodes -Episodes @(5, 3, 1, 2, 4)
        # Returns: @(@{Start=1; End=5}) - input is sorted automatically
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [int[]]$Episodes
    )
    
    # Handle null/empty input
    if ($null -eq $Episodes -or $Episodes.Count -eq 0) {
        return @()
    }
    
    # Sort and remove duplicates
    $sorted = $Episodes | Sort-Object -Unique
    
    # Handle single episode
    if ($sorted.Count -eq 1) {
        return @([PSCustomObject]@{
            Start = $sorted[0]
            End   = $sorted[0]
        })
    }
    
    $ranges = @()
    $rangeStart = $sorted[0]
    $rangeEnd = $sorted[0]
    
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $current = $sorted[$i]
        
        if ($current -eq $rangeEnd + 1) {
            # Consecutive - extend range
            $rangeEnd = $current
        } else {
            # Gap - close current range and start new one
            $ranges += [PSCustomObject]@{
                Start = $rangeStart
                End   = $rangeEnd
            }
            $rangeStart = $current
            $rangeEnd = $current
        }
    }
    
    # Don't forget the last range
    $ranges += [PSCustomObject]@{
        Start = $rangeStart
        End   = $rangeEnd
    }
    
    return $ranges
}

function Format-SAEpisodeRange {
    <#
    .SYNOPSIS
        Formats a single episode range into a string.
    .DESCRIPTION
        Internal helper that formats a single range object (with Start and End properties)
        into a display string like "E01-E03" or "E05".
    .PARAMETER Range
        PSCustomObject with Start and End properties.
    .PARAMETER IncludeSeason
        If specified, includes the season prefix (e.g., "S02E01-E03").
    .PARAMETER Season
        Season number to include (required if IncludeSeason is specified).
    .OUTPUTS
        Formatted string like "E01-E03" or "S02E01-E03".
    .EXAMPLE
        Format-SAEpisodeRange -Range @{Start=1; End=3}
        # Returns: "E01-E03"
    .EXAMPLE
        Format-SAEpisodeRange -Range @{Start=5; End=5}
        # Returns: "E05"
    .EXAMPLE
        Format-SAEpisodeRange -Range @{Start=1; End=3} -IncludeSeason -Season 2
        # Returns: "S02E01-E03"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Range,
        
        [Parameter()]
        [switch]$IncludeSeason,
        
        [Parameter()]
        [int]$Season = 1
    )
    
    $seasonPrefix = if ($IncludeSeason) { "S{0:D2}" -f $Season } else { '' }
    
    if ($Range.Start -eq $Range.End) {
        # Single episode
        return "{0}E{1:D2}" -f $seasonPrefix, $Range.Start
    } else {
        # Range of episodes
        return "{0}E{1:D2}-E{2:D2}" -f $seasonPrefix, $Range.Start, $Range.End
    }
}

function Format-SAEpisodeList {
    <#
    .SYNOPSIS
        Formats a list of episodes into a compact display string.
    .DESCRIPTION
        Takes episode numbers and formats them compactly using ranges where possible.
        Consecutive episodes are collapsed (e.g., E01, E02, E03 becomes E01-E03).
        Non-consecutive episodes are separated by commas.
        
        This is a pure function with no side effects, used for console and email output.
        
        Per OUTPUT-STYLE-GUIDE: Format episode ranges like "S02E01-E03, S02E07"
    .PARAMETER Season
        The season number to include in output.
    .PARAMETER Episodes
        Array of episode numbers (integers). Order does not matter.
    .OUTPUTS
        Formatted string like "S02E01-E03, S02E07-E08" or "S02E05".
    .EXAMPLE
        Format-SAEpisodeList -Season 2 -Episodes @(1, 2, 3, 7, 8)
        # Returns: "S02E01-E03, S02E07-E08"
    .EXAMPLE
        Format-SAEpisodeList -Season 1 -Episodes @(5)
        # Returns: "S01E05"
    .EXAMPLE
        Format-SAEpisodeList -Season 2 -Episodes @(1, 3, 5)
        # Returns: "S02E01, S02E03, S02E05"
    .EXAMPLE
        Format-SAEpisodeList -Season 2 -Episodes @(1, 2, 3, 4, 5, 6, 7, 8)
        # Returns: "S02E01-E08"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Season,
        
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [int[]]$Episodes
    )
    
    # Handle null/empty input
    if ($null -eq $Episodes -or $Episodes.Count -eq 0) {
        return ''
    }
    
    # Group into ranges
    $ranges = Group-SAConsecutiveEpisodes -Episodes $Episodes
    
    if ($ranges.Count -eq 0) {
        return ''
    }
    
    # Format each range with season prefix
    $formattedRanges = $ranges | ForEach-Object {
        Format-SAEpisodeRange -Range $_ -IncludeSeason -Season $Season
    }
    
    # Join with comma separator
    return $formattedRanges -join ', '
}

function Format-SAEpisodeOutcome {
    <#
    .SYNOPSIS
        Formats an episode outcome for display in console/email output.
    .DESCRIPTION
        Creates a formatted string describing what happened to episodes during import.
        Handles single episodes, ranges, and larger batches appropriately.
        
        For small batches (1-3 episodes), shows episode identifiers inline.
        For larger batches or non-consecutive episodes, just shows the count.
        
        This is a pure function with no side effects.
        
        Per OUTPUT-STYLE-GUIDE:
        - ≤3 episodes: Show inline (e.g., "Imported S02E08" or "Skipped S02E01-E03")
        - >3 episodes: Show count (e.g., "Skipped 6 files")
    .PARAMETER Season
        The season number.
    .PARAMETER Episodes
        Array of episode numbers that had this outcome.
    .PARAMETER Action
        The action that occurred: 'Imported', 'Skipped', or 'Aborted'.
    .PARAMETER Reason
        Optional reason text for skipped/aborted episodes.
    .PARAMETER MaxInlineEpisodes
        Maximum number of episodes to show inline (default: 3).
        Above this count, shows "N files" instead.
    .OUTPUTS
        Formatted string like "Imported S02E07" or "Skipped 6 files (quality exists)".
    .EXAMPLE
        Format-SAEpisodeOutcome -Season 2 -Episodes @(7) -Action 'Imported'
        # Returns: "Imported S02E07"
    .EXAMPLE
        Format-SAEpisodeOutcome -Season 2 -Episodes @(1, 2, 3) -Action 'Skipped' -Reason 'Quality exists'
        # Returns: "Skipped S02E01-E03 (Quality exists)"
    .EXAMPLE
        Format-SAEpisodeOutcome -Season 2 -Episodes @(1, 2, 3, 4, 5, 6) -Action 'Skipped' -Reason 'Quality exists'
        # Returns: "Skipped 6 files (Quality exists)"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Season,
        
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [int[]]$Episodes,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Imported', 'Skipped', 'Aborted')]
        [string]$Action,
        
        [Parameter()]
        [string]$Reason = '',
        
        [Parameter()]
        [int]$MaxInlineEpisodes = 3
    )
    
    # Handle null/empty episodes
    if ($null -eq $Episodes -or $Episodes.Count -eq 0) {
        return ''
    }
    
    $count = $Episodes.Count
    
    # Determine if we should show episode identifiers or just count
    # Show episodes inline if: count <= MaxInlineEpisodes
    $showInline = $count -le $MaxInlineEpisodes
    
    if ($showInline) {
        # Format as episode list
        $episodeText = Format-SAEpisodeList -Season $Season -Episodes $Episodes
        $result = "$Action $episodeText"
    } else {
        # Format as count
        $fileWord = Get-SAPluralForm -Count $count -Singular 'file'
        $result = "$Action $count $fileWord"
    }
    
    # Add reason if provided
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $result = "$result ($Reason)"
    }
    
    return $result
}
