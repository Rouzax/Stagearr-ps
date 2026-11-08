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
