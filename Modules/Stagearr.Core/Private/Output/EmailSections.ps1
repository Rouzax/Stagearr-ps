#Requires -Version 5.1
<#
.SYNOPSIS
    HTML section builders for email templates.
.DESCRIPTION
    Functions that generate HTML table sections for email notifications:
    - Document wrapper and structure
    - Status badge (Success/Warning/Failed/Skipped)
    - Title and subtitle sections
    - Details card with key-value rows
    - Notes section for warnings/exceptions
    - "What Happened" and "What to Check" for failures
    - Log path and footer
    
    All functions return HTML strings. Uses $script:SAEmailColors for theming
    (defined in EmailHelpers.ps1).
    
    Depends on: EmailHelpers.ps1 (for ConvertTo-SAHtmlSafe, display formatters, colors)
#>

#region Document Structure

function Get-SAEmailHtmlDocument {
    <#
    .SYNOPSIS
        Builds the complete HTML document with dark theme.
    .DESCRIPTION
        Creates the full email HTML document including DOCTYPE, head, body,
        and all content sections based on the job result type.
    .PARAMETER Title
        HTML document title
    .PARAMETER Summary
        Email summary hashtable
    .PARAMETER Events
        Array of output events (for result detection if not explicitly set)
    .OUTPUTS
        Complete HTML document string
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary,
        
        [Parameter()]
        [PSCustomObject[]]$Events = @()
    )
    
    $colors = $script:SAEmailColors
    
    $html = [System.Text.StringBuilder]::new()
    
    # Document header with Outlook conditional comments
    [void]$html.AppendLine('<!DOCTYPE html>')
    [void]$html.AppendLine('<html lang="en">')
    [void]$html.AppendLine('<head>')
    [void]$html.AppendLine('    <meta charset="UTF-8">')
    [void]$html.AppendLine('    <meta name="viewport" content="width=device-width, initial-scale=1.0">')
    [void]$html.AppendLine("    <title>$(ConvertTo-SAHtmlSafe $Title)</title>")
    [void]$html.AppendLine('    <!--[if mso]>')
    [void]$html.AppendLine('    <style type="text/css">')
    [void]$html.AppendLine('        table { border-collapse: collapse; }')
    [void]$html.AppendLine('        .badge { padding: 12px 24px !important; }')
    [void]$html.AppendLine('    </style>')
    [void]$html.AppendLine('    <![endif]-->')
    [void]$html.AppendLine('</head>')
    [void]$html.AppendLine("<body style=`"margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: $($colors.BackgroundDark); color: $($colors.TextPrimary);`">")
    
    # Wrapper table for email client compatibility
    [void]$html.AppendLine("    <table role=`"presentation`" cellspacing=`"0`" cellpadding=`"0`" border=`"0`" width=`"100%`" style=`"background-color: $($colors.BackgroundDark);`">")
    [void]$html.AppendLine('        <tr>')
    [void]$html.AppendLine('            <td align="center" style="padding: 16px 8px;">')
    
    # Main card - wider for better mobile display
    [void]$html.AppendLine("                <table role=`"presentation`" cellspacing=`"0`" cellpadding=`"0`" border=`"0`" width=`"100%`" style=`"max-width: 540px; background-color: $($colors.BackgroundCard); border-radius: 16px; overflow: hidden;`">")
    
    # Status badge section
    [void]$html.AppendLine((Get-SAEmailStatusBadge -Result $Summary.Result))
    
    # Title section
    [void]$html.AppendLine((Get-SAEmailTitleSection -Summary $Summary))
    
    # Content sections based on result type
    if ($Summary.Result -eq 'Failed') {
        # Failed: Show "What Happened" and "What to Check" sections
        [void]$html.AppendLine((Get-SAEmailWhatHappenedSection -Summary $Summary))
        [void]$html.AppendLine((Get-SAEmailWhatToCheckSection -Summary $Summary))
    } else {
        # Success/Warning/Skipped: Show Details section
        [void]$html.AppendLine((Get-SAEmailDetailsSection -Summary $Summary))
        
        # Notes section (only if there are exceptions)
        if ($Summary.Exceptions.Count -gt 0) {
            [void]$html.AppendLine((Get-SAEmailNotesSection -Exceptions $Summary.Exceptions -Result $Summary.Result))
        }
    }

    # Update section (only if update activity occurred)
    [void]$html.AppendLine((Get-SAEmailUpdateSection))

    # Log path section (always)
    [void]$html.AppendLine((Get-SAEmailLogSection))
    
    # Footer
    [void]$html.AppendLine((Get-SAEmailFooter))
    
    # Close main card
    [void]$html.AppendLine('                </table>')
    
    # Close wrapper
    [void]$html.AppendLine('            </td>')
    [void]$html.AppendLine('        </tr>')
    [void]$html.AppendLine('    </table>')
    [void]$html.AppendLine('</body>')
    [void]$html.AppendLine('</html>')
    
    return $html.ToString()
}

#endregion

#region Status Badge

function Get-SAEmailStatusBadge {
    <#
    .SYNOPSIS
        Generates the status badge section.
    .DESCRIPTION
        Creates a pill-shaped status badge with appropriate color and icon
        based on the job result (Success/Warning/Failed/Skipped).
    .PARAMETER Result
        Job result: Success, Warning, Failed, Skipped
    .OUTPUTS
        HTML string for the status badge table row
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped')]
        [string]$Result
    )
    
    $colors = $script:SAEmailColors
    
    # Badge configuration per result type
    # Note: Using [char] escape sequences for Unicode symbols to ensure PS5.1 compatibility
    # PS5.1 reads files without BOM using system default encoding, which mangles UTF-8 literals
    $checkmark = [char]0x2713  # checkmark
    $xmark = [char]0x2717      # x mark
    $skipArrow = [char]0x21B7  # curved arrow
    
    $badgeConfig = switch ($Result) {
        'Success' { @{ Color = $colors.SuccessGreen; Icon = $checkmark; Text = 'SUCCESS' } }
        'Warning' { @{ Color = $colors.WarningAmber; Icon = '!'; Text = 'WARNING' } }
        'Failed'  { @{ Color = $colors.FailedRed; Icon = $xmark; Text = 'FAILED' } }
        'Skipped' { @{ Color = $colors.SkippedGray; Icon = $skipArrow; Text = 'SKIPPED' } }
    }
    
    $html = [System.Text.StringBuilder]::new()
    
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td align="center" style="padding: 32px 24px 24px 24px;">')
    [void]$html.AppendLine('                            <table role="presentation" cellspacing="0" cellpadding="0" border="0">')
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td class=`"badge`" style=`"background-color: $($badgeConfig.Color); border-radius: 50px; padding: 12px 32px;`">")
    [void]$html.AppendLine("                                        <span style=`"color: #ffffff; font-size: 14px; font-weight: 700; letter-spacing: 1px;`">$($badgeConfig.Icon) $($badgeConfig.Text)</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    return $html.ToString()
}

