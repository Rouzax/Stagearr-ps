#Requires -Version 5.1
<#
.SYNOPSIS
    Media metadata display formatting utilities.
.DESCRIPTION
    Functions for converting parsed media metadata into compact, human-readable
    display formats suitable for any output channel (console, email, notifications).
    
    These functions complement MediaParsing.ps1 by handling the "display" side
    of media metadata, while MediaParsing.ps1 handles the "extraction" side.
    
    Used by: EmailSubject.ps1, console output, notification systems, log files
    
    Scene naming conventions are followed where applicable:
    - Sources: UHD, BluRay, WEB, HDTV, Remux
    - Services: NF (Netflix), AMZN (Amazon), HMAX (HBO Max)
    - HDR: Dolby Vision, HDR10+, HDR10, HDR
    
    Key functions:
    - Get-SASourceDisplayName: Source to compact form
    - Get-SAServiceDisplayName: Service to abbreviation
    - Get-SAHdrDisplayName: HDR tags to display name
    - Get-SAQualityDisplayString: Full quality string for email
    - Get-SAQualityLogString: Full quality string for logs
    - Add-SAReleaseDisplayInfo: Enrich ReleaseInfo with all display values
#>

#region Source Display Names

function Get-SASourceDisplayName {
    <#
    .SYNOPSIS
        Converts source metadata to compact display name.
    .DESCRIPTION
        Maps raw source values from GuessIt or local parsing to scene-convention
        compact names suitable for display in subjects, console output, or notifications.
        
        Remux detection takes precedence (checking both Source and Other fields).
    .PARAMETER Source
        Raw source value (e.g., "Ultra HD Blu-ray", "Web", "Blu-ray")
    .PARAMETER Other
        Other metadata array (may contain "Remux"). Accepts string, array, or null.
    .OUTPUTS
        Compact source string (e.g., "UHD", "WEB", "BluRay", "Remux")
    .EXAMPLE
        Get-SASourceDisplayName -Source 'Ultra HD Blu-ray'
        # Returns: 'UHD'
    .EXAMPLE
        Get-SASourceDisplayName -Source 'Blu-ray' -Other @('Remux', 'HDR10')
        # Returns: 'Remux'
    .EXAMPLE
        Get-SASourceDisplayName -Source 'Web'
        # Returns: 'WEB'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Source,
        
        [Parameter()]
        [object]$Other
    )
    
    # Normalize Other to array for consistent handling
    $otherArray = if ($Other -is [array]) { $Other } elseif ($Other) { @($Other) } else { @() }
    
    # Check for Remux (scene convention: Remux takes precedence over source)
    if ($otherArray -contains 'Remux' -or $otherArray -contains 'REMUX' -or $Source -match '(?i)remux') {
        return 'Remux'
    }
    
    # Map source to compact display name (scene naming conventions)
    $sourceMap = @{
        'Ultra HD Blu-ray' = 'UHD'
        'Blu-ray'          = 'BluRay'
        'HD-DVD'           = 'HDDVD'
        'Web'              = 'WEB'
        'HDTV'             = 'HDTV'
        'DVD'              = 'DVD'
        'VHS'              = 'VHS'
        'Telecine'         = 'TC'
        'Telesync'         = 'TS'
        'Cam'              = 'CAM'
    }
    
    if ($sourceMap.ContainsKey($Source)) {
        return $sourceMap[$Source]
    }
    
    # Fallback: return source as-is if short enough, otherwise abbreviate
    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        if ($Source.Length -le 6) {
            return $Source
        }
        # Remove spaces and dashes, take first 6 chars
        $abbreviated = ($Source -replace '\s+', '' -replace '-', '')
        return $abbreviated.Substring(0, [Math]::Min(6, $abbreviated.Length))
    }
    
    return ''
}

#endregion

#region Streaming Service Display Names

