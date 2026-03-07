#Requires -Version 5.1
<#
.SYNOPSIS
    Console renderer for Stagearr output events
.DESCRIPTION
    Renders output events to the console with:
    - Timestamps
    - Status markers (✓/!/✗ or ASCII fallback)
    - Color coding
    - Section headers with visual separators
    - Batch progress indicators [n/N]
    
    Supports modes: Default, Verbose, Quiet, NoColor, Ascii
    
    INDENTATION SCHEME (per OUTPUT-STYLE-GUIDE.md):
    
    | Level | Spaces | Usage                                    | Example                    |
    |-------|--------|------------------------------------------|----------------------------|
    | 0     | 0      | Job-level outcomes only                  | ✓ Job: Completed           |
    | 0.5   | 2      | Phase headers                            |   ─── Staging ───          |
    | 1     | 4      | Source lines, phase outcomes             |     Source: file.mkv       |
    | 2     | 8      | File details, per-file outcomes          |         Tracks: 1 video    |
    
    MARKER ALIGNMENT:
    Markers replace leading spaces to keep label alignment consistent.
    - Progress level 1: 4 spaces before label
    - Outcome level 1:  marker + 3 spaces = 4 chars before label
    - Progress level 2: 8 spaces before label  
    - Outcome level 2:  marker + 7 spaces = 8 chars before label
#>

#region Module State

$script:SAConsoleSettings = @{
    UseUnicode    = $null   # Auto-detected or forced
    UseColors     = $true
    VerboseMode   = $false
    QuietMode     = $false
    Initialized   = $false
}

#endregion

#region Initialization

function Initialize-SAConsoleRenderer {
    <#
    .SYNOPSIS
        Initializes console renderer settings.
    .DESCRIPTION
        Detects Unicode support and sets up color preferences.
        Called automatically by Initialize-SAOutputSystem.
    .PARAMETER UseColors
        Enable/disable colored output.
    .PARAMETER ForceAscii
        Force ASCII markers even if Unicode is supported.
    .PARAMETER QuietMode
        Only show outcomes and actionable warnings/errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [bool]$UseColors = $true,
        
        [Parameter()]
        [switch]$ForceAscii,

        [Parameter()]
        [bool]$VerboseMode = $script:SAConsoleSettings.VerboseMode,

        [Parameter()]
        [switch]$QuietMode
    )

    $script:SAConsoleSettings.UseColors = $UseColors
    $script:SAConsoleSettings.QuietMode = $QuietMode.IsPresent
    $script:SAConsoleSettings.VerboseMode = $VerboseMode
    
    if ($ForceAscii) {
        $script:SAConsoleSettings.UseUnicode = $false
    } else {
        # Detect Unicode support
        $script:SAConsoleSettings.UseUnicode = Test-SAConsoleUnicodeSupport
    }
    
    $script:SAConsoleSettings.Initialized = $true
}

function Test-SAConsoleUnicodeSupport {
    <#
    .SYNOPSIS
        Detects if console supports Unicode output.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    # Default to Unicode support
    $supportsUnicode = $true
    
    if (Get-SAIsWindows) {
        # Check for Windows Terminal or known good terminals
        if ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode') {
            $supportsUnicode = $true
        } elseif ($Host.Name -eq 'ConsoleHost') {
            # Try to set UTF-8 encoding for proper Unicode support
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                $supportsUnicode = $true
            } catch {
                $supportsUnicode = $false
            }
        } else {
            # ISE or other hosts - safer to use ASCII
            $supportsUnicode = $false
        }
    }
    
    return $supportsUnicode
}

function Reset-SAConsoleRenderer {
    <#
    .SYNOPSIS
        Resets console renderer state.
    #>
    [CmdletBinding()]
    param()
    
    $script:SAConsoleSettings = @{
        UseUnicode    = $null
        UseColors     = $true
        VerboseMode   = $false
        QuietMode     = $false
        Initialized   = $false
    }
}

#endregion

#region Markers and Formatting

