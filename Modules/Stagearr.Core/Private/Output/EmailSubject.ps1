#Requires -Version 5.1
<#
.SYNOPSIS
    Email subject line generation.
.DESCRIPTION
    Functions for generating and formatting email subject lines:
    - Template-based subject generation with placeholders
    - Cleanup and truncation for mobile display
    - Placeholder substitution ({name}, {label}, {result}, etc.)
    
    Subject lines follow OUTPUT-STYLE-GUIDE: keep under 50-70 characters,
    verdict-first for failures.
    
    Available placeholders:
    - {result}     : Status prefix (empty for success, "Failed: " or "Skipped: ")
    - {label}      : Download label (Movie, TV, etc.)
    - {name}       : Friendly name (Inception (2010), Stranger Things S05)
    - {resolution} : Screen size (2160p, 1080p)
    - {source}     : Source type (WEB, BluRay, Remux, UHD)
    - {group}      : Release group (NTb, CiNEPHiLES)
    - {service}    : Streaming service abbreviation (NF, AMZN)
    - {hash4}      : First 4 chars of torrent hash
    
    Uses pre-computed display values from Add-SAReleaseDisplayInfo when available
    (SourceDisplay, ServiceDisplay), falling back to display functions if not enriched.
    
    Depends on: MediaDisplay.ps1 (for Get-SASourceDisplayName, Get-SAServiceDisplayName)
#>

#region Preset Templates

function Get-SASubjectPresetTemplate {
    <#
    .SYNOPSIS
        Gets the template string for a preset style name.
    .DESCRIPTION
        Returns the predefined template for common subject styles.
        Unknown presets default to 'detailed'.
        
        Available presets:
        - detailed: Full info with resolution, source, and group
        - quality:  Just name and resolution
        - source:   Name with source and group
        - group:    Name with just release group
        - hash:     Name with torrent hash prefix
        - none:     Just label and name
    .PARAMETER Style
        Preset style name: detailed, quality, source, group, hash, none
    .OUTPUTS
        Template string with placeholders
    .EXAMPLE
        Get-SASubjectPresetTemplate -Style 'detailed'
        # Returns: '{result}{label}: {name} [{resolution} {source}-{group}]'
    .EXAMPLE
        Get-SASubjectPresetTemplate -Style 'none'
        # Returns: '{result}{label}: {name}'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Style
    )
    
    $presets = @{
        'detailed' = '{result}{label}: {name} [{resolution} {source}-{group}]'
        'quality'  = '{result}{label}: {name} [{resolution}]'
        'source'   = '{result}{label}: {name} [{source}-{group}]'
        'group'    = '{result}{label}: {name} [-{group}]'
        'hash'     = '{result}{label}: {name} [{hash4}]'
        'none'     = '{result}{label}: {name}'
    }
    
    $normalizedStyle = $Style.ToLower()
    
    if ($presets.ContainsKey($normalizedStyle)) {
        return $presets[$normalizedStyle]
    }
    
    # Unknown preset: return 'detailed' as default
    return $presets['detailed']
}

#endregion

#region Subject Cleanup

function Format-SAEmailSubjectCleanup {
    <#
    .SYNOPSIS
        Cleans up email subject after placeholder substitution.
    .DESCRIPTION
        Removes artifacts from unfilled placeholders:
        - Unfilled placeholders like {resolution}
        - Empty brackets: [], [ ]
        - Orphaned separators: leading/trailing dashes, colons
        - Multiple spaces
        - Leading/trailing whitespace
    .PARAMETER Subject
        Raw subject string after placeholder substitution
    .OUTPUTS
        Cleaned subject string
    .EXAMPLE
        Format-SAEmailSubjectCleanup -Subject 'Movie: Title [2160p -]'
        # Returns: 'Movie: Title [2160p]'
    .EXAMPLE
        Format-SAEmailSubjectCleanup -Subject 'Movie: Title []'
        # Returns: 'Movie: Title'
    .EXAMPLE
        Format-SAEmailSubjectCleanup -Subject 'Movie: Title [{resolution}]'
        # Returns: 'Movie: Title'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Subject
    )
    
    if ([string]::IsNullOrWhiteSpace($Subject)) {
        return ''
    }
    
    $result = $Subject
    
    # Remove unfilled placeholders (anything like {word})
    $result = $result -replace '\{[^}]+\}', ''
    
    # Remove empty brackets with optional whitespace: [], [ ], [  ]
    $result = $result -replace '\[\s*\]', ''
    
    # Remove orphaned dashes inside brackets: [- ], [ -], [-], [--]
    $result = $result -replace '\[\s*-+\s*\]', ''
    
    # Clean up dashes at start/end of bracket content: [- content] -> [content]
    $result = $result -replace '\[\s*-\s+', '['
    $result = $result -replace '\s+-\s*\]', ']'
    
    # Clean up trailing dash before bracket: [content-] -> [content]
    $result = $result -replace '-\]', ']'
    
    # Remove double dashes: -- -> -
    $result = $result -replace '--+', '-'
    
    # Remove orphaned colon at end: "Label: " with no name -> "Label"
    $result = $result -replace ':\s*$', ''
    
    # Remove colon-space before bracket: "Label: [" -> "Label ["
    $result = $result -replace ':\s+\[', ' ['
    
    # Collapse multiple spaces
    $result = $result -replace '\s+', ' '
    
    # Trim
    return $result.Trim()
}