#endregion

#region Title Section

function Get-SAEmailTitleSection {
    <#
    .SYNOPSIS
        Generates the title and subtitle section.
    .DESCRIPTION
        Creates the main title (job name) and subtitle (category • target).
        When OMDb data is present, renders a poster + metadata layout.
        When OMDb data is absent, renders the original centered layout.
    .PARAMETER Summary
        Email summary hashtable containing Name, Label, ImportTarget, and optionally OmdbData
    .OUTPUTS
        HTML string for the title section
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    # Check if we have OMDb data to display
    # PosterData is the new CID-based structure, PosterBase64 is deprecated but still supported
    $hasOmdbData = $null -ne $Summary.OmdbData -and (
        $Summary.OmdbData.PosterData -or 
        $Summary.OmdbData.PosterBase64 -or 
        $Summary.OmdbData.ImdbRating -or 
        $Summary.OmdbData.Genre
    )
    
    if ($hasOmdbData) {
        return Get-SAEmailOmdbTitleSection -Summary $Summary
    }
    
    # Original centered layout when no OMDb data
    return Get-SAEmailCenteredTitleSection -Summary $Summary
}

function Get-SAEmailCenteredTitleSection {
    <#
    .SYNOPSIS
        Generates the original centered title section (no OMDb data).
    .DESCRIPTION
        The classic centered title + subtitle layout used when OMDb data is not available.
    .PARAMETER Summary
        Email summary hashtable
    .OUTPUTS
        HTML string for the centered title section
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $colors = $script:SAEmailColors
    
    $html = [System.Text.StringBuilder]::new()
    
    # Title - Per OUTPUT-STYLE-GUIDE template: 22px
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td align="center" style="padding: 0 24px 8px 24px;">')
    [void]$html.AppendLine("                            <h1 style=`"margin: 0; font-size: 22px; font-weight: 600; color: $($colors.TextPrimary); line-height: 1.3;`">")
    [void]$html.AppendLine("                                $(ConvertTo-SAHtmlSafe $Summary.Name)")
    [void]$html.AppendLine('                            </h1>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    # Subtitle (Category • Target) - Per OUTPUT-STYLE-GUIDE template: 15px
    $subtitle = Get-SAEmailSubtitle -Summary $Summary
    if (-not [string]::IsNullOrWhiteSpace($subtitle)) {
        [void]$html.AppendLine('                    <tr>')
        [void]$html.AppendLine('                        <td align="center" style="padding: 0 24px 24px 24px;">')
        [void]$html.AppendLine("                            <span style=`"color: $($colors.TextSecondary); font-size: 15px;`">")
        [void]$html.AppendLine("                                $(ConvertTo-SAHtmlSafe $subtitle)")
        [void]$html.AppendLine('                            </span>')
        [void]$html.AppendLine('                        </td>')
        [void]$html.AppendLine('                    </tr>')
    }
    
    return $html.ToString()
}