function Get-SAConsoleMarker {
    <#
    .SYNOPSIS
        Returns the appropriate marker symbol for an event level.
    .DESCRIPTION
        Unicode markers are 1 character wide.
        ASCII markers are 4 characters wide: [OK], [!!], [XX], [--]
    .PARAMETER Level
        Event level: Success, Warning, Error, Skip, Info, Verbose
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Error', 'Skip', 'Info', 'Verbose')]
        [string]$Level
    )
    
    # Ensure initialized
    if (-not $script:SAConsoleSettings.Initialized) {
        Initialize-SAConsoleRenderer
    }
    
    if ($script:SAConsoleSettings.UseUnicode) {
        switch ($Level) {
            'Success' { return [char]0x2713 }  # ✓
            'Warning' { return '!' }
            'Error'   { return [char]0x2717 }  # ✗
            'Skip'    { return [char]0x21B7 }  # ↷
            'Info'    { return ' ' }
            'Verbose' { return ' ' }
        }
    } else {
        switch ($Level) {
            'Success' { return '[OK]' }
            'Warning' { return '[!!]' }
            'Error'   { return '[XX]' }
            'Skip'    { return '[--]' }
            'Info'    { return '    ' }
            'Verbose' { return '    ' }
        }
    }
}

function Get-SAConsoleMarkerWidth {
    <#
    .SYNOPSIS
        Returns the character width of markers in current mode.
    .DESCRIPTION
        Unicode markers are 1 character.
        ASCII markers are 4 characters.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    
    if (-not $script:SAConsoleSettings.Initialized) {
        Initialize-SAConsoleRenderer
    }
    
    if ($script:SAConsoleSettings.UseUnicode) {
        return 1
    } else {
        return 4
    }
}

function Get-SAConsoleColor {
    <#
    .SYNOPSIS
        Returns the console color for an event level.
    .PARAMETER Level
        Event level
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Level
    )
    
    switch ($Level) {
        'Success' { return 'DarkGreen' }
        'Warning' { return 'DarkYellow' }
        'Error'   { return 'DarkRed' }
        'Skip'    { return 'DarkGray' }
        'Info'    { return 'Gray' }
        'Verbose' { return 'DarkGray' }
        default   { return 'Gray' }
    }
}

function Get-SAConsoleDashChar {
    <#
    .SYNOPSIS
        Returns the dash character for headers.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    
    if (-not $script:SAConsoleSettings.Initialized) {
        Initialize-SAConsoleRenderer
    }
    
    if ($script:SAConsoleSettings.UseUnicode) {
        return [string][char]0x2500  # ─
    } else {
        return '-'
    }
}

function Get-SAConsoleIndent {
    <#
    .SYNOPSIS
        Returns the indent string for progress lines at a given level.
    .DESCRIPTION
        Per OUTPUT-STYLE-GUIDE.md indentation hierarchy:
        
        | Level | Spaces | Usage                                    |
        |-------|--------|------------------------------------------|
        | 0     | 0      | Not used for progress (job outcomes)     |
        | 1     | 4      | Source: lines, phase-level progress      |
        | 2     | 8      | File details (tracks, extraction info)   |
        
        This scheme applies identically to single-file and batch modes.
        
        NOTE: For outcomes with markers, use Get-SAConsoleOutcomePrefix instead.
    .PARAMETER Level
        Indentation level (0-2)
    .OUTPUTS
        Indent string (spaces)
    .LINK
        See OUTPUT-STYLE-GUIDE.md section "Indentation Hierarchy"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateRange(0, 2)]
        [int]$Level = 0
    )
    
    switch ($Level) {
        0 { return '' }              # 0 spaces - job-level (not for progress)
        1 { return '    ' }          # 4 spaces - Source: lines, phase progress
        2 { return '        ' }      # 8 spaces - file details (tracks, extraction)
        default { return '' }
    }
}

