#Requires -Version 5.1
<#
.SYNOPSIS
    Email display helper functions.
.DESCRIPTION
    Utility functions for generating email content:
    - HTML escaping
    - Display name formatting (files, subtitles, import status)
    - Source and service name resolution
    - Color palette definition
    
    These are stateless helpers used by EmailSections, EmailSubject, and EmailRenderer.
    
    Color palette is defined here to avoid load-order dependencies between
    EmailRenderer and EmailSections.
#>

#region Color Palette (Style Guide)

# Email color palette following OUTPUT-STYLE-GUIDE
# Defined in EmailHelpers.ps1 for early availability to all email modules
$script:SAEmailColors = @{
    # Backgrounds
    BackgroundDark   = '#0f172a'   # Main background
    BackgroundCard   = '#1e293b'   # Card background
    
    # Status badge colors
    SuccessGreen     = '#22c55e'
    WarningAmber     = '#f59e0b'
    FailedRed        = '#ef4444'
    SkippedGray      = '#6b7280'
    
    # Text colors
    TextPrimary      = '#f8fafc'
    TextSecondary    = '#94a3b8'
    TextMuted        = '#64748b'
    TextNote         = '#cbd5e1'
    
    # Accent colors
    AccentSlate      = '#475569'
    BorderColor      = '#334155'
    
    # Error text
    ErrorLight       = '#fca5a5'
    
    # OMDb rating colors (brand colors)
    ImdbYellow       = '#f5c518'    # IMDb brand yellow (for star)
    TomatoRed        = '#fa320a'    # Rotten Tomatoes red
    MetacriticGreen  = '#66cc33'    # Metacritic green
    
    # OMDb link color
    LinkBlue         = '#60a5fa'    # Blue for IMDb link
}

#endregion

#region HTML Escaping

function ConvertTo-SAHtmlSafe {
    <#
    .SYNOPSIS
        HTML-encodes a string for safe rendering.
    .DESCRIPTION
        Escapes HTML special characters to prevent XSS and rendering issues.
        Handles null and empty strings gracefully.
    .PARAMETER Text
        Text to escape
    .OUTPUTS
        HTML-safe string
    .EXAMPLE
        ConvertTo-SAHtmlSafe -Text '<script>alert("xss")</script>'
        # Returns: '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text
    )
    
    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    
    return $Text.Replace('&', '&amp;').
                 Replace('<', '&lt;').
                 Replace('>', '&gt;').
                 Replace('"', '&quot;').
                 Replace("'", '&#39;')
}

#endregion

#region Display Formatters

function Get-SAEmailQualityDisplay {
    <#
    .SYNOPSIS
        Gets the pre-computed quality display string for email.
    .DESCRIPTION
        Returns the QualityDisplay property from ReleaseInfo, which was
        pre-computed by Add-SAReleaseDisplayInfo in JobProcessor.
        
        Returns empty string if ReleaseInfo is null (passthrough mode)
        or if QualityDisplay is not available.
    .PARAMETER Summary
        Email summary hashtable containing ReleaseInfo with QualityDisplay property
    .OUTPUTS
        Quality display string (e.g., "2160p WEB • Dolby Vision") or empty string
    .EXAMPLE
        Get-SAEmailQualityDisplay -Summary @{ ReleaseInfo = @{ QualityDisplay = '2160p WEB • Dolby Vision' } }
        # Returns: '2160p WEB • Dolby Vision'
    .EXAMPLE
        Get-SAEmailQualityDisplay -Summary @{ ReleaseInfo = $null }
        # Returns: '' (passthrough mode)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    # Handle null ReleaseInfo (passthrough mode)
    if ($null -eq $Summary.ReleaseInfo) {
        return ''
    }
    
    # Return pre-computed quality display value
    if (-not [string]::IsNullOrWhiteSpace($Summary.ReleaseInfo.QualityDisplay)) {
        return $Summary.ReleaseInfo.QualityDisplay
    }
    
    return ''
}

function Get-SAEmailFilesDisplay {
    <#
    .SYNOPSIS
        Formats files info for email display.
    .DESCRIPTION
        Creates a human-readable string showing file count and total size.
        Uses appropriate terminology (video/episodes/files) based on context.
    .PARAMETER Summary
        Email summary hashtable containing VideoCount, VideoSize, IsPassthrough
    .OUTPUTS
        Formatted string like "1 video (4.2 GB)" or "8 episodes (6.5 GB)"
    .EXAMPLE
        Get-SAEmailFilesDisplay -Summary @{ VideoCount = 8; VideoSize = '6.5 GB'; IsPassthrough = $false }
        # Returns: '8 episodes (6.5 GB)'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    if ($Summary.VideoCount -le 0) {
        return ''
    }
    
    # Build description based on count and type
    $fileWord = Get-SAPluralForm -Count $Summary.VideoCount -Singular 'video' -Plural 'episodes'
    if ($Summary.IsPassthrough) {
        $fileWord = Get-SAPluralForm -Count $Summary.VideoCount -Singular 'file'
    }
    
    $display = "$($Summary.VideoCount) $fileWord"
    
    if (-not [string]::IsNullOrWhiteSpace($Summary.VideoSize)) {
        $display += " ($($Summary.VideoSize))"
    }
    
    return $display
}