#endregion

#region Subject Formatting

function Format-SAEmailSubject {
    <#
    .SYNOPSIS
        Formats email subject using template with placeholder substitution.
    .DESCRIPTION
        Processes a template string, replacing placeholders with actual values.
        Supports both preset styles (as template input) and custom templates.
        
        Handles cleanup of artifacts from empty placeholders and truncates
        long subjects while preserving the suffix in brackets.
    .PARAMETER Template
        Template string with placeholders, or preset name (detailed, quality, etc.)
    .PARAMETER Placeholders
        Hashtable of placeholder values
    .PARAMETER MaxLength
        Maximum subject length (default: 70, truncates name if needed)
    .OUTPUTS
        Formatted subject string
    .EXAMPLE
        $ph = @{ label = 'Movie'; name = 'Inception (2010)'; resolution = '2160p'; source = 'UHD'; group = 'GROUP'; result = '' }
        Format-SAEmailSubject -Template 'detailed' -Placeholders $ph
        # Returns: 'Movie: Inception (2010) [2160p UHD-GROUP]'
    .EXAMPLE
        $ph = @{ label = 'Movie'; name = 'Inception (2010)'; result = 'Failed: ' }
        Format-SAEmailSubject -Template 'none' -Placeholders $ph
        # Returns: 'Failed: Movie: Inception (2010)'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Template,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Placeholders,
        
        [Parameter()]
        [int]$MaxLength = 70
    )
    
    # Check if Template is a preset name
    $presetNames = @('detailed', 'quality', 'source', 'group', 'hash', 'none', 'custom')
    $templateToUse = if ($Template.ToLower() -in $presetNames -and $Template.ToLower() -ne 'custom') {
        Get-SASubjectPresetTemplate -Style $Template
    } else {
        $Template
    }
    
    # Build the subject by replacing placeholders
    $result = $templateToUse
    
    foreach ($key in $Placeholders.Keys) {
        $placeholder = "{$key}"
        $value = if ($null -ne $Placeholders[$key]) { $Placeholders[$key].ToString() } else { '' }
        $result = $result -replace [regex]::Escape($placeholder), $value
    }
    
    # Clean up artifacts from empty placeholders
    $result = Format-SAEmailSubjectCleanup -Subject $result
    
    # Truncate if too long (preserve suffix in brackets)
    if ($result.Length -gt $MaxLength) {
        # Try to find the suffix portion (last [...])
        if ($result -match '^(.+?)(\s*\[[^\]]+\])$') {
            $mainPart = $Matches[1]
            $suffix = $Matches[2]

            $availableLength = $MaxLength - $suffix.Length - 3  # -3 for "..."
            if ($availableLength -gt 10) {
                $mainPart = $mainPart.Substring(0, $availableLength) + '...'
                $result = "$mainPart$suffix"
            } else {
                # Suffix too long to preserve - truncate the whole string
                $result = $result.Substring(0, $MaxLength - 3) + '...'
            }
        } else {
            # No suffix, just truncate
            $result = $result.Substring(0, $MaxLength - 3) + '...'
        }
    }
    
    # Final fallback: if result is empty or just whitespace, use name
    if ([string]::IsNullOrWhiteSpace($result) -and $Placeholders.ContainsKey('name')) {
        $result = $Placeholders['name']
    }
    
    return $result
}

#endregion

#region Placeholder Building