function Get-SAConsoleOutcomePrefix {
    <#
    .SYNOPSIS
        Returns the marker + padding string for outcome lines.
    .DESCRIPTION
        Calculates the appropriate spacing after the marker to align
        the label with progress lines at the same indent level.
        
        | Level | Progress Indent | Outcome Prefix (Unicode)      | Outcome Prefix (ASCII)        |
        |-------|-----------------|-------------------------------|-------------------------------|
        | 0     | N/A             | marker + 1 space              | marker + 1 space              |
        | 1     | 4 spaces        | marker + 3 spaces (=4 total)  | marker + 0 spaces (=4 total)  |
        | 2     | 8 spaces        | marker + 7 spaces (=8 total)  | marker + 4 spaces (=8 total)  |
        
        For ASCII mode (4-char markers), we subtract marker width from spacing.
    .PARAMETER Level
        Indentation level: Success, Warning, Error, Skip
    .PARAMETER MarkerLevel
        Event level for marker selection
    .OUTPUTS
        String containing marker followed by appropriate spacing
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 2)]
        [int]$Level,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Error', 'Skip')]
        [string]$MarkerLevel
    )
    
    $marker = Get-SAConsoleMarker -Level $MarkerLevel
    $markerWidth = Get-SAConsoleMarkerWidth
    
    # Target indent widths (how many chars before label starts)
    # Level 0: 2 chars (marker + 1 space minimum for readability)
    # Level 1: 4 chars (aligns with 4-space progress indent)
    # Level 2: 8 chars (aligns with 8-space progress indent)
    
    $targetWidth = switch ($Level) {
        0 { 2 }   # Job outcomes: marker + 1 space minimum
        1 { 4 }   # Phase outcomes: align with 4-space progress
        2 { 8 }   # Detail outcomes: align with 8-space progress
    }
    
    # Calculate padding needed after marker
    $paddingNeeded = [Math]::Max(1, $targetWidth - $markerWidth)
    $padding = ' ' * $paddingNeeded
    
    return "$marker$padding"
}

function Format-SAConsoleTimestamp {
    <#
    .SYNOPSIS
        Formats a timestamp for console output.
    .PARAMETER Time
        DateTime to format (default: now)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [DateTime]$Time = (Get-Date)
    )
    
    return "[$($Time.ToString('HH:mm:ss'))]"
}

#endregion

#region Event Rendering

function Write-SAConsoleEvent {
    <#
    .SYNOPSIS
        Renders a single event to the console.
    .DESCRIPTION
        Main rendering function called by the event dispatcher.
        Formats the event according to its type and console settings.
    .PARAMETER Event
        The event object to render
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    # Ensure initialized
    if (-not $script:SAConsoleSettings.Initialized) {
        Initialize-SAConsoleRenderer
    }
    
    # Handle verbose events - use PowerShell's native verbose stream
    if ($Event.Level -eq 'Verbose') {
        Write-SAConsoleVerbose -Event $Event
        return
    }
    
    # In quiet mode, only show outcomes and warnings/errors
    if ($script:SAConsoleSettings.QuietMode) {
        if (-not $Event.IsOutcome -and $Event.Level -notin @('Warning', 'Error')) {
            if (-not $Event.IsHeader) {
                return
            }
        }
    }
    
    # Dispatch to appropriate renderer
    if ($Event.IsHeader) {
        Write-SAConsoleHeader -Event $Event
    } elseif ($Event.IsOutcome) {
        Write-SAConsoleOutcome -Event $Event
    } elseif ($Event.Details -and $Event.Details['_EventType'] -eq 'KeyValue') {
        Write-SAConsoleKeyValue -Event $Event
    } else {
        Write-SAConsoleProgress -Event $Event
    }
}

function Write-SAConsoleHeader {
    <#
    .SYNOPSIS
        Renders a section header to console.
    .DESCRIPTION
        Headers are rendered at indent level 0.5 (2 spaces) to visually
        separate them from job-level outcomes while maintaining hierarchy.
        
        Format: [HH:mm:ss]   ─── Title ───────────────────
                          ^^
                          2 spaces (level 0.5)
    .PARAMETER Event
        Header event
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    $timestamp = Format-SAConsoleTimestamp -Time $Event.Timestamp
    $dashChar = Get-SAConsoleDashChar
    $title = $Event.Text
    
    # Level 0.5: 2 spaces before dash line
    $headerIndent = '  '
    
    # Calculate padding for consistent visual alignment
    # Target total width (after timestamp + space): ~45 chars
    $headerWidth = 43  # Reduced by 2 to account for header indent
    $titleWithSpaces = " $title "
    $remainingWidth = $headerWidth - $titleWithSpaces.Length
    $leftDashes = 3
    $rightDashes = [Math]::Max(3, $remainingWidth - $leftDashes)
    
    $dashLine = "$($dashChar * $leftDashes)$titleWithSpaces$($dashChar * $rightDashes)"
    $line = "$timestamp$headerIndent$dashLine"
    
    if ($script:SAConsoleSettings.UseColors) {
        Write-Host $line -ForegroundColor DarkCyan
    } else {
        Write-Host $line
    }
}