function Get-SAEmailSubtitleDisplay {
    <#
    .SYNOPSIS
        Formats subtitle info for email display.
    .DESCRIPTION
        Creates a human-readable string showing present and missing languages.
        Missing languages are shown in parentheses as "unavailable".
    .PARAMETER Summary
        Email summary hashtable containing Subtitles and MissingLangs arrays
    .OUTPUTS
        Formatted string like "English, Dutch" or "English (unavailable: Dutch)"
    .EXAMPLE
        Get-SAEmailSubtitleDisplay -Summary @{ Subtitles = @('English'); MissingLangs = @('Dutch') }
        # Returns: 'English (unavailable: Dutch)'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $parts = @()
    
    # Present languages
    if ($Summary.Subtitles -and $Summary.Subtitles.Count -gt 0) {
        $parts += ($Summary.Subtitles | Sort-Object) -join ', '
    }
    
    # Missing languages
    if ($Summary.MissingLangs -and $Summary.MissingLangs.Count -gt 0) {
        $missing = ($Summary.MissingLangs | Sort-Object) -join ', '
        if ($parts.Count -gt 0) {
            $parts[0] += " (unavailable: $missing)"
        } else {
            $parts += "Missing: $missing"
        }
    }
    
    return ($parts -join '')
}

function Get-SAEmailImportDisplay {
    <#
    .SYNOPSIS
        Formats import info for email display.
    .DESCRIPTION
        Returns the import result string. For passthrough mode, returns "Files staged".
        The import target is shown in the subtitle, so only the result is returned here.
    .PARAMETER Summary
        Email summary hashtable containing ImportTarget, ImportResult, IsPassthrough
    .OUTPUTS
        Import result string or empty string if no import info available
    .EXAMPLE
        Get-SAEmailImportDisplay -Summary @{ ImportResult = 'Imported to library'; IsPassthrough = $false }
        # Returns: 'Imported to library'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    # Handle passthrough mode
    if ($Summary.IsPassthrough) {
        return 'Files staged'
    }
    
    if ([string]::IsNullOrWhiteSpace($Summary.ImportTarget) -and 
        [string]::IsNullOrWhiteSpace($Summary.ImportResult)) {
        return ''
    }
    
    # Return just the result - target is in subtitle
    if (-not [string]::IsNullOrWhiteSpace($Summary.ImportResult)) {
        return $Summary.ImportResult
    }
    
    return ''
}

#endregion

#region Inline Image Helpers

function Get-SAEmailInlineImages {
    <#
    .SYNOPSIS
        Extracts inline images from OMDb data for email attachments.
    .DESCRIPTION
        Converts OmdbData.PosterData into the InlineImages format expected by Send-SAEmail.
        Returns an empty array if no poster data is available.
        
        The returned array contains hashtables with:
        - Bytes: [byte[]] Raw image data
        - MimeType: [string] MIME type (e.g., 'image/jpeg')
        - ContentId: [string] Content-ID for cid: references in HTML
    .PARAMETER OmdbData
        OMDb data hashtable from Get-SAOmdbMetadata, or $null
    .OUTPUTS
        Array of inline image hashtables, or empty array
    .EXAMPLE
        $images = Get-SAEmailInlineImages -OmdbData $omdbData
        Send-SAEmail -Config $config -Subject "Test" -Body $html -InlineImages $images
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [hashtable]$OmdbData
    )
    
    $images = @()
    
    # Check for PosterData in OmdbData
    if ($null -eq $OmdbData) {
        return $images
    }
    
    $posterData = $OmdbData.PosterData
    if ($null -eq $posterData) {
        return $images
    }
    
    # Validate required properties
    if ($null -eq $posterData.Bytes -or $posterData.Bytes.Length -eq 0) {
        return $images
    }
    
    if ([string]::IsNullOrWhiteSpace($posterData.ContentId)) {
        return $images
    }
    
    # Build inline image hashtable
    $images += @{
        Bytes     = $posterData.Bytes
        MimeType  = if ($posterData.MimeType) { $posterData.MimeType } else { 'image/jpeg' }
        ContentId = $posterData.ContentId
    }
    
    return $images
}

#endregion

# Note: Source and service display name functions have been moved to 
# Private/MediaDisplay.ps1 for reuse across console, email, and other outputs.
# See: Get-SASourceDisplayName, Get-SAServiceDisplayName