function Get-SAServiceDisplayName {
    <#
    .SYNOPSIS
        Converts streaming service name to compact abbreviation.
    .DESCRIPTION
        Maps full streaming service names to scene-convention abbreviations
        suitable for display in subjects, console output, or notifications.
        
        Accepts both full names (from GuessIt API) and abbreviations (from local parsing).
        If input is already a known abbreviation, returns it unchanged.
        
        Unknown services are truncated to first 4 characters uppercase.
    .PARAMETER StreamingService
        Full service name or abbreviation (e.g., "Netflix", "NF", "Amazon Prime", "AMZN")
    .OUTPUTS
        Abbreviated service name (e.g., "NF", "AMZN", "HMAX")
    .EXAMPLE
        Get-SAServiceDisplayName -StreamingService 'Netflix'
        # Returns: 'NF'
    .EXAMPLE
        Get-SAServiceDisplayName -StreamingService 'NF'
        # Returns: 'NF' (pass-through)
    .EXAMPLE
        Get-SAServiceDisplayName -StreamingService 'Amazon Prime'
        # Returns: 'AMZN'
    .EXAMPLE
        Get-SAServiceDisplayName -StreamingService 'Disney+'
        # Returns: 'DSNP'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$StreamingService
    )
    
    if ([string]::IsNullOrWhiteSpace($StreamingService)) {
        return ''
    }
    
    # Map full names to abbreviations (for GuessIt API responses)
    # Also includes abbreviations as identity mappings (for local parsing)
    $serviceMap = @{
        # Full names (from GuessIt API)
        'Netflix'        = 'NF'
        'Amazon Prime'   = 'AMZN'
        'Amazon'         = 'AMZN'
        'HBO Max'        = 'HMAX'
        'HBO'            = 'HBO'
        'Disney+'        = 'DSNP'
        'Disney Plus'    = 'DSNP'
        'Apple TV+'      = 'ATVP'
        'Apple TV Plus'  = 'ATVP'
        'Hulu'           = 'HULU'
        'Peacock'        = 'PCOK'
        'Paramount+'     = 'PMTP'
        'Paramount Plus' = 'PMTP'
        'iTunes'         = 'iT'
        'YouTube'        = 'YT'
        'YouTube Red'    = 'RED'
        'Crunchyroll'    = 'CR'
        'Stan'           = 'STAN'
        'Crave'          = 'CRAV'
        'Shout! Factory' = 'SHOUT'
        
        # Abbreviations (pass-through for local parsing)
        # Note: Hulu/HULU and Stan/STAN are not listed here as PowerShell
        # hashtables are case-insensitive, so the full names above handle them
        'NF'    = 'NF'
        'AMZN'  = 'AMZN'
        'HMAX'  = 'HMAX'
        'DSNP'  = 'DSNP'
        'ATVP'  = 'ATVP'
        'PCOK'  = 'PCOK'
        'PMTP'  = 'PMTP'
        'iT'    = 'iT'
        'YT'    = 'YT'
        'RED'   = 'RED'
        'CR'    = 'CR'
        'CRAV'  = 'CRAV'
        'SHOUT' = 'SHOUT'
    }
    
    if ($serviceMap.ContainsKey($StreamingService)) {
        return $serviceMap[$StreamingService]
    }
    
    # Fallback: first 4 chars uppercase
    return $StreamingService.Substring(0, [Math]::Min(4, $StreamingService.Length)).ToUpper()
}

#endregion

#region HDR Display Names

function Get-SAHdrDisplayName {
    <#
    .SYNOPSIS
        Converts HDR metadata tags to human-readable display names.
    .DESCRIPTION
        Maps raw HDR values from GuessIt or local parsing to user-friendly
        display names. Handles multiple HDR formats (e.g., DV + HDR10) by
        combining them into a compound display string.
        
        The Other array may contain various tags; this function extracts
        only HDR-related values and formats them appropriately.
        
        Priority order for compound formats:
        1. Dolby Vision (most valuable HDR format)
        2. HDR10+
        3. HDR10
        4. Generic HDR
    .PARAMETER Other
        Other metadata array from ReleaseInfo (may contain HDR tags).
        Accepts string, array, or null.
    .OUTPUTS
        Display string (e.g., "Dolby Vision", "HDR10+", "Dolby Vision HDR", "")
    .EXAMPLE
        Get-SAHdrDisplayName -Other @('DV', 'HDR10')
        # Returns: 'Dolby Vision HDR'
    .EXAMPLE
        Get-SAHdrDisplayName -Other @('HDR10+', 'REMUX')
        # Returns: 'HDR10+'
    .EXAMPLE
        Get-SAHdrDisplayName -Other @('REMUX')
        # Returns: ''
    .EXAMPLE
        Get-SAHdrDisplayName -Other 'DV'
        # Returns: 'Dolby Vision'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [object]$Other
    )
    
    # Normalize Other to array for consistent handling
    $otherArray = if ($Other -is [array]) { $Other } elseif ($Other) { @($Other) } else { @() }
    
    if ($otherArray.Count -eq 0) {
        return ''
    }
    
    # Check for HDR formats (case-insensitive matching)
    $hasDV = $otherArray | Where-Object { $_ -match '(?i)^(DV|Dolby[\s\.]?Vision)$' }
    $hasHdr10Plus = $otherArray | Where-Object { $_ -match '(?i)^HDR10[\+P]$' }
    $hasHdr10 = $otherArray | Where-Object { $_ -match '(?i)^HDR10$' }
    $hasHdr = $otherArray | Where-Object { $_ -match '(?i)^HDR$' }
    
    # Build display name based on what's present
    # Priority: DV > HDR10+ > HDR10 > HDR
    # Compound: DV + any other HDR = "Dolby Vision HDR"
    
    if ($hasDV) {
        # Dolby Vision present - check for compound format
        if ($hasHdr10Plus -or $hasHdr10 -or $hasHdr) {
            return 'Dolby Vision HDR'
        }
        return 'Dolby Vision'
    }
    
    if ($hasHdr10Plus) {
        return 'HDR10+'
    }
    
    if ($hasHdr10) {
        return 'HDR10'
    }
    
    if ($hasHdr) {
        return 'HDR'
    }
    
    return ''
}