function Write-SAConsoleOutcome {
    <#
    .SYNOPSIS
        Renders an outcome event with status marker.
    .DESCRIPTION
        Outcomes use marker + padding to align labels with progress lines.
        
        Level 0 (job):    [HH:mm:ss] ✓ Job: Completed
        Level 1 (phase):  [HH:mm:ss] ✓   Staging: 8 files ready
        Level 2 (detail): [HH:mm:ss] ✓       Extracted: Dutch
                                     ↑^^^    ↑
                                     marker  label (aligns with progress)
    .PARAMETER Event
        Outcome event
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    $timestamp = Format-SAConsoleTimestamp -Time $Event.Timestamp
    $color = Get-SAConsoleColor -Level $Event.Level
    
    # Determine indent level from event details
    $indentLevel = 0
    if ($Event.Details -and $Event.Details.ContainsKey('_Indent')) {
        $indentLevel = [Math]::Min(2, [Math]::Max(0, [int]$Event.Details['_Indent']))
    }
    
    # Get the marker + padding prefix for alignment
    $prefix = Get-SAConsoleOutcomePrefix -Level $indentLevel -MarkerLevel $Event.Level
    
    # Build message with optional batch prefix and duration
    $message = Format-SAConsoleMessage -Event $Event
    
    # Build the line
    $line = if ([string]::IsNullOrWhiteSpace($Event.Label)) {
        "$timestamp $prefix$message"
    } else {
        "$timestamp $prefix$($Event.Label): $message"
    }
    
    if ($script:SAConsoleSettings.UseColors) {
        Write-Host $line -ForegroundColor $color
    } else {
        Write-Host $line
    }
}

function Write-SAConsoleProgress {
    <#
    .SYNOPSIS
        Renders a progress/info event (no marker).
    .DESCRIPTION
        Progress lines use fixed-width indentation.
        
        Level 1: [HH:mm:ss]     Source: file.mkv (4.2 GB)
        Level 2: [HH:mm:ss]         Tracks: 1 video, 2 audio
                           ^^^^    ^^^^^^^^
                           4 spaces 8 spaces
    .PARAMETER Event
        Progress event
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    $timestamp = Format-SAConsoleTimestamp -Time $Event.Timestamp
    
    # Determine indent level from event details
    $indentLevel = 1  # Default for progress
    if ($Event.Details -and $Event.Details.ContainsKey('_Indent')) {
        $indentLevel = [Math]::Min(2, [Math]::Max(0, [int]$Event.Details['_Indent']))
    }
    
    # Get the indent string for this level
    $indent = Get-SAConsoleIndent -Level $indentLevel
    
    # Build message with optional batch prefix
    $message = Format-SAConsoleMessage -Event $Event
    
    # Build the line (no marker for progress, just indent)
    $line = if ([string]::IsNullOrWhiteSpace($Event.Label)) {
        "$timestamp $indent$message"
    } else {
        "$timestamp $indent$($Event.Label): $message"
    }
    
    if ($script:SAConsoleSettings.UseColors) {
        Write-Host $line -ForegroundColor Gray
    } else {
        Write-Host $line
    }
}