function Build-SASubjectPlaceholders {
    <#
    .SYNOPSIS
        Builds placeholder hashtable for email subject template.
    .DESCRIPTION
        Creates a hashtable of all available placeholder values from 
        job metadata and release info. Used as input to Format-SAEmailSubject.
        
        When ReleaseInfo has been enriched by Add-SAReleaseDisplayInfo,
        uses the pre-computed SourceDisplay and ServiceDisplay values
        instead of calling display functions.
    .PARAMETER Name
        Friendly name (e.g., "Inception (2010)")
    .PARAMETER Label
        Download label (e.g., "Movie", "TV")
    .PARAMETER Result
        Job result: Success, Warning, Failed, Skipped
    .PARAMETER ReleaseInfo
        Release info object from Get-SAReleaseInfo (contains ScreenSize, Source, etc.)
        May have been enriched by Add-SAReleaseDisplayInfo with pre-computed display values.
    .PARAMETER TorrentHash
        Torrent hash for fallback identification
    .OUTPUTS
        Hashtable with all placeholder values
    .EXAMPLE
        $info = [PSCustomObject]@{ ScreenSize = '2160p'; SourceDisplay = 'WEB'; ServiceDisplay = 'NF'; ReleaseGroup = 'NTb' }
        Build-SASubjectPlaceholders -Name 'Show S01' -Label 'TV' -Result 'Success' -ReleaseInfo $info
        # Returns: @{ result = ''; label = 'TV'; name = 'Show S01'; resolution = '2160p'; source = 'WEB'; group = 'NTb'; service = 'NF'; hash4 = '' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$Name = '',
        
        [Parameter()]
        [string]$Label = '',
        
        [Parameter()]
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped')]
        [string]$Result = 'Success',
        
        [Parameter()]
        [object]$ReleaseInfo,
        
        [Parameter()]
        [string]$TorrentHash = ''
    )
    
    # Build result prefix (only for failures and skips)
    $resultPrefix = switch ($Result) {
        'Failed'  { 'Failed: ' }
        'Skipped' { 'Skipped: ' }
        default   { '' }
    }
    
    # Extract values from ReleaseInfo
    $resolution = ''
    $source = ''
    $group = ''
    $service = ''
    
    if ($null -ne $ReleaseInfo) {
        # Resolution
        $resolution = if ($ReleaseInfo.ScreenSize) { $ReleaseInfo.ScreenSize } else { '' }
        
        # Source - use pre-computed SourceDisplay if available (from Add-SAReleaseDisplayInfo)
        # Otherwise fall back to calling the display function
        if (-not [string]::IsNullOrWhiteSpace($ReleaseInfo.SourceDisplay)) {
            $source = $ReleaseInfo.SourceDisplay
        } else {
            $source = Get-SASourceDisplayName -Source $ReleaseInfo.Source -Other $ReleaseInfo.Other
        }
        
        # Release group
        $group = if ($ReleaseInfo.ReleaseGroup) { $ReleaseInfo.ReleaseGroup } else { '' }
        
        # Streaming service - use pre-computed ServiceDisplay if available (from Add-SAReleaseDisplayInfo)
        # Otherwise fall back to calling the display function
        if (-not [string]::IsNullOrWhiteSpace($ReleaseInfo.ServiceDisplay)) {
            $service = $ReleaseInfo.ServiceDisplay
        } else {
            $service = Get-SAServiceDisplayName -StreamingService $ReleaseInfo.StreamingService
        }
    }
    
    # Build hash4 (first 4 chars of torrent hash, lowercase)
    $hash4 = ''
    if (-not [string]::IsNullOrWhiteSpace($TorrentHash)) {
        $hash4 = $TorrentHash.Substring(0, [Math]::Min(4, $TorrentHash.Length)).ToLower()
    }
    
    return @{
        result     = $resultPrefix
        label      = $Label
        name       = $Name
        resolution = $resolution
        source     = $source
        group      = $group
        service    = $service
        hash4      = $hash4
    }
}

#endregion

#region Main Subject Generator

function Get-SAEmailSubject {
    <#
    .SYNOPSIS
        Generates the email subject line using template.
    .DESCRIPTION
        Uses the configured subject style (preset or custom template) to generate
        the email subject. Reads values from the email summary state.
        
        This is the main entry point for subject generation, called by
        ConvertTo-SAEmailHtml or Notification functions.
    .PARAMETER Result
        Job result: Success, Warning, Failed, Skipped
    .PARAMETER SubjectStyle
        Style name (detailed, quality, etc.) or 'custom'
    .PARAMETER SubjectTemplate
        Custom template string (used when SubjectStyle is 'custom')
    .OUTPUTS
        Formatted subject line string
    .EXAMPLE
        Get-SAEmailSubject -Result 'Success' -SubjectStyle 'detailed'
        # Uses email summary state to generate: 'Movie: Inception (2010) [2160p BluRay-GROUP]'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped')]
        [string]$Result = 'Success',
        
        [Parameter()]
        [string]$SubjectStyle = 'detailed',
        
        [Parameter()]
        [string]$SubjectTemplate = ''
    )
    
    # Get values from email summary state
    $name = $script:SAEmailSummary.Name
    $label = $script:SAEmailSummary.Label
    $releaseInfo = $script:SAEmailSummary.ReleaseInfo
    $torrentHash = $script:SAEmailSummary.TorrentHash
    
    # Build placeholder hashtable
    $placeholders = Build-SASubjectPlaceholders -Name $name `
                                                 -Label $label `
                                                 -Result $Result `
                                                 -ReleaseInfo $releaseInfo `
                                                 -TorrentHash $torrentHash
    
    # Determine which template to use
    $template = if ($SubjectStyle.ToLower() -eq 'custom' -and -not [string]::IsNullOrWhiteSpace($SubjectTemplate)) {
        $SubjectTemplate
    } else {
        $SubjectStyle  # Will be expanded by Format-SAEmailSubject
    }
    
    # Format and return
    return Format-SAEmailSubject -Template $template -Placeholders $placeholders
}

#endregion