#endregion

#region Quality String Formatting

function Get-SAQualityDisplayString {
    <#
    .SYNOPSIS
        Builds a human-readable quality string for email display.
    .DESCRIPTION
        Constructs a formatted quality string from ReleaseInfo metadata,
        using bullet separators for readability in email context.
        
        Format: "{resolution} {source} • {hdr}"
        
        Examples:
        - "2160p Remux • Dolby Vision"
        - "2160p WEB • HDR10+"
        - "1080p BluRay"
        - "1080p WEB"
        
        Returns empty string if no meaningful quality data is available.
    .PARAMETER ReleaseInfo
        ReleaseInfo object from Get-SAReleaseInfo (or similar structure).
        Expected properties: ScreenSize, Source, Other
    .OUTPUTS
        Quality display string for email (e.g., "2160p WEB • Dolby Vision") or ""
    .EXAMPLE
        Get-SAQualityDisplayString -ReleaseInfo @{ScreenSize='2160p'; Source='Web'; Other=@('DV','HDR10')}
        # Returns: '2160p WEB • Dolby Vision HDR'
    .EXAMPLE
        Get-SAQualityDisplayString -ReleaseInfo @{ScreenSize='1080p'; Source='Blu-ray'; Other=$null}
        # Returns: '1080p BluRay'
    .EXAMPLE
        Get-SAQualityDisplayString -ReleaseInfo $null
        # Returns: ''
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [object]$ReleaseInfo
    )
    
    if ($null -eq $ReleaseInfo) {
        return ''
    }
    
    $parts = @()
    
    # Resolution (ScreenSize)
    if (-not [string]::IsNullOrWhiteSpace($ReleaseInfo.ScreenSize)) {
        $parts += $ReleaseInfo.ScreenSize
    }
    
    # Source (using existing helper for consistent formatting)
    $sourceDisplay = Get-SASourceDisplayName -Source $ReleaseInfo.Source -Other $ReleaseInfo.Other
    if (-not [string]::IsNullOrWhiteSpace($sourceDisplay)) {
        $parts += $sourceDisplay
    }
    
    # If we have no resolution or source, return empty
    if ($parts.Count -eq 0) {
        return ''
    }
    
    # HDR info (using new helper)
    $hdrDisplay = Get-SAHdrDisplayName -Other $ReleaseInfo.Other
    
    # Build final string
    $baseQuality = $parts -join ' '
    
    if (-not [string]::IsNullOrWhiteSpace($hdrDisplay)) {
        # Use bullet separator for HDR in email context
        return "$baseQuality • $hdrDisplay"
    }
    
    return $baseQuality
}