function Get-SAEmailOmdbTitleSection {
    <#
    .SYNOPSIS
        Generates the title section with OMDb poster and metadata.
    .DESCRIPTION
        Creates a side-by-side layout with poster thumbnail on the left
        and title/ratings/genre on the right. Includes IMDb link.
        
        Layout:
        ┌────────┐  Title
        │ POSTER │  ⭐ 7.4  •  🍅 85%  •  Ⓜ 80
        │  80px  │  Genre  •  Runtime
        │        │  Category • Target
        └────────┘  ↳ View on IMDb
    .PARAMETER Summary
        Email summary hashtable with OmdbData
    .OUTPUTS
        HTML string for the OMDb-enhanced title section
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $colors = $script:SAEmailColors
    $omdb = $Summary.OmdbData
    
    $html = [System.Text.StringBuilder]::new()
    
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td style="padding: 0 24px 24px 24px;">')
    [void]$html.AppendLine('                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">')
    [void]$html.AppendLine('                                <tr>')
    
    # Poster column (prefer CID reference, fallback to base64 for backward compatibility)
    $posterSrc = $null
    if ($null -ne $omdb.PosterData -and -not [string]::IsNullOrWhiteSpace($omdb.PosterData.ContentId)) {
        # New CID-based reference (Phase 2+)
        $posterSrc = "cid:$($omdb.PosterData.ContentId)"
    } elseif (-not [string]::IsNullOrWhiteSpace($omdb.PosterBase64)) {
        # Deprecated: base64 data URI fallback
        $posterSrc = $omdb.PosterBase64
    }
    
    if (-not [string]::IsNullOrWhiteSpace($posterSrc)) {
        $safePosterSrc = $posterSrc.Replace('"', '&quot;')
        [void]$html.AppendLine('                                    <td style="width: 90px; vertical-align: top; padding-right: 16px;">')
        [void]$html.AppendLine("                                        <img src=`"$safePosterSrc`" alt=`"Poster`" style=`"width: 80px; height: auto; border-radius: 6px; display: block;`" />")
        [void]$html.AppendLine('                                    </td>')
    }
    
    # Content column (title, ratings, metadata)
    [void]$html.AppendLine('                                    <td style="vertical-align: top;">')
    
    # Title
    [void]$html.AppendLine("                                        <h1 style=`"margin: 0 0 8px 0; font-size: 20px; font-weight: 600; color: $($colors.TextPrimary); line-height: 1.3;`">")
    [void]$html.AppendLine("                                            $(ConvertTo-SAHtmlSafe $Summary.Name)")
    [void]$html.AppendLine('                                        </h1>')
    
    # Ratings row
    $ratingsHtml = Get-SAEmailRatingsHtml -OmdbData $omdb
    if (-not [string]::IsNullOrWhiteSpace($ratingsHtml)) {
        [void]$html.AppendLine("                                        <div style=`"margin-bottom: 6px; font-size: 14px;`">$ratingsHtml</div>")
    }
    
    # Genre and Runtime
    $metaParts = @()
    if (-not [string]::IsNullOrWhiteSpace($omdb.Genre)) {
        $metaParts += $omdb.Genre
    }
    if (-not [string]::IsNullOrWhiteSpace($omdb.Runtime)) {
        $metaParts += $omdb.Runtime
    }
    # For series, show total seasons
    if ($omdb.Type -eq 'series' -and -not [string]::IsNullOrWhiteSpace($omdb.TotalSeasons)) {
        $seasonWord = if ($omdb.TotalSeasons -eq '1') { 'season' } else { 'seasons' }
        $metaParts += "$($omdb.TotalSeasons) $seasonWord"
    }
    
    if ($metaParts.Count -gt 0) {
        $bullet = [char]0x2022  # •
        $metaText = $metaParts -join " $bullet "
        [void]$html.AppendLine("                                        <div style=`"color: $($colors.TextSecondary); font-size: 14px; margin-bottom: 6px;`">$(ConvertTo-SAHtmlSafe $metaText)</div>")
    }
    
    # Category • Target (subtitle)
    $subtitle = Get-SAEmailSubtitle -Summary $Summary
    if (-not [string]::IsNullOrWhiteSpace($subtitle)) {
        [void]$html.AppendLine("                                        <div style=`"color: $($colors.TextMuted); font-size: 14px; margin-bottom: 6px;`">$(ConvertTo-SAHtmlSafe $subtitle)</div>")
    }
    
    # IMDb link
    if (-not [string]::IsNullOrWhiteSpace($omdb.ImdbId) -and $omdb.ImdbId -match '^tt\d+$') {
        $imdbUrl = "https://www.imdb.com/title/$($omdb.ImdbId)/"
        [void]$html.AppendLine("                                        <div style=`"font-size: 13px;`">")
        [void]$html.AppendLine("                                            <a href=`"$imdbUrl`" style=`"color: $($colors.LinkBlue); text-decoration: none;`">&#8627; View on IMDb</a>")
        [void]$html.AppendLine('                                        </div>')
    }
    
    # Plot (if enabled and available)
    if (-not [string]::IsNullOrWhiteSpace($omdb.Plot)) {
        [void]$html.AppendLine("                                        <div style=`"color: $($colors.TextSecondary); font-size: 13px; margin-top: 10px; font-style: italic; line-height: 1.4;`">$(ConvertTo-SAHtmlSafe $omdb.Plot)</div>")
    }
    
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    return $html.ToString()
}

function Get-SAEmailRatingsHtml {
    <#
    .SYNOPSIS
        Generates the ratings HTML string.
    .DESCRIPTION
        Creates an inline HTML string showing available ratings with colored icons:
        ⭐ 7.4  •  🍅 85%  •  Ⓜ 80
        
        Only includes ratings that are present. Returns empty string if no ratings.
    .PARAMETER OmdbData
        OMDb data hashtable with ImdbRating, RottenTomatoes, Metacritic
    .OUTPUTS
        HTML string with ratings, or empty string if no ratings available
    .EXAMPLE
        Get-SAEmailRatingsHtml -OmdbData @{ ImdbRating = '7.4'; RottenTomatoes = '85%' }
        # Returns: '<span style="...">⭐</span> 7.4  •  <span style="...">🍅</span> 85%'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$OmdbData
    )
    
    $colors = $script:SAEmailColors
    $parts = @()
    
    # IMDb rating (yellow star)
    if (-not [string]::IsNullOrWhiteSpace($OmdbData.ImdbRating)) {
        $parts += "<span style=`"color: $($colors.ImdbYellow);`">&#11088;</span> <span style=`"color: $($colors.TextPrimary);`">$($OmdbData.ImdbRating)</span>"
    }
    
    # Rotten Tomatoes (tomato emoji - using text for email compatibility)
    if (-not [string]::IsNullOrWhiteSpace($OmdbData.RottenTomatoes)) {
        $parts += "<span style=`"color: $($colors.TomatoRed);`">&#127813;</span> <span style=`"color: $($colors.TextPrimary);`">$($OmdbData.RottenTomatoes)</span>"
    }
    
    # Metacritic (M in circle)
    if (-not [string]::IsNullOrWhiteSpace($OmdbData.Metacritic)) {
        $parts += "<span style=`"color: $($colors.MetacriticGreen);`">&#9410;</span> <span style=`"color: $($colors.TextPrimary);`">$($OmdbData.Metacritic)</span>"
    }
    
    if ($parts.Count -eq 0) {
        return ''
    }
    
    # Join with bullet separator (double space for visual breathing room)
    # Note: Store separator in variable to avoid PS5.1 parsing issues with < in -join string
    $separator = '  <span style="color: #64748b;">{0}</span>  ' -f [char]0x2022
    return ($parts -join $separator)
}

function Get-SAEmailSubtitle {
    <#
    .SYNOPSIS
        Builds the subtitle string (Category • Target).
    .DESCRIPTION
        Combines label and import target with bullet separator.
    .PARAMETER Summary
        Email summary hashtable
    .OUTPUTS
        Subtitle string like "Movie • Radarr"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $parts = @()
    
    if (-not [string]::IsNullOrWhiteSpace($Summary.Label)) {
        $parts += $Summary.Label
    }
    
    if (-not [string]::IsNullOrWhiteSpace($Summary.ImportTarget)) {
        $parts += $Summary.ImportTarget
    } elseif ($Summary.IsPassthrough) {
        $parts += 'Passthrough'
    }
    
    # Use Unicode code point to avoid encoding issues
    $bullet = [char]0x2022  # •
    return ($parts -join " $bullet ")
}

#endregion

#region Details Section

function Get-SAEmailDetailsSection {
    <#
    .SYNOPSIS
        Generates the Details card section.
    .DESCRIPTION
        Creates the details card showing source, files, subtitles, import status, and duration.
    .PARAMETER Summary
        Email summary hashtable
    .OUTPUTS
        HTML string for the details card
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $colors = $script:SAEmailColors
    
    $html = [System.Text.StringBuilder]::new()
    
    # Details card wrapper
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td style="padding: 0 16px 16px 16px;">')
    [void]$html.AppendLine("                            <table role=`"presentation`" cellspacing=`"0`" cellpadding=`"0`" border=`"0`" width=`"100%`" style=`"background-color: $($colors.BackgroundDark); border-radius: 12px; overflow: hidden;`">")
    
    # Header - Per OUTPUT-STYLE-GUIDE template: 12px for section labels
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td colspan=`"2`" style=`"padding: 16px 20px 12px 20px; border-bottom: 1px solid $($colors.BorderColor);`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextSecondary); font-size: 12px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;`">Details</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    
    # Source row (original release name) - first row, muted color
    if (-not [string]::IsNullOrWhiteSpace($Summary.SourceName)) {
        [void]$html.AppendLine((Format-SAEmailDetailRow -Label 'Source' -Value $Summary.SourceName -ValueColor $colors.TextSecondary -IsFirst -IsMonospace))
    }
    
    # Quality row (after Source, before Files) - only if quality info available
    $qualityDisplay = Get-SAEmailQualityDisplay -Summary $Summary
    if (-not [string]::IsNullOrWhiteSpace($qualityDisplay)) {
        # IsFirst only if no Source row
        $isFirst = [string]::IsNullOrWhiteSpace($Summary.SourceName)
        [void]$html.AppendLine((Format-SAEmailDetailRow -Label 'Quality' -Value $qualityDisplay -IsFirst:$isFirst))
    }
    
    # Files row
    $filesDisplay = Get-SAEmailFilesDisplay -Summary $Summary
    if (-not [string]::IsNullOrWhiteSpace($filesDisplay)) {
        # IsFirst only if no Source and no Quality row
        $isFirst = [string]::IsNullOrWhiteSpace($Summary.SourceName) -and [string]::IsNullOrWhiteSpace($qualityDisplay)
        [void]$html.AppendLine((Format-SAEmailDetailRow -Label 'Files' -Value $filesDisplay -IsFirst:$isFirst))
    }
    
    # Subtitles row (only for non-passthrough)
    if (-not $Summary.IsPassthrough) {
        $subDisplay = Get-SAEmailSubtitleDisplay -Summary $Summary
        if (-not [string]::IsNullOrWhiteSpace($subDisplay)) {
            $hasAllSubs = ($Summary.Subtitles.Count -gt 0) -and ($Summary.MissingLangs.Count -eq 0)
            if ($hasAllSubs) {
                [void]$html.AppendLine((Format-SAEmailDetailRow -Label 'Subtitles' -Value $subDisplay -HasCheckmark))
            } else {
                [void]$html.AppendLine((Format-SAEmailDetailRow -Label 'Subtitles' -Value $subDisplay))
            }
        }
    }
    
    # Import row
    $importDisplay = Get-SAEmailImportDisplay -Summary $Summary
    if (-not [string]::IsNullOrWhiteSpace($importDisplay)) {
        $importColor = $null
        if ($Summary.ImportResult -like '*Skipped*') {
            $importColor = $colors.WarningAmber
        }
        [void]$html.AppendLine((Format-SAEmailDetailRow -Label 'Import' -Value $importDisplay -ValueColor $importColor))
    }
    
    # Duration row (last) - normalize duration format
    if (-not [string]::IsNullOrWhiteSpace($Summary.Duration)) {
        $durationDisplay = ConvertTo-SAHumanDuration -Duration $Summary.Duration
        [void]$html.AppendLine((Format-SAEmailDetailRow -Label 'Duration' -Value $durationDisplay -IsLast))
    }
    
    # Close card
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    return $html.ToString()
}

function Format-SAEmailDetailRow {
    <#
    .SYNOPSIS
        Formats a row in the details card.
    .DESCRIPTION
        Creates a table row with label and value columns, with appropriate styling.
    .PARAMETER Label
        Row label (e.g., "Files", "Subtitles")
    .PARAMETER Value
        Row value
    .PARAMETER IsFirst
        Whether this is the first row (affects top padding)
    .PARAMETER IsLast
        Whether this is the last row (affects bottom padding)
    .PARAMETER HasCheckmark
        Whether to show a green checkmark before the value
    .PARAMETER ValueColor
        Custom color for the value text
    .PARAMETER IsMonospace
        Whether to use monospace font for technical values
    .OUTPUTS
        HTML string for the detail row
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        
        [Parameter(Mandatory = $true)]
        [string]$Value,
        
        [Parameter()]
        [switch]$IsFirst,
        
        [Parameter()]
        [switch]$IsLast,
        
        [Parameter()]
        [switch]$HasCheckmark,
        
        [Parameter()]
        [string]$ValueColor,
        
        [Parameter()]
        [switch]$IsMonospace
    )
    
    $colors = $script:SAEmailColors
    
    # Determine padding
    $topPadding = if ($IsFirst) { '12px' } else { '0' }
    $bottomPadding = if ($IsLast) { '16px' } else { '12px' }
    
    # Validate ValueColor is a proper hex color (not a boolean or other invalid value)
    $validValueColor = $false
    if (-not [string]::IsNullOrWhiteSpace($ValueColor) -and $ValueColor -match '^#[0-9A-Fa-f]{3,6}$') {
        $validValueColor = $true
    }
    
    # Font styling - monospace for technical values like release names
    $fontFamily = if ($IsMonospace) { 
        "font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace; font-size: 13px; word-break: break-all; line-height: 1.4;" 
    } else { 
        "font-size: 15px;" 
    }
    
    $html = [System.Text.StringBuilder]::new()
    
    # Per OUTPUT-STYLE-GUIDE template: 15px for content text (13px for monospace)
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"padding: $topPadding 20px $bottomPadding 20px; width: 75px; vertical-align: top;`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextMuted); font-size: 15px;`">$(ConvertTo-SAHtmlSafe $Label)</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine("                                    <td style=`"padding: $topPadding 20px $bottomPadding 0; vertical-align: top;`">")
    
    if ($HasCheckmark) {
        # Use variable for Unicode checkmark to avoid PS5.1 parsing issues
        $checkmark = [char]0x2713  # ✓
        [void]$html.AppendLine("                                        <span style=`"color: $($colors.SuccessGreen); font-size: 15px;`">$checkmark</span>")
        [void]$html.Append("                                        <span style=`"color: $($colors.TextPrimary); font-size: 15px;`"> ")
    } elseif ($validValueColor) {
        [void]$html.Append("                                        <span style=`"color: $ValueColor; $fontFamily`">")
    } else {
        [void]$html.Append("                                        <span style=`"color: $($colors.TextPrimary); $fontFamily`">")
    }
    
    [void]$html.AppendLine("$(ConvertTo-SAHtmlSafe $Value)</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    
    return $html.ToString()
}

#endregion

#region Notes Section

function Get-SAEmailNotesSection {
    <#
    .SYNOPSIS
        Generates the Notes card section.
    .DESCRIPTION
        Creates the notes card showing warnings and exceptions.
        Has an accent border color based on the result type.
    .PARAMETER Exceptions
        Array of exception objects with Message and Type properties
    .PARAMETER Result
        Job result for styling (Success/Warning/Failed)
    .OUTPUTS
        HTML string for the notes card
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$Exceptions,
        
        [Parameter()]
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped')]
        [string]$Result = 'Success'
    )
    
    $colors = $script:SAEmailColors
    
    # Determine border color based on result
    $borderColor = switch ($Result) {
        'Warning' { $colors.WarningAmber }
        'Failed'  { $colors.FailedRed }
        default   { $colors.TextSecondary }
    }
    
    # Determine header color
    $headerColor = switch ($Result) {
        'Warning' { $colors.WarningAmber }
        'Failed'  { $colors.FailedRed }
        default   { $colors.TextSecondary }
    }
    
    $html = [System.Text.StringBuilder]::new()
    
    # Notes card wrapper with accent border
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td style="padding: 0 16px 16px 16px;">')
    [void]$html.AppendLine("                            <table role=`"presentation`" cellspacing=`"0`" cellpadding=`"0`" border=`"0`" width=`"100%`" style=`"background-color: $($colors.BackgroundDark); border-radius: 12px; overflow: hidden; border-left: 3px solid $borderColor;`">")
    
    # Header - Per OUTPUT-STYLE-GUIDE template: 12px for section labels
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"padding: 16px 20px 12px 20px; border-bottom: 1px solid $($colors.BorderColor);`">")
    [void]$html.AppendLine("                                        <span style=`"color: $headerColor; font-size: 12px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;`">Notes</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    
    # Exception items
    $isFirst = $true
    foreach ($ex in $Exceptions) {
        $bulletColor = switch ($ex.Type) {
            'Error'   { $colors.FailedRed }
            'Warning' { $colors.WarningAmber }
            default   { $colors.TextSecondary }
        }
        
        $topPadding = if ($isFirst) { '12px' } else { '4px' }
        
        [void]$html.AppendLine('                                <tr>')
        [void]$html.AppendLine("                                    <td style=`"padding: $topPadding 20px 8px 20px;`">")
        # Use variable for Unicode bullet to avoid PS5.1 parsing issues
        $bullet = [char]0x2022  # •
        [void]$html.AppendLine("                                        <span style=`"color: $bulletColor; font-size: 15px;`">$bullet</span>")
        [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextNote); font-size: 15px;`"> $(ConvertTo-SAHtmlSafe $ex.Message)</span>")
        [void]$html.AppendLine('                                    </td>')
        [void]$html.AppendLine('                                </tr>')
        
        $isFirst = $false
    }
    
    # Add bottom padding
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine('                                    <td style="padding: 0 20px 8px 20px;"></td>')
    [void]$html.AppendLine('                                </tr>')
    
    # Close card
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    return $html.ToString()
}

#endregion

#region Failure Sections

function Get-SAEmailWhatHappenedSection {
    <#
    .SYNOPSIS
        Generates the "What Happened" card for failure emails.
    .DESCRIPTION
        Creates a card showing the failure phase, error message, and relevant path.
    .PARAMETER Summary
        Email summary hashtable containing FailurePhase, FailureError, FailurePath
    .OUTPUTS
        HTML string for the "What Happened" card
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $colors = $script:SAEmailColors
    
    $html = [System.Text.StringBuilder]::new()
    
    # Card wrapper with red accent border
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td style="padding: 0 16px 16px 16px;">')
    [void]$html.AppendLine("                            <table role=`"presentation`" cellspacing=`"0`" cellpadding=`"0`" border=`"0`" width=`"100%`" style=`"background-color: $($colors.BackgroundDark); border-radius: 12px; overflow: hidden; border-left: 3px solid $($colors.FailedRed);`">")
    
    # Header - Per OUTPUT-STYLE-GUIDE template: 12px for section labels
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td colspan=`"2`" style=`"padding: 16px 20px 12px 20px; border-bottom: 1px solid $($colors.BorderColor);`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.FailedRed); font-size: 12px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;`">What Happened</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    
    # Source row (if available) - original release name
    if (-not [string]::IsNullOrWhiteSpace($Summary.SourceName)) {
        [void]$html.AppendLine('                                <tr>')
        [void]$html.AppendLine("                                    <td style=`"padding: 12px 20px 8px 20px; width: 80px; vertical-align: top;`">")
        [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextMuted); font-size: 15px;`">Source</span>")
        [void]$html.AppendLine('                                    </td>')
        [void]$html.AppendLine("                                    <td style=`"padding: 12px 20px 8px 0; vertical-align: top;`">")
        [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextSecondary); font-size: 13px; font-family: 'SF Mono', Monaco, monospace; word-break: break-all;`">$(ConvertTo-SAHtmlSafe $Summary.SourceName)</span>")
        [void]$html.AppendLine('                                    </td>')
        [void]$html.AppendLine('                                </tr>')
    }
    
    # Phase row - Per OUTPUT-STYLE-GUIDE template: 15px for content
    $phase = if (-not [string]::IsNullOrWhiteSpace($Summary.FailurePhase)) { $Summary.FailurePhase } else { 'Processing' }
    $phasePadding = if ([string]::IsNullOrWhiteSpace($Summary.SourceName)) { '12px' } else { '0' }
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"padding: $phasePadding 20px 8px 20px; width: 80px; vertical-align: top;`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextMuted); font-size: 15px;`">Phase</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine("                                    <td style=`"padding: $phasePadding 20px 8px 0; vertical-align: top;`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextPrimary); font-size: 15px;`">$(ConvertTo-SAHtmlSafe $phase)</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    
    # Error row
    $errorText = if (-not [string]::IsNullOrWhiteSpace($Summary.FailureError)) { $Summary.FailureError } else { 'An error occurred' }
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"padding: 0 20px 8px 20px; vertical-align: top;`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextMuted); font-size: 15px;`">Error</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine("                                    <td style=`"padding: 0 20px 8px 0; vertical-align: top;`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.ErrorLight); font-size: 15px;`">$(ConvertTo-SAHtmlSafe $errorText)</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    
    # Path row (if available)
    if (-not [string]::IsNullOrWhiteSpace($Summary.FailurePath)) {
        [void]$html.AppendLine('                                <tr>')
        [void]$html.AppendLine("                                    <td style=`"padding: 0 20px 16px 20px; vertical-align: top;`">")
        [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextMuted); font-size: 15px;`">Path</span>")
        [void]$html.AppendLine('                                    </td>')
        [void]$html.AppendLine("                                    <td style=`"padding: 0 20px 16px 0; vertical-align: top;`">")
        [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextSecondary); font-size: 13px; font-family: 'SF Mono', Monaco, monospace; word-break: break-all;`">$(ConvertTo-SAHtmlSafe $Summary.FailurePath)</span>")
        [void]$html.AppendLine('                                    </td>')
        [void]$html.AppendLine('                                </tr>')
    } else {
        # Add padding at bottom if no path
        [void]$html.AppendLine('                                <tr>')
        [void]$html.AppendLine('                                    <td colspan="2" style="padding: 0 20px 8px 20px;"></td>')
        [void]$html.AppendLine('                                </tr>')
    }
    
    # Close card
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    return $html.ToString()
}

function Get-SAEmailWhatToCheckSection {
    <#
    .SYNOPSIS
        Generates the "What to Check" card with troubleshooting suggestions.
    .DESCRIPTION
        Creates a card with context-aware troubleshooting suggestions based on
        the failure phase and error message.
    .PARAMETER Summary
        Email summary hashtable containing FailurePhase, FailureError, ImportTarget
    .OUTPUTS
        HTML string for the "What to Check" card, or empty string if no suggestions
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $colors = $script:SAEmailColors
    
    # Generate context-aware troubleshooting suggestions
    $suggestions = Get-SAEmailTroubleshootingSuggestions -Summary $Summary
    
    if ($suggestions.Count -eq 0) {
        return ''
    }
    
    $html = [System.Text.StringBuilder]::new()
    
    # Card wrapper
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td style="padding: 0 16px 16px 16px;">')
    [void]$html.AppendLine("                            <table role=`"presentation`" cellspacing=`"0`" cellpadding=`"0`" border=`"0`" width=`"100%`" style=`"background-color: $($colors.BackgroundDark); border-radius: 12px; overflow: hidden;`">")
    
    # Header - Per OUTPUT-STYLE-GUIDE template: 12px for section labels
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"padding: 16px 20px 12px 20px; border-bottom: 1px solid $($colors.BorderColor);`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextSecondary); font-size: 12px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;`">What to Check</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    
    # Suggestion items - Per OUTPUT-STYLE-GUIDE template: 15px for content
    $isFirst = $true
    foreach ($suggestion in $suggestions) {
        $topPadding = if ($isFirst) { '12px' } else { '0' }
        
        [void]$html.AppendLine('                                <tr>')
        [void]$html.AppendLine("                                    <td style=`"padding: $topPadding 20px 8px 20px;`">")
        # Use variable for Unicode bullet to avoid PS5.1 parsing issues
        $bullet = [char]0x2022  # •
        [void]$html.AppendLine("                                        <span style=`"color: $($colors.WarningAmber); font-size: 15px;`">$bullet</span>")
        [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextNote); font-size: 15px;`"> $(ConvertTo-SAHtmlSafe $suggestion)</span>")
        [void]$html.AppendLine('                                    </td>')
        [void]$html.AppendLine('                                </tr>')
        
        $isFirst = $false
    }
    
    # Add bottom padding
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine('                                    <td style="padding: 0 20px 8px 20px;"></td>')
    [void]$html.AppendLine('                                </tr>')
    
    # Close card
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    return $html.ToString()
}

function Get-SAEmailTroubleshootingSuggestions {
    <#
    .SYNOPSIS
        Generates context-aware troubleshooting suggestions based on failure details.
    .DESCRIPTION
        Analyzes the failure phase and error message to provide relevant suggestions.
        Returns up to 3 suggestions.
    .PARAMETER Summary
        Email summary hashtable containing FailurePhase, FailureError, ImportTarget
    .OUTPUTS
        Array of suggestion strings (max 3)
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $suggestions = @()
    
    $phase = $Summary.FailurePhase
    $failureError = $Summary.FailureError
    $target = $Summary.ImportTarget
    
    # Phase-specific suggestions
    switch -Regex ($phase) {
        'Import|Radarr|Sonarr|Medusa' {
            # Medusa-specific errors
            if ($failureError -match 'Archived') {
                $suggestions += 'Episode is archived in Medusa'
                $suggestions += 'Change episode status to Wanted or Skipped'
            } elseif ($failureError -match 'postponed|waiting for subtitle') {
                $suggestions += 'Medusa is waiting for subtitles'
                $suggestions += 'Check subtitle provider settings'
            }
            # Path and access errors (Radarr/Sonarr/Medusa)
            elseif ($failureError -match 'invalid path format|not a valid Windows path') {
                $suggestions += 'Path format is invalid'
                $suggestions += 'Use full Windows path like C:\Downloads\Release'
                $suggestions += 'Escape backslashes in JSON config'
            } elseif ($failureError -match 'not found|not accessible|does not exist') {
                $suggestions += 'Is the network drive mounted?'
                $suggestions += "Check Remote Path Mapping in $target"
                $suggestions += "Does $target have read access to the folder?"
            } elseif ($failureError -match 'permission denied|access.*denied') {
                $suggestions += "Does $target service account have read/write permission?"
                $suggestions += 'Check share permissions and folder ACLs'
                $suggestions += 'For Docker: verify UID/GID mapping'
            }
            # Space and transfer errors
            elseif ($failureError -match 'not enough.*space|free space') {
                $suggestions += 'Not enough free space on destination'
                $suggestions += "Free up space or adjust minimum free space in $target"
            } elseif ($failureError -match 'move incomplete|data loss') {
                $suggestions += 'File transfer was interrupted'
                $suggestions += 'Ensure download is complete and file not in use'
                $suggestions += 'Check disk and network stability'
            }
            # Parse and naming errors
            elseif ($failureError -match 'unable to parse|parse.*name|cannot identify') {
                $suggestions += "Check release naming matches $target expectations"
                $suggestions += "Use Manual Import in $target to see rejections"
                if ($target -match 'Medusa') {
                    $suggestions += 'Add a scene exception if needed'
                }
            } elseif ($failureError -match 'sample|rejected.*sample') {
                $suggestions += 'File was detected as a sample'
                $suggestions += "Adjust sample handling in $target settings"
            }
            # Quality and skip errors
            elseif ($failureError -match 'reject|quality|exists|cutoff') {
                $suggestions += "Check $target quality profile settings"
                $suggestions += 'Review import settings for upgrade behavior'
            }
            # API and connection errors
            elseif ($failureError -match 'timeout|timed out|took too long') {
                $suggestions += "Is the $target service responding?"
                $suggestions += 'Check the API connection settings'
            } elseif ($failureError -match 'API|key|auth|unauthorized|401') {
                $suggestions += 'Check your API key configuration'
                $suggestions += "Verify $target API key is correct"
            }
            # Default fallback
            else {
                $suggestions += "Check $target activity log for details"
                $suggestions += "Is the $target service running?"
            }
        }
        'Staging|Video|Extract' {
            if ($failureError -match 'disk|space|full') {
                $suggestions += 'Check available disk space'
                $suggestions += 'Clean up staging folder'
            } elseif ($failureError -match 'corrupt|invalid|damaged') {
                $suggestions += 'The source file may be corrupted'
                $suggestions += 'Try re-downloading the file'
            } elseif ($failureError -match 'rar|extract|archive') {
                $suggestions += 'Is WinRAR installed correctly?'
                $suggestions += 'Check the archive file integrity'
            } else {
                $suggestions += 'Check disk space and permissions'
                $suggestions += 'Review the log file for details'
            }
        }
        'Subtitle' {
            if ($failureError -match 'quota|limit|rate') {
                $suggestions += 'OpenSubtitles API quota may be exceeded'
                $suggestions += 'Wait and try again later'
            } elseif ($failureError -match 'auth|login|credential') {
                $suggestions += 'Check OpenSubtitles credentials'
                $suggestions += 'API key may have expired'
            } else {
                $suggestions += 'Check internet connectivity'
                $suggestions += 'Verify OpenSubtitles API settings'
            }
        }
        default {
            # Generic suggestions
            $suggestions += 'Check the log file for detailed error information'
            $suggestions += 'Verify all configuration settings'
            $suggestions += 'Ensure required tools are installed'
        }
    }
    
    return $suggestions | Select-Object -First 3
}

#endregion

#region Update Section

function Get-SAEmailUpdateSection {
    <#
    .SYNOPSIS
        Generates the Update notification card section.
    .DESCRIPTION
        Creates an update card shown between Notes and Log File sections.
        Green left bar for successful auto-update, amber for notify-only,
        gray for up-to-date confirmation. Only rendered when a check was performed.
    .OUTPUTS
        HTML string for the update card, or empty string if no check was performed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $state = Get-SAUpdateState
    if (-not $state.CheckPerformed) {
        return ''
    }

    $colors = $script:SAEmailColors

    # Determine styling based on update result
    if ($state.UpdateApplied) {
        $borderColor = $colors.SuccessGreen
        $headerColor = $colors.SuccessGreen
        $headerText = 'Updated'
        $messageText = "Updated from v$($state.OldVersion) to v$($state.NewVersion)"
    } elseif ($state.UpdateAvailable) {
        $borderColor = $colors.WarningAmber
        $headerColor = $colors.WarningAmber
        $headerText = 'Update Available'
        $messageText = "v$($state.NewVersion) is available"
    } else {
        # Up to date - nothing actionable to show
        return ''
    }

    $html = [System.Text.StringBuilder]::new()

    # Card wrapper with accent border
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td style="padding: 0 16px 16px 16px;">')
    [void]$html.AppendLine("                            <table role=`"presentation`" cellspacing=`"0`" cellpadding=`"0`" border=`"0`" width=`"100%`" style=`"background-color: $($colors.BackgroundDark); border-radius: 12px; overflow: hidden; border-left: 3px solid $borderColor;`">")

    # Header
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"padding: 16px 20px 12px 20px; border-bottom: 1px solid $($colors.BorderColor);`">")
    [void]$html.AppendLine("                                        <span style=`"color: $headerColor; font-size: 12px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;`">$headerText</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')

    # Message row
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"padding: 12px 20px 8px 20px;`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextPrimary); font-size: 15px;`">$(ConvertTo-SAHtmlSafe $messageText)</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')

    # Release link row
    if (-not [string]::IsNullOrWhiteSpace($state.ReleaseUrl)) {
        [void]$html.AppendLine('                                <tr>')
        [void]$html.AppendLine("                                    <td style=`"padding: 0 20px 12px 20px;`">")
        [void]$html.AppendLine("                                        <a href=`"$(ConvertTo-SAHtmlSafe $state.ReleaseUrl)`" style=`"color: $($colors.TextSecondary); font-size: 13px; text-decoration: underline;`">View release notes</a>")
        [void]$html.AppendLine('                                    </td>')
        [void]$html.AppendLine('                                </tr>')
    }

    # Close card
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')

    return $html.ToString()
}

#endregion

#region Log and Footer Sections

function Get-SAEmailLogSection {
    <#
    .SYNOPSIS
        Generates the log path section.
    .DESCRIPTION
        Creates a section showing the filesystem log file path for reference.
    .OUTPUTS
        HTML string for the log path section, or empty string if no log path set
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    
    $colors = $script:SAEmailColors
    $logPath = $script:SAEmailState.LogPath
    
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        return ''
    }
    
    $html = [System.Text.StringBuilder]::new()
    
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td style="padding: 8px 16px 16px 16px;">')
    [void]$html.AppendLine('                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">')
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"padding: 12px 16px; background-color: $($colors.BackgroundDark); border-radius: 8px; border-left: 3px solid $($colors.AccentSlate);`">")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextMuted); font-size: 12px; display: block; margin-bottom: 4px;`">Log file</span>")
    [void]$html.AppendLine("                                        <span style=`"color: $($colors.TextSecondary); font-size: 13px; font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace; word-break: break-all;`">$(ConvertTo-SAHtmlSafe $logPath)</span>")
    [void]$html.AppendLine('                                    </td>')
    [void]$html.AppendLine('                                </tr>')
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    return $html.ToString()
}

function Get-SAEmailFooter {
    <#
    .SYNOPSIS
        Generates the footer section.
    .DESCRIPTION
        Creates the footer with version information and divider.
    .OUTPUTS
        HTML string for the footer section
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    
    $colors = $script:SAEmailColors
    
    # Get version from module manifest if available
    $version = 'v2.0.0'
    try {
        $manifestPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Stagearr.Core.psd1'
        if (Test-Path $manifestPath) {
            $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
            if ($manifest.ModuleVersion) {
                $version = "v$($manifest.ModuleVersion)"
            }
        }
    } catch {
        # Ignore errors, use default version
    }
    
    $html = [System.Text.StringBuilder]::new()
    
    # Footer divider
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td style="padding: 0 24px;">')
    [void]$html.AppendLine('                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">')
    [void]$html.AppendLine('                                <tr>')
    [void]$html.AppendLine("                                    <td style=`"border-top: 1px solid $($colors.BorderColor);`"></td>")
    [void]$html.AppendLine('                                </tr>')
    [void]$html.AppendLine('                            </table>')
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    # Footer text
    [void]$html.AppendLine('                    <tr>')
    [void]$html.AppendLine('                        <td align="center" style="padding: 16px 24px 24px 24px;">')
    [void]$html.AppendLine("                            <span style=`"color: $($colors.AccentSlate); font-size: 12px;`">Stagearr $version</span>")
    [void]$html.AppendLine('                        </td>')
    [void]$html.AppendLine('                    </tr>')
    
    return $html.ToString()
}

#endregion