function Write-SAConsoleKeyValue {
    <#
    .SYNOPSIS
        Renders a key-value pair with special formatting.
    .DESCRIPTION
        Key-value pairs have the key in a muted color with fixed-width padding,
        and the value in normal color. Used for status displays.
        
        Format: [HH:mm:ss]     Key:        Value
                           ^^^^           ^^^^
                           indent         padded key
    .PARAMETER Event
        KeyValue event with Details containing _KeyWidth
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    $timestamp = Format-SAConsoleTimestamp -Time $Event.Timestamp
    $indent = Get-SAConsoleIndent -Level 1  # 4 spaces
    
    # Get key width from event details, default to 12
    $keyWidth = 12
    if ($Event.Details -and $Event.Details.ContainsKey('_KeyWidth')) {
        $keyWidth = $Event.Details['_KeyWidth']
    }
    
    $paddedKey = "$($Event.Label):".PadRight($keyWidth)
    
    if ($script:SAConsoleSettings.UseColors) {
        Write-Host "$timestamp $indent" -NoNewline
        Write-Host $paddedKey -ForegroundColor DarkGray -NoNewline
        Write-Host $Event.Text
    } else {
        Write-Host "$timestamp $indent$paddedKey $($Event.Text)"
    }
}

function Write-SAConsoleVerbose {
    <#
    .SYNOPSIS
        Renders a verbose event to console when VerboseMode is enabled.
    .PARAMETER Event
        Verbose event
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )

    if (-not $script:SAConsoleSettings.VerboseMode) {
        return
    }

    $timestamp = Format-SAConsoleTimestamp -Time $Event.Timestamp

    # Format: "Label: Message" or just "Message"
    $message = if ([string]::IsNullOrWhiteSpace($Event.Label)) {
        $Event.Text
    } else {
        "$($Event.Label): $($Event.Text)"
    }

    $line = "$timestamp     $message"

    if ($script:SAConsoleSettings.UseColors) {
        Write-Host $line -ForegroundColor DarkGray
    } else {
        Write-Host $line
    }
}

function Format-SAConsoleMessage {
    <#
    .SYNOPSIS
        Formats an event message with optional batch prefix and duration.
    .PARAMETER Event
        Event to format
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    $parts = @()
    
    # Add main text first
    if (-not [string]::IsNullOrWhiteSpace($Event.Text)) {
        $parts += $Event.Text
    }
    
    # Add batch suffix if present (format: [n/N])
    if ($null -ne $Event.BatchIndex -and $null -ne $Event.BatchTotal) {
        $parts += "[$($Event.BatchIndex)/$($Event.BatchTotal)]"
    }
    
    # Add duration if present
    if ($null -ne $Event.Duration -and $Event.Duration -gt 0) {
        $parts += "($($Event.Duration)s)"
    }
    
    return ($parts -join ' ')
}

#endregion

#region Banner and Special Output

function Write-SABanner {
    <#
    .SYNOPSIS
        Writes the Stagearr banner/title.
    .PARAMETER Title
        Title text (default: "Stagearr")
    .PARAMETER Version
        Optional version string
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Title = 'Stagearr',
        
        [Parameter()]
        [string]$Version
    )
    
    if (-not $script:SAConsoleSettings.Initialized) {
        Initialize-SAConsoleRenderer
    }
    
    $displayText = $Title
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $displayText = "$Title v$Version"
    }
    
    Write-Host ''
    if ($script:SAConsoleSettings.UseColors) {
        Write-Host $displayText -ForegroundColor DarkYellow
    } else {
        Write-Host $displayText
    }
    Write-Host ''
}

function Write-SAKeyValue {
    <#
    .SYNOPSIS
        Writes a key-value pair with consistent formatting.
    .DESCRIPTION
        Used for job info display (Path, Label) at the start of processing.
        Uses level 1 indent (4 spaces) to align with Source: lines.
    .PARAMETER Key
        The key/label
    .PARAMETER Value
        The value to display
    .PARAMETER KeyWidth
        Width for the key column (default: 12)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,
        
        [Parameter()]
        [int]$KeyWidth = 12
    )
    
    # Emit event - console renderer handles the special key-value formatting
    Write-SAEvent -Level Info -Label $Key -Text $Value -EmailExclude -Details @{ 
        '_EventType' = 'KeyValue'
        '_KeyWidth' = $KeyWidth
        '_Indent' = 1
    }
}

#endregion