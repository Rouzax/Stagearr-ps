#Requires -Version 7.0
<#
.SYNOPSIS
    Pushover notifications for Stagearr
.DESCRIPTION
    Sends a formatted message per job to the Pushover recipients routed for the job's
    label. Each recipient receives either every message ("all") or only messages about
    something new being imported ("success").

    Design principles:
    - Opt-in: only runs when [notifications.pushover] is enabled.
    - Best-effort: never throws and never changes the job result; the import already
      happened.
    - The app token and user keys never reach logs, console or email.

    Recipients and routes are flat "a|b|c" strings, like [kodi] pathMap, because the TOML
    reader and config sync only handle fixed table names.
#>

#region Config

function ConvertFrom-SAPushoverConfig {
    <#
    .SYNOPSIS
        Parses the recipients and routes strings of [notifications.pushover]. Pure function.
    .DESCRIPTION
        recipients: "name|userOrGroupKey|all" or "...|success"
        routes:     "label,label|name,name"; label "*" catches labels without a route.

        A malformed entry is skipped with an error naming its position and, for recipients,
        the name only, so a key never ends up in a log line.
    .PARAMETER Config
        The [notifications.pushover] hashtable.
    .OUTPUTS
        PSCustomObject with Recipients (name -> @{ Name; Key; Notify }), Routes
        (@{ Labels; Recipients }[]) and Errors (string[]).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $recipients = [ordered]@{}
    $routes = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    $position = 0
    foreach ($entry in @($Config.recipients)) {
        $position++
        if ([string]::IsNullOrWhiteSpace([string]$entry)) { continue }
        $parts = @(([string]$entry -split '\|') | ForEach-Object { $_.Trim() })
        if ($parts.Count -ne 3 -or -not $parts[0] -or -not $parts[1]) {
            $errors.Add("recipients entry $position is not name|key|all or name|key|success")
            continue
        }
        $name = $parts[0]
        $notify = $parts[2].ToLowerInvariant()
        if ($notify -notin @('all', 'success')) {
            $errors.Add("recipient '$name' has notify '$($parts[2])'; use all or success")
            continue
        }
        if ($recipients.Contains($name)) {
            $errors.Add("recipient '$name' is listed more than once; the first entry is used")
            continue
        }
        $recipients[$name] = @{ Name = $name; Key = $parts[1]; Notify = $notify }
    }

    $position = 0
    foreach ($entry in @($Config.routes)) {
        $position++
        if ([string]::IsNullOrWhiteSpace([string]$entry)) { continue }
        $parts = @(([string]$entry -split '\|') | ForEach-Object { $_.Trim() })
        if ($parts.Count -ne 2) {
            $errors.Add("routes entry $position is not labels|recipients")
            continue
        }
        $labels = @(($parts[0] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($n in @(($parts[1] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if ($recipients.Contains($n)) {
                $names.Add($n)
            } else {
                $errors.Add("routes entry $position names unknown recipient '$n'")
            }
        }
        if ($labels.Count -eq 0 -or $names.Count -eq 0) {
            if ($labels.Count -eq 0) { $errors.Add("routes entry $position has no labels") }
            continue
        }
        $routes.Add(@{ Labels = $labels; Recipients = $names.ToArray() })
    }

    return [PSCustomObject]@{
        Recipients = $recipients
        Routes     = $routes.ToArray()
        Errors     = $errors.ToArray()
    }
}

function Get-SAPushoverRecipients {
    <#
    .SYNOPSIS
        Returns the recipients routed for a download label. Pure function.
    .DESCRIPTION
        A route label "tv" or "movie" matches every label Get-SALabelType maps to that
        type, so the [labels] aliases count. Other route labels match the job label without
        regard to case. The "*" route applies only when no named route matched.
    .PARAMETER Parsed
        Output of ConvertFrom-SAPushoverConfig.
    .PARAMETER Label
        The job's download label.
    .PARAMETER Config
        Full config, for the [labels] aliases.
    .OUTPUTS
        Recipient hashtables (@{ Name; Key; Notify }), each name once.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Parsed,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Label = '',

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $labelType = if ($Label) { Get-SALabelType -Label $Label -Config $Config } else { '' }

    $named = [System.Collections.Generic.List[string]]::new()
    $fallback = [System.Collections.Generic.List[string]]::new()
    foreach ($route in $Parsed.Routes) {
        foreach ($routeLabel in $route.Labels) {
            # Assigned, not taken from an if expression: that would unroll an empty list to $null
            $target = $named
            if ($routeLabel -eq '*') { $target = $fallback }
            $matched = $routeLabel -eq '*' -or
                ($routeLabel -in @('tv', 'movie') -and $routeLabel -eq $labelType) -or
                ($Label -and $routeLabel -ieq $Label)
            if ($matched) {
                foreach ($n in $route.Recipients) {
                    if (-not $target.Contains($n)) { $target.Add($n) }
                }
            }
        }
    }

    $chosen = if ($named.Count -gt 0) { $named } else { $fallback }
    return @($chosen | ForEach-Object { $Parsed.Recipients[$_] })
}

#endregion

#region State

function Get-SAPushoverState {
    <#
    .SYNOPSIS
        Classifies a finished job for Pushover. Pure function.
    .DESCRIPTION
        Get-SAEmailResultLevel cannot be reused: it reports a quality skip and a scheduled
        TBA retry as Success, while here a success recipient must only hear about jobs that
        imported something, and an "all" recipient must see the retry.

        States: Imported, Partial (imported with warnings, or nothing yet and a TBA retry
        scheduled), NothingNew (already in the library), Failed.
    .PARAMETER JobSuccess
        Overall job success.
    .PARAMETER ImportResult
        Result from Invoke-SAImport, or $null.
    .PARAMETER MissingLanguages
        Wanted subtitle languages that were not found.
    .PARAMETER TbaRetryScheduled
        Whether a TBA retry was queued for this job.
    .PARAMETER IsPassthrough
        Whether the job ran in passthrough mode (no import).
    .OUTPUTS
        PSCustomObject with State, ImportedCount and HasWarnings.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$JobSuccess,

        [Parameter()]
        [AllowNull()]
        [object]$ImportResult,

        [Parameter()]
        [AllowNull()]
        [array]$MissingLanguages,

        [Parameter()]
        [bool]$TbaRetryScheduled = $false,

        [Parameter()]
        [bool]$IsPassthrough = $false
    )

    $result = { param($State, $Count, $Warn) [PSCustomObject]@{ State = $State; ImportedCount = [int]$Count; HasWarnings = [bool]$Warn } }

    if (-not $JobSuccess) {
        return & $result 'Failed' 0 $true
    }
    if ($IsPassthrough) {
        return & $result 'Imported' 1 $false
    }

    $count = 0
    if ($null -ne $ImportResult) {
        if ($ImportResult.PSObject.Properties['ImportedCount'] -and $null -ne $ImportResult.ImportedCount) {
            $count = [int]$ImportResult.ImportedCount
        } elseif ($ImportResult.Success -eq $true -and $ImportResult.Skipped -ne $true -and $ImportResult.QualityRejected -ne $true) {
            # Medusa and older results carry no count; a plain success imported something
            $count = 1
        }
    }

    if ($count -eq 0) {
        if ($TbaRetryScheduled) {
            return & $result 'Partial' 0 $true
        }
        return & $result 'NothingNew' 0 $false
    }

    $aborted = $null -ne $ImportResult -and $ImportResult.Status -eq 'partial' -and $ImportResult.AbortedCount -gt 0
    $missing = $null -ne $MissingLanguages -and @($MissingLanguages).Count -gt 0
    if ($aborted -or $TbaRetryScheduled -or $missing) {
        return & $result 'Partial' $count $true
    }
    return & $result 'Imported' $count $false
}

#endregion

#region Message

function New-SAPushoverMessage {
    <#
    .SYNOPSIS
        Builds the Pushover message for one audience. Pure function.
    .DESCRIPTION
        A success recipient only hears about jobs that imported something, and then sees
        what is ready without warnings or retry times. An "all" recipient sees every state
        with its warnings.

        The title is plain text (Pushover renders HTML in the message only). Every message
        line is a self-contained HTML snippet, so shortening drops whole lines and never
        leaves a tag open: the plot goes first, then warnings from the end.
    .PARAMETER Summary
        The email summary hashtable ($script:SAEmailSummary).
    .PARAMETER StateInfo
        Output of Get-SAPushoverState.
    .PARAMETER Audience
        'all' or 'success'.
    .PARAMETER ImportResult
        Result from Invoke-SAImport, for the episode list.
    .PARAMETER KodiStatus
        'Updated', 'Partial', 'Skipped' or empty, from Invoke-SAKodiStep.
    .PARAMETER FinishedAt
        When the job finished; shown instead of the arrival time.
    .PARAMETER PushoverConfig
        The [notifications.pushover] hashtable, for sounds.
    .PARAMETER FolderPath
        Where a passthrough job put its files.
    .OUTPUTS
        Hashtable of Pushover message fields, or $null when this audience gets nothing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$StateInfo,

        [Parameter(Mandatory = $true)]
        [ValidateSet('all', 'success')]
        [string]$Audience,

        [Parameter()]
        [AllowNull()]
        [object]$ImportResult,

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$KodiStatus = '',

        [Parameter(Mandatory = $true)]
        [datetime]$FinishedAt,

        [Parameter(Mandatory = $true)]
        [hashtable]$PushoverConfig,

        [Parameter()]
        [AllowEmptyString()]
        [string]$FolderPath = ''
    )

    $state = $StateInfo.State
    $isAll = $Audience -eq 'all'
    if (-not $isAll -and ($state -in @('Failed', 'NothingNew') -or $StateInfo.ImportedCount -lt 1)) {
        return $null
    }

    $h = { param($t) ConvertTo-SAHtmlSafe -Text ([string]$t) }

    $prefix = switch ($state) {
        'Failed'     { '❌ Failed' }
        'NothingNew' { 'ℹ️ Already in library' }
        'Partial'    {
            if (-not $isAll) { '✅ Ready to watch' }
            elseif ($StateInfo.ImportedCount -lt 1) { '⏳ Waiting' }
            else { '⚠️ Partly imported' }
        }
        default {
            if ($Summary.IsPassthrough) { '✅ Done' }
            elseif ($isAll) { '✅ Imported' }
            else { '✅ Ready to watch' }
        }
    }
    $title = "$prefix · $($Summary.Name)"
    $titleMax = $script:SAConstants.PushoverTitleMaxLength
    if ($title.Length -gt $titleMax) { $title = $title.Substring(0, $titleMax) }

    $omdb = $Summary.OmdbData
    $plotLine = $null
    $lines = [System.Collections.Generic.List[string]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()

    if ($Summary.IsPassthrough) {
        if ($state -eq 'Failed' -and $Summary.FailureError) {
            $lines.Add("<b>Status:</b> $(& $h $Summary.FailureError)")
        }
        if ($Summary.VideoCount -gt 0) {
            $files = "$($Summary.VideoCount)"
            if ($Summary.VideoSize) { $files += ", $($Summary.VideoSize)" }
            $lines.Add("<b>Files:</b> $(& $h $files)")
        }
        if ($FolderPath -and $state -ne 'Failed') { $lines.Add("<b>Folder:</b> $(& $h $FolderPath)") }
        if ($Summary.Duration) { $lines.Add("<b>Took:</b> $(& $h $Summary.Duration)") }
    } else {
        if ($omdb -and $omdb.Plot) { $plotLine = "<i>$(& $h $omdb.Plot)</i>" }

        $status = switch ($state) {
            'Failed' {
                if ($Summary.FailureError) { $Summary.FailureError }
                elseif ($Summary.ImportResult) { $Summary.ImportResult }
                else { 'Job failed' }
            }
            'NothingNew' { 'Already in library at equal or better quality' }
            default {
                if ($StateInfo.ImportedCount -lt 1) {
                    "Waiting until $($Summary.ImportTarget) accepts the episode title"
                } else {
                    $note = ''
                    if ($null -ne $ImportResult -and $ImportResult.ImportedFiles) {
                        $note = Format-SAImportEpisodeNote -Files @($ImportResult.ImportedFiles) -Action 'Imported'
                    }
                    if (-not $note) { $note = 'Imported' }
                    if ($Summary.ImportTarget) { "$note to $($Summary.ImportTarget)" } else { $note }
                }
            }
        }
        $lines.Add("<b>Status:</b> $(& $h $status)")

        $quality = Get-SAEmailQualityDisplay -Summary $Summary
        if ($quality) { $lines.Add("<b>Quality:</b> $(& $h $quality)") }

        $subs = if ($isAll) {
            Get-SAEmailSubtitleDisplay -Summary $Summary
        } elseif ($Summary.Subtitles) {
            (@($Summary.Subtitles) | Sort-Object) -join ', '
        } else { '' }
        if ($subs) { $lines.Add("<b>Subtitles:</b> $(& $h $subs)") }

        if ($omdb -and $omdb.ImdbId -and $omdb.ImdbRating) {
            $imdbUrl = "https://www.imdb.com/title/$([uri]::EscapeDataString([string]$omdb.ImdbId))/"
            $imdb = "<b>IMDb:</b> <a href=`"$imdbUrl`">★ $(& $h $omdb.ImdbRating)</a>"
            if ($omdb.Genre) { $imdb += " · $(& $h $omdb.Genre)" }
            $lines.Add($imdb)
        }

        $kodi = switch ($KodiStatus) {
            'Updated' { 'in library' }
            'Partial' { if ($isAll) { 'not everything reached Kodi' } }
            'Skipped' { if ($isAll) { 'not scanned' } }
        }
        if ($kodi) { $lines.Add("<b>Kodi:</b> $kodi") }
    }

    if ($isAll) {
        foreach ($ex in @($Summary.Exceptions)) {
            if ($ex -and $ex.Type -in @('Warning', 'Error') -and $ex.Message) {
                $warningLines.Add((& $h $ex.Message))
            }
        }
    }

    $maxLength = $script:SAConstants.PushoverMessageMaxLength
    $compose = {
        param($withPlot, $warnCount)
        $all = [System.Collections.Generic.List[string]]::new()
        if ($withPlot -and $plotLine) { $all.Add($plotLine) }
        $all.AddRange($lines)
        for ($i = 0; $i -lt $warnCount; $i++) { $all.Add($warningLines[$i]) }
        $left = $warningLines.Count - $warnCount
        if ($left -gt 0) { $all.Add("<i>+$left more in the email and job log</i>") }
        return ($all -join "`n")
    }
    $message = & $compose $true $warningLines.Count
    if ($message.Length -gt $maxLength) { $message = & $compose $false $warningLines.Count }
    $warnCount = $warningLines.Count
    while ($message.Length -gt $maxLength -and $warnCount -gt 0) {
        $warnCount--
        $message = & $compose $false $warnCount
    }
    if ($message.Length -gt $maxLength) {
        # Only the fixed lines are left: cut whole lines from the end, keeping Status
        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($message -split "`n")) {
            $candidate = if ($kept.Count) { ($kept -join "`n") + "`n" + $line } else { $line }
            if ($candidate.Length -gt $maxLength) { break }
            $kept.Add($line)
        }
        $message = $kept -join "`n"
    }

    $fields = [ordered]@{
        title     = $title
        message   = $message
        html      = 1
        priority  = switch ($state) { 'Failed' { 1 } 'NothingNew' { -1 } default { 0 } }
        timestamp = ([DateTimeOffset]$FinishedAt).ToUnixTimeSeconds()
    }

    $sound = if ($state -eq 'Failed') { $PushoverConfig.failureSound } else { $PushoverConfig.sound }
    if ($state -ne 'NothingNew' -and -not [string]::IsNullOrWhiteSpace($sound)) {
        $fields.sound = $sound
    }

    $link = $Summary.ArrLink
    if ($link -and $link.Url -and $link.Url.Length -le 512) {
        $fields.url = $link.Url
        $urlTitle = "View in $($link.AppName)"
        $fields.url_title = $urlTitle.Substring(0, [Math]::Min($urlTitle.Length, $script:SAConstants.PushoverUrlTitleMaxLength))
    }

    $poster = if ($omdb) { $omdb.PosterData } else { $null }
    if ($poster -and $poster.Bytes -and $poster.Bytes.Length -gt 0 -and
        $poster.Bytes.Length -le $script:SAConstants.PushoverAttachmentMaxBytes) {
        $fields.attachment_base64 = [Convert]::ToBase64String([byte[]]$poster.Bytes)
        $fields.attachment_type = if ($poster.MimeType) { $poster.MimeType } else { 'image/jpeg' }
    }

    return [hashtable]$fields
}

#endregion