function Get-SAQualityLogString {
    <#
    .SYNOPSIS
        Builds a technical quality string for log file display.
    .DESCRIPTION
        Constructs a formatted quality string from ReleaseInfo metadata,
        using space separators for a more technical log-file appearance.
        
        Format: "{resolution} {source} {hdr}"
        
        Examples:
        - "2160p WEB-DL Dolby Vision"
        - "1080p BluRay HDR10+"
        - "720p HDTV"
        
        Returns empty string if no meaningful quality data is available.
        
        Note: Uses slightly more technical source names than email version
        (e.g., preserves WEB-DL distinction where available).
    .PARAMETER ReleaseInfo
        ReleaseInfo object from Get-SAReleaseInfo (or similar structure).
        Expected properties: ScreenSize, Source, Other
    .OUTPUTS
        Quality log string (e.g., "2160p WEB-DL Dolby Vision") or ""
    .EXAMPLE
        Get-SAQualityLogString -ReleaseInfo @{ScreenSize='2160p'; Source='Web'; Other=@('DV')}
        # Returns: '2160p WEB Dolby Vision'
    .EXAMPLE
        Get-SAQualityLogString -ReleaseInfo @{ScreenSize='1080p'; Source='Blu-ray'; Other=$null}
        # Returns: '1080p BluRay'
    .EXAMPLE
        Get-SAQualityLogString -ReleaseInfo $null
        # Returns: ''
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [object]$ReleaseInfo
    )
    
    if ($null -eq $ReleaseInfo) {
        return ''
    }
    
    $parts = @()
    
    # Resolution (ScreenSize)
    if (-not [string]::IsNullOrWhiteSpace($ReleaseInfo.ScreenSize)) {
        $parts += $ReleaseInfo.ScreenSize
    }
    
    # Source (using existing helper - same as email for consistency)
    $sourceDisplay = Get-SASourceDisplayName -Source $ReleaseInfo.Source -Other $ReleaseInfo.Other
    if (-not [string]::IsNullOrWhiteSpace($sourceDisplay)) {
        $parts += $sourceDisplay
    }
    
    # If we have no resolution or source, return empty
    if ($parts.Count -eq 0) {
        return ''
    }
    
    # HDR info (using new helper)
    $hdrDisplay = Get-SAHdrDisplayName -Other $ReleaseInfo.Other
    if (-not [string]::IsNullOrWhiteSpace($hdrDisplay)) {
        $parts += $hdrDisplay
    }
    
    # Build final string (space-separated for logs)
    return $parts -join ' '
}

#endregion

#region ReleaseInfo Enrichment

function Add-SAReleaseDisplayInfo {
    <#
    .SYNOPSIS
        Enriches a ReleaseInfo object with all pre-computed display values.
    .DESCRIPTION
        Computes and adds display-ready properties to a ReleaseInfo object
        so downstream code can use them directly without re-computation.
        
        This function should be called once in JobProcessor after parsing,
        and the enriched object passed through the pipeline.
        
        Added properties:
        - SourceDisplay: Compact source name (e.g., "WEB", "Remux")
        - ServiceDisplay: Service abbreviation (e.g., "NF", "AMZN")
        - HdrDisplay: HDR display name (e.g., "Dolby Vision")
        - QualityDisplay: Email-formatted quality (e.g., "2160p WEB • Dolby Vision")
        - QualityLogDisplay: Log-formatted quality (e.g., "2160p WEB Dolby Vision")
        
        Handles null input gracefully (returns null for passthrough mode).
    .PARAMETER ReleaseInfo
        ReleaseInfo object from Get-SAReleaseInfo. May be null.
    .OUTPUTS
        Enriched ReleaseInfo object with display properties, or null if input is null.
    .EXAMPLE
        $releaseInfo = Get-SAReleaseInfo -FileName $name -Config $config
        $releaseInfo = Add-SAReleaseDisplayInfo -ReleaseInfo $releaseInfo
        # Now use $releaseInfo.QualityDisplay in email, $releaseInfo.QualityLogDisplay in logs
    .EXAMPLE
        $releaseInfo = Add-SAReleaseDisplayInfo -ReleaseInfo $null
        # Returns: $null (passthrough mode)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [PSCustomObject]$ReleaseInfo
    )
    
    # Handle null (passthrough mode)
    if ($null -eq $ReleaseInfo) {
        return $null
    }
    
    # Compute display values
    $sourceDisplay = Get-SASourceDisplayName -Source $ReleaseInfo.Source -Other $ReleaseInfo.Other
    $serviceDisplay = Get-SAServiceDisplayName -StreamingService $ReleaseInfo.StreamingService
    $hdrDisplay = Get-SAHdrDisplayName -Other $ReleaseInfo.Other
    $qualityDisplay = Get-SAQualityDisplayString -ReleaseInfo $ReleaseInfo
    $qualityLogDisplay = Get-SAQualityLogString -ReleaseInfo $ReleaseInfo
    
    # Add display properties to the object
    # Using Add-Member to preserve the original object type
    $ReleaseInfo | Add-Member -NotePropertyName 'SourceDisplay' -NotePropertyValue $sourceDisplay -Force
    $ReleaseInfo | Add-Member -NotePropertyName 'ServiceDisplay' -NotePropertyValue $serviceDisplay -Force
    $ReleaseInfo | Add-Member -NotePropertyName 'HdrDisplay' -NotePropertyValue $hdrDisplay -Force
    $ReleaseInfo | Add-Member -NotePropertyName 'QualityDisplay' -NotePropertyValue $qualityDisplay -Force
    $ReleaseInfo | Add-Member -NotePropertyName 'QualityLogDisplay' -NotePropertyValue $qualityLogDisplay -Force
    
    return $ReleaseInfo
}

#endregion
