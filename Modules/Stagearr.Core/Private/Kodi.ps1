#Requires -Version 7.0
<#
.SYNOPSIS
    Targeted Kodi library updates for Stagearr
.DESCRIPTION
    After an import, scans only the imported title's folder in Kodi over JSON-RPC, then
    confirms the title appeared.

    Kodi answers OK to several requests that do nothing, so the response proves little:
    - A scan path without a trailing slash is treated as its parent. A new show then adds
      nothing, and season folders can be scraped as shows.
    - A scan of a season folder creates a bogus show.
    - A scan of a missing directory only logs a warning.
    - A scan sent during a scan cancels the running one and is itself dropped.

    Hence every path comes from Files.GetDirectory, Stagearr waits for Kodi to be idle
    before scanning, and success is judged from the library afterwards.

    Radarr/Sonarr paths are matched to Kodi's sources by their trailing folder names, and
    the match is only trusted once Kodi lists the title's folder there. kodi.pathMap is an
    override for setups where the names differ.

    A title that could not be scanned for a passing reason goes on a pending list and is
    retried by a later job, because nothing else would tell Kodi about it.

    Best-effort: nothing here throws, and a failure never changes the job outcome. The
    import has already happened by the time this runs.
#>

#region Pure Helper Functions

function Get-SAKodiPathMap {
    <#
    .SYNOPSIS
        Parses kodi.pathMap entries of the form "arrPath|kodiPath". Pure function.
    .DESCRIPTION
        The TOML parser unrolls a one-element array to a plain string, so the value is
        always read through @(). Malformed entries are dropped; Test-SAKodiConfig reports
        them.
    .PARAMETER PathMap
        Raw kodi.pathMap value: string, array of strings, or $null.
    .OUTPUTS
        PSCustomObject[] with From and To.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$PathMap
    )

    $entries = @()
    foreach ($entry in @($PathMap)) {
        if ($entry -isnot [string]) {
            continue
        }
        # The TOML parser keeps the quotes of a single-quoted array item
        $parts = $entry.Trim().Trim("'", '"').Split('|', 2)
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
            continue
        }
        $entries += [PSCustomObject]@{
            From = $parts[0].Trim()
            To   = $parts[1].Trim()
        }
    }

    return $entries
}

function Get-SAKodiPathSeparator {
    <#
    .SYNOPSIS
        Returns the separator a Kodi path uses: Kodi on Windows has backslash sources.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path.Contains('\') -and -not $Path.Contains('/')) {
        return '\'
    }
    return '/'
}

function ConvertTo-SAKodiPath {
    <#
    .SYNOPSIS
        Maps a Radarr/Sonarr title root to Kodi's form. Pure function.
    .DESCRIPTION
        Returns the parent folder and the title folder separately, because the exact path
        to scan must come from Kodi's own listing of the parent.

        The longest matching prefix wins. Matching ignores case and stops at a path
        boundary, so D:\Data does not match D:\Data2.
    .PARAMETER ArrPath
        Title root as reported by Radarr or Sonarr.
    .PARAMETER PathMap
        Entries from Get-SAKodiPathMap.
    .OUTPUTS
        PSCustomObject with Parent (ends in a separator) and Leaf, or $null when unmapped.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArrPath,

        [Parameter()]
        [AllowNull()]
        [object[]]$PathMap
    )

    $normalized = $ArrPath.Replace('\', '/').TrimEnd('/')
    $best = $null
    $bestPrefix = ''

    foreach ($entry in @($PathMap)) {
        if ($null -eq $entry) {
            continue
        }
        $prefix = $entry.From.Replace('\', '/').TrimEnd('/')
        if ($prefix.Length -gt $bestPrefix.Length -and
            $normalized.StartsWith("$prefix/", [StringComparison]::OrdinalIgnoreCase)) {
            $best = $entry
            $bestPrefix = $prefix
        }
    }

    if ($null -eq $best) {
        return $null
    }

    $relative = $normalized.Substring($bestPrefix.Length + 1)
    $separator = $relative.LastIndexOf('/')
    $kodiSeparator = Get-SAKodiPathSeparator -Path $best.To
    $base = $best.To.TrimEnd('/', '\')
    if ($separator -ge 0) {
        $base = $base + $kodiSeparator + $relative.Substring(0, $separator).Replace('/', $kodiSeparator)
    }

    return [PSCustomObject]@{
        Parent = $base + $kodiSeparator
        Leaf   = $relative.Substring($separator + 1)
    }
}

function Get-SAKodiPathCandidates {
    <#
    .SYNOPSIS
        Lists the Kodi sources a Radarr/Sonarr title root could live under. Pure function.
    .DESCRIPTION
        Compares folder names from the end, ignoring case, so \\server\data\kids\movies
        scores higher against smb://SERVER/Data/Kids/Movies/ than against .../Movies/. Host
        names and drive letters need not match, and folders below a source are carried over.

        A match is only a candidate: the caller must see the title in Kodi's listing.
        Multipath sources are skipped because their folders cannot be compared.
    .PARAMETER ArrPath
        Title root as reported by Radarr or Sonarr.
    .PARAMETER Sources
        Kodi video source paths.
    .OUTPUTS
        PSCustomObject[] with Parent, Leaf and Score, best first.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArrPath,

        [Parameter()]
        [AllowNull()]
        [string[]]$Sources
    )

    $segments = @($ArrPath.Replace('\', '/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))
    if ($segments.Count -lt 2) {
        return
    }
    $leaf = $segments[-1]
    $parents = @($segments[0..($segments.Count - 2)])

    $candidates = foreach ($source in @($Sources)) {
        if ([string]::IsNullOrWhiteSpace($source) -or $source -match '^multipath://') {
            continue
        }
        $sourceSegments = @(($source -replace '^[A-Za-z0-9+.-]+://', '') -split '[/\\]' | Where-Object { $_ })

        $bestScore = 0
        $bestEnd = -1
        for ($end = $parents.Count - 1; $end -ge 0; $end--) {
            $score = 0
            while ($score -le $end -and $score -lt $sourceSegments.Count -and
                $parents[$end - $score] -ieq $sourceSegments[$sourceSegments.Count - 1 - $score]) {
                $score++
            }
            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestEnd = $end
            }
        }
        if ($bestScore -eq 0) {
            continue
        }

        $below = @()
        if ($bestEnd -lt $parents.Count - 1) {
            $below = @($parents[($bestEnd + 1)..($parents.Count - 1)])
        }
        $sourceSeparator = Get-SAKodiPathSeparator -Path $source
        [PSCustomObject]@{
            Parent = (@($source.TrimEnd('/', '\')) + $below -join $sourceSeparator) + $sourceSeparator
            Leaf   = $leaf
            Score  = $bestScore
            Below  = $below.Count
        }
    }

    $seen = @{}
    return @($candidates | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, 'Below' -Stable | Where-Object {
            $key = $_.Parent.ToLowerInvariant()
            $isNew = -not $seen.ContainsKey($key)
            $seen[$key] = $true
            $isNew
        })
}

function Set-SAKodiSourceSpelling {
    <#
    .SYNOPSIS
        Replaces the start of a path with the spelling of the matching source. Pure function.
    .DESCRIPTION
        Kodi's listing returns children under whatever parent it was asked about, so without
        this a broad kodi.pathMap entry would store the Radarr/Sonarr spelling in the library.
    .PARAMETER Path
        Kodi path, ending in /.
    .PARAMETER Sources
        Kodi video source paths.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [AllowNull()]
        [string[]]$Sources
    )

    $match = @($Sources) | Where-Object { $_ -and $Path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object -Property Length -Descending | Select-Object -First 1
    if ($null -eq $match) {
        return $Path
    }
    return $match + $Path.Substring($match.Length)
}

function Merge-SAKodiPending {
    <#
    .SYNOPSIS
        Adds titles to the pending list, one entry per folder. Pure function.
    .PARAMETER Existing
        Current entries.
    .PARAMETER Add
        Targets to add. An entry already present keeps its date, so expiry counts from the
        first miss.
    .PARAMETER Now
        Time to stamp on new entries.
    .OUTPUTS
        PSCustomObject[] of entries.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$Existing,

        [Parameter()]
        [AllowNull()]
        [object[]]$Add,

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    $merged = [ordered]@{}
    foreach ($item in @(@($Existing) + @($Add) | Where-Object { $null -ne $_ })) {
        $key = $item.RootPath.ToLowerInvariant()
        if (-not $merged.Contains($key)) {
            # An unreadable date restarts the clock so the entry can still expire
            $addedAt = $item.AddedAt
            $parsed = [datetimeoffset]::MinValue
            if ($addedAt -is [datetime]) {
                $addedAt = $addedAt.ToUniversalTime().ToString('o')
            } elseif (-not [datetimeoffset]::TryParse("$addedAt", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
                $addedAt = $Now.ToUniversalTime().ToString('o')
            }
            $merged[$key] = [PSCustomObject]@{
                RootPath  = $item.RootPath
                Title     = $item.Title
                MediaType = $item.MediaType
                Verified  = [bool]$item.Verified
                Episodes  = @()
                AddedAt   = $addedAt
            }
        }

        $entry = $merged[$key]
        $entry.Verified = $entry.Verified -and [bool]$item.Verified
        foreach ($episode in @($item.Episodes | Where-Object { $null -ne $_ })) {
            $known = @($entry.Episodes | Where-Object { $_.Season -eq $episode.Season -and $_.Episode -eq $episode.Episode })
            if ($known.Count -eq 0) {
                $entry.Episodes += [PSCustomObject]@{ Season = [int]$episode.Season; Episode = [int]$episode.Episode }
            }
        }
    }

    return @($merged.Values)
}

function Split-SAKodiPending {
    <#
    .SYNOPSIS
        Separates entries to retry from entries past the age limit. Pure function.
    .PARAMETER Entries
        Pending entries.
    .PARAMETER Now
        Current time.
    .OUTPUTS
        PSCustomObject with Keep and Expired.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    $keep = @()
    $expired = @()
    foreach ($entry in @($Entries | Where-Object { $null -ne $_ })) {
        # An unreadable date is kept: losing a title is worse than one more retry. The next
        # save restamps it.
        $addedAt = [datetimeoffset]::MinValue
        $hasDate = if ($entry.AddedAt -is [datetime]) {
            $addedAt = [datetimeoffset]$entry.AddedAt
            $true
        } else {
            [datetimeoffset]::TryParse("$($entry.AddedAt)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$addedAt)
        }

        if ($hasDate -and ($Now.ToUniversalTime() - $addedAt.UtcDateTime).TotalDays -ge $script:SAConstants.KodiPendingMaxAgeDays) {
            $expired += $entry
        } else {
            $keep += $entry
        }
    }

    return [PSCustomObject]@{ Keep = $keep; Expired = $expired }
}

function ConvertTo-SAKodiHost {
    <#
    .SYNOPSIS
        Parses one kodi.host entry. Pure function.
    .PARAMETER Entry
        A host name or address, optionally followed by :port. IPv6 with a port is written
        in brackets, as in a URL.
    .PARAMETER DefaultPort
        Port for an entry that names none.
    .OUTPUTS
        PSCustomObject with Name (ready for a URL), Port, Label (the entry as written) and
        Key (safe as a folder name), or $null when the entry cannot be used.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Entry,

        [Parameter(Mandatory = $true)]
        [int]$DefaultPort
    )

    $label = "$Entry".Trim()
    if ($label -eq '' -or $label -match '[\s/\\@?#]') {
        return $null
    }

    $name = $label
    $port = "$DefaultPort"
    if ($label -match '^\[([0-9A-Fa-f:.%]+)\](?::(\d*))?$') {
        $name = "[$($Matches[1])]"
        if ($null -ne $Matches[2]) { $port = $Matches[2] }
    } elseif ($label -match '^[^:\[\]]+:(\d*)$') {
        $name = $label.Substring(0, $label.LastIndexOf(':'))
        $port = $Matches[1]
    } elseif ($label -match '^[0-9A-Fa-f:.%]+$' -and $label.Contains(':')) {
        $name = "[$label]"
    } elseif ($label -match '[:\[\]]') {
        return $null
    }

    $number = 0
    if (-not [int]::TryParse($port, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        return $null
    }

    return [PSCustomObject]@{
        Name  = $name
        Port  = $number
        Label = $label
        Key   = ("$($name.Trim('[', ']'))_$number".ToLowerInvariant() -replace '[^a-z0-9._-]', '-')
    }
}

function Get-SAKodiHosts {
    <#
    .SYNOPSIS
        Lists the Kodi hosts to update, once each. Pure function.
    .DESCRIPTION
        kodi.host is one host or a list. A list is for devices that each keep their own
        library; devices sharing one database need only one of them. Unusable entries are
        left out here and reported by Test-SAKodiConfig.
    .PARAMETER Config
        Full configuration hashtable.
    .OUTPUTS
        PSCustomObject[] from ConvertTo-SAKodiHost.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    # Kodi's own default, for a config that sets no port at all
    $defaultPort = 8080
    if ($null -ne $Config.kodi.port -and "$($Config.kodi.port)" -match '^\d+$') {
        $defaultPort = [int]$Config.kodi.port
    }

    $seen = @{}
    foreach ($entry in @($Config.kodi.host)) {
        $parsed = ConvertTo-SAKodiHost -Entry $entry -DefaultPort $defaultPort
        if ($null -eq $parsed -or $seen.ContainsKey($parsed.Key)) {
            continue
        }
        $seen[$parsed.Key] = $true
        $parsed
    }
}

function Get-SAKodiTimeoutSeconds {
    <#
    .SYNOPSIS
        Reads kodi.timeoutSeconds. Pure function.
    .OUTPUTS
        [int], the default when the setting is absent, or $null when it is not a whole
        number of at least 1.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $value = $Config.kodi.timeoutSeconds
    if ($null -eq $value) {
        return [int]$script:SAConstants.KodiRequestTimeoutSeconds
    }
    if (($value -is [int] -or $value -is [long]) -and $value -ge 1 -and $value -le [int]::MaxValue) {
        return [int]$value
    }
    return $null
}

function Test-SAKodiConfig {
    <#
    .SYNOPSIS
        Lists problems with the [kodi] section. Pure function.
    .DESCRIPTION
        Deliberately separate from config validation, which aborts before a job is queued:
        a Kodi typo must only disable this step, never stop a torrent being processed.
    .PARAMETER Config
        Full configuration hashtable.
    .OUTPUTS
        String array of problems, empty when usable.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $problems = @()
    $entries = @(@($Config.kodi.host) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($entries.Count -eq 0) {
        $problems += 'kodi.host is empty'
    }
    foreach ($entry in $entries) {
        if ($null -eq (ConvertTo-SAKodiHost -Entry $entry -DefaultPort 80)) {
            $problems += "kodi.host entry `"$($entry.Trim())`" is not a host name or host:port"
        }
    }
    if ($null -ne $Config.kodi.timeoutSeconds -and $null -eq (Get-SAKodiTimeoutSeconds -Config $Config)) {
        $problems += 'kodi.timeoutSeconds must be a whole number of seconds, at least 1'
    }
    $entered = @(@($Config.kodi.pathMap) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (@(Get-SAKodiPathMap -PathMap $Config.kodi.pathMap).Count -ne $entered.Count) {
        $problems += 'kodi.pathMap has an entry that is not "arrPath|kodiPath"'
    }

    return $problems
}

function Get-SAKodiTargets {
    <#
    .SYNOPSIS
        Lists the titles one import touched. Pure function.
    .DESCRIPTION
        Works per file rather than from ArrMetadata, which only describes the first file:
        a pack can hold several titles, and each needs its own scan. Episodes stay with
        their show because two shows in one job can share an episode number.

        Verified is true only when Radarr/Sonarr history confirmed specific items. Without
        that, the list is what was sent for import, not what landed.

        Runs for every import, after the files have moved, so a failure here must not reach
        the job: it returns nothing instead.
    .PARAMETER ImportableFiles
        Scan files sent for import, each carrying .movie or .series and .episodes.
    .PARAMETER AppType
        'Radarr' or 'Sonarr'.
    .PARAMETER Verification
        Optional result from Get-SAImportVerification (uses its .Records).
    .OUTPUTS
        PSCustomObject[] with RootPath, Title, MediaType, Episodes, Verified.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ImportableFiles,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,

        [Parameter()]
        [AllowNull()]
        [object]$Verification
    )

    try {
    $idField = if ($AppType -eq 'Sonarr') { 'episodeId' } else { 'movieId' }
    $confirmedIds = @{}
    if ($null -ne $Verification) {
        foreach ($record in @($Verification.Records)) {
            if ($null -ne $record -and $null -ne $record.$idField) {
                $confirmedIds["$($record.$idField)"] = $true
            }
        }
    }
    $verified = $confirmedIds.Count -gt 0

    $targets = [ordered]@{}
    foreach ($file in @($ImportableFiles)) {
        if ($null -eq $file) {
            continue
        }

        $media = if ($AppType -eq 'Sonarr') { $file.series } else { $file.movie }
        if ($null -eq $media -or [string]::IsNullOrWhiteSpace($media.path)) {
            continue
        }

        $episodes = @()
        if ($AppType -eq 'Sonarr') {
            foreach ($episode in @($file.episodes)) {
                if ($null -eq $episode -or ($verified -and -not $confirmedIds.ContainsKey("$($episode.id)"))) {
                    continue
                }
                $episodes += [PSCustomObject]@{
                    Season  = [int]$episode.seasonNumber
                    Episode = [int]$episode.episodeNumber
                }
            }
            if ($verified -and $episodes.Count -eq 0) {
                continue
            }
        } elseif ($verified -and -not $confirmedIds.ContainsKey("$($media.id)")) {
            continue
        }

        $key = $media.path.ToLowerInvariant()
        if (-not $targets.Contains($key)) {
            $targets[$key] = [PSCustomObject]@{
                RootPath  = $media.path
                Title     = $media.title
                MediaType = if ($AppType -eq 'Sonarr') { 'tv' } else { 'movie' }
                Episodes  = @()
                Verified  = $verified
            }
        }
        $targets[$key].Episodes += $episodes
    }

    return @($targets.Values)
    } catch {
        Write-SAVerbose -Text "Kodi targets could not be built: $($_.Exception.Message)"
        return @()
    }
}

function Test-SAKodiStepNeeded {
    <#
    .SYNOPSIS
        Decides whether a job should update Kodi. Pure function.
    .DESCRIPTION
        Also true for an import reported as failed for an unknown reason. The usual cause
        is Stagearr's wait timing out on a long copy, and Radarr/Sonarr then finish the
        import regardless. Nothing else would tell Kodi, and a scan is harmless if the file
        never arrived. Medusa results carry no targets.
    .PARAMETER ImportResult
        Result object from Invoke-SAImport.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ImportResult
    )

    if ($null -eq $ImportResult -or $ImportResult.Skipped -eq $true -or $null -eq $ImportResult.KodiTargets) {
        return $false
    }
    if ($ImportResult.Success -eq $true) {
        return ($null -eq $ImportResult.ImportedCount -or $ImportResult.ImportedCount -ne 0)
    }
    return ($ImportResult.ErrorType -eq 'unknown')
}

#endregion

#region JSON-RPC

function Invoke-SAKodiRpc {
    <#
    .SYNOPSIS
        Calls one Kodi JSON-RPC method. Never throws.
    .DESCRIPTION
        Always a single attempt: a retried VideoLibrary.Scan that Kodi did receive would
        cancel the scan it started. The body is pre-serialized because Invoke-SAWebRequest
        only encodes hashtables and objects, and the charset is explicit so titles with
        accents survive on every supported PowerShell version.
    .PARAMETER Config
        Full configuration hashtable.
    .PARAMETER Method
        JSON-RPC method name.
    .PARAMETER Params
        Method parameters.
    .PARAMETER TimeoutSeconds
        Overrides kodi.timeoutSeconds, for a call that waits on something slower than Kodi.
    .OUTPUTS
        PSCustomObject with Success, Result, Unreachable, Rejected, ErrorMessage.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter()]
        [hashtable]$Params = @{},

        [Parameter()]
        [int]$TimeoutSeconds = 0
    )

    # Kodi answers ordinary calls in well under a second, so a short limit finds a device
    # that is off quickly. An invalid setting is reported by Test-SAKodiConfig.
    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = Get-SAKodiTimeoutSeconds -Config $Config
        if ($TimeoutSeconds -le 0) {
            $TimeoutSeconds = $script:SAConstants.KodiRequestTimeoutSeconds
        }
    }

    $kodi = $Config.kodi
    $scheme = if ($kodi.ssl -eq $true) { 'https' } else { 'http' }
    $uri = "${scheme}://$($kodi.host):$($kodi.port)/jsonrpc"

    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($kodi.username)) {
        $credential = [Text.Encoding]::UTF8.GetBytes("$($kodi.username):$($kodi.password)")
        $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String($credential)
    }

    $body = @{
        jsonrpc = '2.0'
        id      = 1
        method  = $Method
        params  = $Params
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $response = Invoke-SAWebRequest -Uri $uri -Method POST -Headers $headers -Body $body `
            -ContentType 'application/json; charset=utf-8' -MaxRetries 1 `
            -TimeoutSeconds $TimeoutSeconds
    } catch {
        return [PSCustomObject]@{
            Success      = $false
            Result       = $null
            Unreachable  = $true
            Rejected     = $false
            ErrorMessage = $_.Exception.Message
        }
    }

    if (-not $response.Success) {
        $hasStatus = $null -ne $response.StatusCode -and $response.StatusCode -ne 0
        $rejected = $response.StatusCode -in @(401, 403)
        $message = if ($rejected) {
            'Kodi rejected the request: authentication failed'
        } else {
            $response.ErrorMessage
        }
        return [PSCustomObject]@{
            Success      = $false
            Result       = $null
            Unreachable  = -not $hasStatus
            Rejected     = $rejected
            ErrorMessage = $message
        }
    }

    if ($null -ne $response.Data.error) {
        return [PSCustomObject]@{
            Success      = $false
            Result       = $null
            Unreachable  = $false
            Rejected     = $false
            ErrorMessage = "Kodi returned an error: $($response.Data.error.message)"
        }
    }

    return [PSCustomObject]@{
        Success      = $true
        Result       = $response.Data.result
        Unreachable  = $false
        Rejected     = $false
        ErrorMessage = $null
    }
}

#endregion

#region Library Update

# Hosts that could not be reached, so a queue of jobs behind a sleeping device does not pay
# the timeout once each. Kept per host, because one device being off says nothing about the
# others. Lives for the worker run: Reset-SAJobState leaves it alone on purpose, and a new
# worker tries again.
$script:SAKodiUnreachable = @{}

function Reset-SAKodiBreaker {
    <#
    .SYNOPSIS
        Clears the unreachable flag.
    #>
    [CmdletBinding()]
    param()

    $script:SAKodiUnreachable = @{}
}

function Get-SAKodiPendingPath {
    <#
    .SYNOPSIS
        Path of the pending list. In queueRoot so it survives restarts with the job queue.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )

    return Join-Path -Path $QueueRoot -ChildPath 'kodi-pending.json'
}

function Read-SAKodiPending {
    <#
    .SYNOPSIS
        Reads the pending list. A missing file counts as empty.
    .DESCRIPTION
        An unreadable file throws. Reading it as empty would let the next save delete
        titles that are still waiting.
    .OUTPUTS
        PSCustomObject[] of entries.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )

    $path = Get-SAKodiPendingPath -QueueRoot $QueueRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }

    $entries = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    return @($entries | Where-Object { $null -ne $_ -and $_.RootPath -is [string] -and -not [string]::IsNullOrWhiteSpace($_.RootPath) })
}

function Save-SAKodiPending {
    <#
    .SYNOPSIS
        Writes the pending list, or removes the file when it is empty.
    .OUTPUTS
        [bool] true when saved, so a warning never promises a retry that was not stored.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,

        [Parameter()]
        [AllowNull()]
        [object[]]$Entries
    )

    $path = Get-SAKodiPendingPath -QueueRoot $QueueRoot
    $items = @($Entries | Where-Object { $null -ne $_ })
    try {
        if ($items.Count -eq 0) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        } else {
            $folder = Split-Path -Path $path -Parent
            if (-not (Test-Path -LiteralPath $folder)) {
                $null = New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop
            }
            Write-SAFileAtomicUtf8NoBom -Path $path -Content (ConvertTo-Json -InputObject $items -Depth 6)
        }
        return $true
    } catch {
        Write-SAVerbose -Text "Kodi pending list not saved: $($_.Exception.Message)"
        return $false
    }
}

function Get-SAKodiBudgetSeconds {
    <#
    .SYNOPSIS
        Time one job may spend on Kodi. Pure function.
    .PARAMETER ItemCount
        Number of movies and episodes in the job.
    .PARAMETER TitleCount
        Number of titles, each of which needs its own scan and clean.
    .OUTPUTS
        Seconds.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ItemCount,

        [Parameter(Mandatory = $true)]
        [int]$TitleCount
    )

    $constants = $script:SAConstants
    $budget = $constants.KodiBudgetBaseSeconds + ($ItemCount * $constants.KodiBudgetPerItemSeconds) +
        (($TitleCount - 1) * $constants.KodiBudgetPerTitleSeconds)
    return [Math]::Min($budget, $constants.KodiBudgetMaxSeconds)
}

function Get-SAKodiElapsedSeconds {
    <#
    .SYNOPSIS
        Whole seconds on a stopwatch. Separate so tests can drive the clock.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Timer
    )

    return [int]$Timer.Elapsed.TotalSeconds
}

function Get-SAKodiScanState {
    <#
    .SYNOPSIS
        Reads whether Kodi is scanning or cleaning.
    .OUTPUTS
        'Idle', 'Busy', 'Unreachable' or 'Error'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $response = Invoke-SAKodiRpc -Config $Config -Method 'XBMC.GetInfoBooleans' -Params @{ booleans = @('Library.IsScanningVideo') }
    if ($response.Unreachable) {
        return 'Unreachable'
    }
    if (-not $response.Success) {
        return 'Error'
    }
    if ($response.Result.'Library.IsScanningVideo' -eq $true) {
        return 'Busy'
    }
    return 'Idle'
}

function Wait-SAKodiIdle {
    <#
    .SYNOPSIS
        Waits for Kodi to stop scanning, within the job's budget.
    .OUTPUTS
        'Idle', 'Busy' (budget ran out), 'Unreachable' or 'Error'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Timer,

        [Parameter(Mandatory = $true)]
        [int]$BudgetSeconds
    )

    while ($true) {
        $state = Get-SAKodiScanState -Config $Config
        if ($state -ne 'Busy' -or (Get-SAKodiElapsedSeconds -Timer $Timer) -ge $BudgetSeconds) {
            return $state
        }
        Start-Sleep -Seconds $script:SAConstants.KodiPollSeconds
    }
}

function Resolve-SAKodiDirectory {
    <#
    .SYNOPSIS
        Finds a title folder in Kodi's own listing of its parent.
    .DESCRIPTION
        Scanning a built string is unsafe: a missing slash or a spelling difference still
        returns OK. Kodi's listing gives the form it will store, and proves the folder
        exists and that Kodi can reach the share.
    .OUTPUTS
        PSCustomObject with Status ('Found', 'Missing', 'ListFailed', 'NoAnswer', 'Rejected'),
        Path and ErrorMessage. Missing means Kodi listed the parent and the folder is not
        there. A share that is down gives ListFailed, because Kodi reports it as an error.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Leaf
    )

    # A listing waits on the file share, which can take seconds to wake, so it gets far
    # longer than an ordinary call
    $response = Invoke-SAKodiRpc -Config $Config -Method 'Files.GetDirectory' -Params @{ directory = $Parent; media = 'files' } `
        -TimeoutSeconds $script:SAConstants.KodiListTimeoutSeconds
    if ($response.Unreachable) {
        return [PSCustomObject]@{ Status = 'NoAnswer'; Path = $null; ErrorMessage = $response.ErrorMessage }
    }
    if ($response.Rejected) {
        return [PSCustomObject]@{ Status = 'Rejected'; Path = $null; ErrorMessage = $response.ErrorMessage }
    }

    if (-not $response.Success) {
        return [PSCustomObject]@{ Status = 'ListFailed'; Path = $null; ErrorMessage = $response.ErrorMessage }
    }

    $separator = Get-SAKodiPathSeparator -Path $Parent
    foreach ($entry in @($response.Result.files)) {
        if ($null -eq $entry -or $entry.filetype -eq 'file') {
            continue
        }
        $name = ($entry.file.TrimEnd('/', '\') -split '[/\\]')[-1]
        if ($name -ieq $Leaf) {
            return [PSCustomObject]@{ Status = 'Found'; Path = $entry.file.TrimEnd('/', '\') + $separator; ErrorMessage = $null }
        }
    }

    return [PSCustomObject]@{ Status = 'Missing'; Path = $null; ErrorMessage = $null }
}

function Get-SAKodiSources {
    <#
    .SYNOPSIS
        Reads Kodi's video sources.
    .OUTPUTS
        PSCustomObject with Status ('OK', 'Unreachable', 'Rejected', 'Failed'), Sources and
        ErrorMessage. On 'Failed' the job can still go on with kodi.pathMap.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $response = Invoke-SAKodiRpc -Config $Config -Method 'Files.GetSources' -Params @{ media = 'video' }
    $status = if ($response.Unreachable) { 'Unreachable' }
    elseif ($response.Rejected) { 'Rejected' }
    elseif (-not $response.Success) { 'Failed' }
    else { 'OK' }

    $sources = @()
    if ($response.Success) {
        $sources = @($response.Result.sources | Where-Object { $null -ne $_ } | ForEach-Object { $_.file })
    }

    return [PSCustomObject]@{ Status = $status; Sources = $sources; ErrorMessage = $response.ErrorMessage }
}

function Resolve-SAKodiLocation {
    <#
    .SYNOPSIS
        Finds where Kodi sees a title, from kodi.pathMap or by matching its sources.
    .DESCRIPTION
        Only the best-scoring sources are considered. A weaker source can hold a same-named
        folder, and scanning that would pass the library check on its old entry while the
        real title never reaches Kodi. For the same reason a title found under two equally
        good sources is refused, and any failed listing stops the search.
    .OUTPUTS
        PSCustomObject with Status ('Found', 'Unmatched', 'Missing', 'Ambiguous', 'ListFailed',
        'NoAnswer', 'Rejected'), Path and ErrorMessage.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$ArrPath,

        [Parameter()]
        [AllowNull()]
        [object[]]$PathMap,

        [Parameter()]
        [AllowNull()]
        [string[]]$Sources
    )

    $mapped = ConvertTo-SAKodiPath -ArrPath $ArrPath -PathMap $PathMap
    $candidates = if ($null -ne $mapped) {
        @([PSCustomObject]@{ Parent = Set-SAKodiSourceSpelling -Path $mapped.Parent -Sources $Sources; Leaf = $mapped.Leaf; Score = 0 })
    } else {
        @(Get-SAKodiPathCandidates -ArrPath $ArrPath -Sources $Sources)
    }

    if ($candidates.Count -eq 0) {
        return [PSCustomObject]@{ Status = 'Unmatched'; Path = $null; ErrorMessage = $null }
    }

    $bestScore = ($candidates | Measure-Object -Property Score -Maximum).Maximum
    $found = @()
    foreach ($candidate in @($candidates | Where-Object { $_.Score -eq $bestScore })) {
        $resolved = Resolve-SAKodiDirectory -Config $Config -Parent $candidate.Parent -Leaf $candidate.Leaf
        if ($resolved.Status -in @('ListFailed', 'NoAnswer', 'Rejected')) {
            return $resolved
        }
        if ($resolved.Status -eq 'Found') {
            $found += $resolved
        }
    }

    if ($found.Count -eq 1) {
        return $found[0]
    }
    $status = if ($found.Count -gt 1) { 'Ambiguous' } else { 'Missing' }
    return [PSCustomObject]@{ Status = $status; Path = $null; ErrorMessage = $null }
}

function Get-SAKodiMissingItems {
    <#
    .SYNOPSIS
        Lists a target's items that are not in the Kodi library.
    .DESCRIPTION
        Without a confirmed episode list there is nothing specific to look for, so a show
        counts as present once it has any episode under its folder.
    .OUTPUTS
        PSCustomObject with Success and Missing (labels).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$KodiPath
    )

    $filter = @{ field = 'path'; operator = 'startswith'; value = $KodiPath }

    if ($Target.MediaType -eq 'movie') {
        $response = Invoke-SAKodiRpc -Config $Config -Method 'VideoLibrary.GetMovies' -Params @{ filter = $filter; limits = @{ end = 1 } }
        if (-not $response.Success) {
            return [PSCustomObject]@{ Success = $false; Missing = @() }
        }
        $missing = if ([int]$response.Result.limits.total -gt 0) { @() } else { @($Target.Title) }
        return [PSCustomObject]@{ Success = $true; Missing = $missing }
    }

    $response = Invoke-SAKodiRpc -Config $Config -Method 'VideoLibrary.GetEpisodes' -Params @{ filter = $filter; properties = @('season', 'episode') }
    if (-not $response.Success) {
        return [PSCustomObject]@{ Success = $false; Missing = @() }
    }

    $present = @{}
    foreach ($episode in @($response.Result.episodes)) {
        if ($null -ne $episode) {
            $present["$($episode.season):$($episode.episode)"] = $true
        }
    }

    $missing = @()
    if (@($Target.Episodes).Count -eq 0) {
        if ($present.Count -eq 0) {
            $missing = @($Target.Title)
        }
    } else {
        foreach ($episode in @($Target.Episodes)) {
            if (-not $present.ContainsKey("$($episode.Season):$($episode.Episode)")) {
                $missing += '{0} S{1:00}E{2:00}' -f $Target.Title, $episode.Season, $episode.Episode
            }
        }
    }

    return [PSCustomObject]@{ Success = $true; Missing = $missing }
}

function Invoke-SAKodiTargetUpdate {
    <#
    .SYNOPSIS
        Scans one title and checks the result.
    .DESCRIPTION
        The library check waits for Kodi to go idle first. On an upgrade the old entry
        already matches the title's folder, so checking earlier would pass before the scan
        has done anything.

        Retry marks a reason that may pass by itself. A title Kodi refused or a mapping
        problem would fail the same way again.
    .OUTPUTS
        PSCustomObject with Status ('Updated', 'Missing', 'Skipped', 'Unreachable'), Reason,
        Retry, Missing and Gone (Kodi listed the parent and the folder is not there).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter()]
        [AllowNull()]
        [object[]]$PathMap,

        [Parameter()]
        [AllowNull()]
        [string[]]$Sources,

        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Timer,

        [Parameter(Mandatory = $true)]
        [int]$BudgetSeconds
    )

    $result = {
        param($Status, $Reason = $null, $Retry = $false, $Missing = @(), $Gone = $false)
        [PSCustomObject]@{ Status = $Status; Reason = $Reason; Retry = $Retry; Missing = @($Missing); Gone = $Gone }
    }

    # The idle check comes first because it is the cheap call that proves Kodi is up. A
    # listing can time out on a spun-down share while Kodi itself is fine, so a listing
    # that gets no answer must not count as an outage.
    $idleResult = {
        param($State)
        switch ($State) {
            'Unreachable' { return & $result 'Unreachable' 'Kodi is unreachable' $true }
            'Busy' { return & $result 'Skipped' 'Kodi was still busy when the time limit ran out' $true }
            'Error' { return & $result 'Skipped' 'Kodi would not report its scan state' $true }
        }
    }

    $blocked = & $idleResult (Wait-SAKodiIdle -Config $Config -Timer $Timer -BudgetSeconds $BudgetSeconds)
    if ($null -ne $blocked) {
        return $blocked
    }

    $resolved = Resolve-SAKodiLocation -Config $Config -ArrPath $Target.RootPath -PathMap $PathMap -Sources $Sources
    switch ($resolved.Status) {
        'NoAnswer' { return & $result 'Skipped' 'Kodi did not list its folder in time' $true }
        'Rejected' { return & $result 'Skipped' $resolved.ErrorMessage }
        'ListFailed' { return & $result 'Skipped' 'Kodi could not list its folder' $true }
        'Unmatched' {
            if (@($Sources).Count -eq 0) {
                return & $result 'Skipped' 'Kodi did not list its sources' $true
            }
            return & $result 'Skipped' 'no Kodi source matches its folder (add the source in Kodi, or set kodi.pathMap)'
        }
        'Ambiguous' { return & $result 'Skipped' 'more than one Kodi source holds its folder (set kodi.pathMap)' }
        # An unconfirmed import may still be copying, so its folder can appear later
        'Missing' { return & $result 'Skipped' 'Kodi cannot see its folder (check kodi.pathMap)' (-not $Target.Verified) @() $true }
    }

    # The listing took time, and a scan sent into a running scan cancels both
    $blocked = & $idleResult (Wait-SAKodiIdle -Config $Config -Timer $Timer -BudgetSeconds $BudgetSeconds)
    if ($null -ne $blocked) {
        return $blocked
    }

    if ((Get-SAKodiElapsedSeconds -Timer $Timer) -ge $BudgetSeconds) {
        return & $result 'Skipped' 'the time limit ran out before its scan' $true
    }

    $scan = Invoke-SAKodiRpc -Config $Config -Method 'VideoLibrary.Scan' -Params @{ directory = $resolved.Path; showdialogs = $false }
    if ($scan.Unreachable) {
        # Kodi may have received it, so neither "scanned" nor "not scanned" is known
        if ((Get-SAKodiScanState -Config $Config) -eq 'Unreachable') {
            return & $result 'Unreachable' 'Kodi is unreachable' $true
        }
        return & $result 'Missing' 'Kodi did not answer the scan request, so it is not confirmed' $true @($Target.Title)
    }
    if (-not $scan.Success) {
        return & $result 'Skipped' $scan.ErrorMessage
    }

    Start-Sleep -Seconds $script:SAConstants.KodiPollSeconds
    $state = Wait-SAKodiIdle -Config $Config -Timer $Timer -BudgetSeconds $BudgetSeconds
    if ($state -eq 'Unreachable') {
        return & $result 'Unreachable' 'Kodi is unreachable' $true
    }
    if ($state -ne 'Idle') {
        # Judging now would pass an upgrade on its old entry, or fail a new title too early
        return & $result 'Missing' 'scan sent, but Kodi was still busy, so it is not confirmed' $true @($Target.Title)
    }

    $check = Get-SAKodiMissingItems -Config $Config -Target $Target -KodiPath $resolved.Path
    $graceEnd = (Get-SAKodiElapsedSeconds -Timer $Timer) + $script:SAConstants.KodiVerifyGraceSeconds
    while ($check.Success -and @($check.Missing).Count -gt 0 -and (Get-SAKodiElapsedSeconds -Timer $Timer) -lt $graceEnd) {
        Start-Sleep -Seconds $script:SAConstants.KodiPollSeconds
        $check = Get-SAKodiMissingItems -Config $Config -Target $Target -KodiPath $resolved.Path
    }

    if (-not $check.Success) {
        return & $result 'Missing' 'could not be confirmed in Kodi' $true @($Target.Title)
    }
    if (@($check.Missing).Count -gt 0) {
        $reason = if ($Target.Verified) { 'not found in Kodi after the scan' } else { 'not found in Kodi after the scan, and it may not have imported' }
        return & $result 'Missing' $reason $false $check.Missing
    }
    return & $result 'Updated'
}

function Invoke-SAKodiStep {
    <#
    .SYNOPSIS
        The pipeline's Kodi step: gates, update and reporting. Never throws.
    .DESCRIPTION
        Everything sits inside one try/catch, gates included, because the import has already
        happened and nothing here may change the job outcome.

        Only a title Kodi refused is a Warning, because that event turns the email amber. A
        skip that sorts itself out uses Skip level with an Info note, so a sleeping HTPC does
        not do that to every job.
    .PARAMETER Context
        Processing context.
    .PARAMETER JobId
        Job id, for progress reporting.
    .PARAMETER ImportResult
        Result object from Invoke-SAImport.
    .OUTPUTS
        'Updated', 'Partial' or 'Skipped' for the Pushover message, or nothing when the
        step did not run or had nothing to report.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [Parameter()]
        [AllowNull()]
        [object]$ImportResult
    )

    try {
        if (-not (Test-SAFeatureEnabled -Feature 'Kodi' -Config $Context.Config)) {
            return
        }

        $config = $Context.Config
        $queueRoot = $Context.Paths.QueueRoot
        $needed = Test-SAKodiStepNeeded -ImportResult $ImportResult
        $targets = if ($needed) { @($ImportResult.KodiTargets) } else { @() }

        # A config problem is reported once, and no retry list is touched while the host
        # list cannot be trusted
        if (@(Test-SAKodiConfig -Config $config).Count -gt 0) {
            if (-not $needed) {
                return
            }
            $kodiResult = Invoke-SAKodiUpdate -Config $config -Targets $targets
        } else {
            # Each host keeps its own retry list, in a folder of its own
            $runs = @(foreach ($kodiHost in @(Get-SAKodiHosts -Config $config)) {
                    $hostConfig = $config.Clone()
                    $hostConfig.kodi = $config.kodi.Clone()
                    $hostConfig.kodi.host = $kodiHost.Name
                    $hostConfig.kodi.port = $kodiHost.Port
                    [PSCustomObject]@{
                        Label     = $kodiHost.Label
                        Config    = $hostConfig
                        QueueRoot = Join-Path -Path (Join-Path -Path $queueRoot -ChildPath 'kodi') -ChildPath $kodiHost.Key
                    }
                })

            # A job with nothing of its own still clears waiting titles, so a quiet stretch of
            # skipped imports does not leave them waiting
            if (-not $needed) {
                $runs = @($runs | Where-Object { Test-Path -LiteralPath (Get-SAKodiPendingPath -QueueRoot $_.QueueRoot) })
            }
            if ($runs.Count -eq 0) {
                return
            }

            Update-SAJobProgress -QueueRoot $queueRoot -JobId $JobId -Phase 'Import' -Activity 'Updating Kodi...'
            $results = @(foreach ($run in $runs) {
                    $text = if ($runs.Count -gt 1) { "Scanning $($run.Label)..." } else { 'Scanning...' }
                    Write-SAProgress -Label 'Kodi' -Text $text -Indent 1 -ConsoleOnly
                    [PSCustomObject]@{
                        Label  = $run.Label
                        Result = Invoke-SAKodiUpdate -Config $run.Config -Targets $targets -QueueRoot $run.QueueRoot
                    }
                })
            $kodiResult = Join-SAKodiResults -Results $results
        }

        switch ($kodiResult.Status) {
            'Updated' {
                $headline = if ($kodiResult.Summary) { $kodiResult.Summary } else { $kodiResult.Text }
                Write-SAOutcome -Level Success -Label 'Kodi' -Text $headline -Duration $kodiResult.Duration -Indent 1 -EmailInclude
                if ($kodiResult.Notes) {
                    Add-SAEmailException -Message "Kodi: $($kodiResult.Notes)" -Type Info
                }
                return 'Updated'
            }
            'Partial' {
                Write-SAOutcome -Level Warning -Label 'Kodi' -Text 'Not everything reached Kodi' -Duration $kodiResult.Duration -Indent 1
                Add-SAEmailException -Message "Kodi: $($kodiResult.Text)" -Type Warning
                return 'Partial'
            }
            'Idle' {
                Write-SAVerbose -Text 'Kodi: nothing to report'
            }
            default {
                Write-SAOutcome -Level Skip -Label 'Kodi' -Text 'Not scanned' -Indent 1
                Add-SAEmailException -Message "Kodi: $($kodiResult.Text)" -Type Info
                return 'Skipped'
            }
        }
    } catch {
        Write-SAVerbose -Text "Kodi step failed: $($_.Exception.Message)"
        Write-SAOutcome -Level Skip -Label 'Kodi' -Text 'Not scanned' -Indent 1
        Add-SAEmailException -Message 'Kodi: update failed, so the title stays out of Kodi until a scan runs' -Type Info
        return 'Skipped'
    }
}

function Join-SAKodiResults {
    <#
    .SYNOPSIS
        Combines the results of several Kodi hosts into one. Pure function.
    .DESCRIPTION
        One host passes through unchanged. With several, every line names its host, hosts
        with nothing to report are left out, and the worst outcome sets the status.
    .PARAMETER Results
        PSCustomObject[] with Label and Result (from Invoke-SAKodiUpdate).
    .OUTPUTS
        PSCustomObject shaped like Invoke-SAKodiUpdate's result.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results
    )

    if ($Results.Count -eq 1) {
        return $Results[0].Result
    }

    $active = @($Results | Where-Object { $_.Result.Status -ne 'Idle' })
    $summary = @($active | Where-Object { $_.Result.Summary } | ForEach-Object { "$($_.Label): $($_.Result.Summary)" }) -join '; '
    $notes = @($active | Where-Object { $_.Result.Notes } | ForEach-Object { "$($_.Label): $($_.Result.Notes)" }) -join '; '
    $statuses = @($active | ForEach-Object { $_.Result.Status })
    $status = 'Idle'
    foreach ($candidate in @('Partial', 'Updated', 'Skipped')) {
        if ($statuses -contains $candidate) {
            $status = $candidate
            break
        }
    }

    $duration = 0
    foreach ($item in $Results) {
        $duration += [int]$item.Result.Duration
    }

    return [PSCustomObject]@{
        Status   = $status
        Text     = (@($summary, $notes) | Where-Object { $_ }) -join '; '
        Summary  = if ($summary) { $summary } else { $null }
        Notes    = if ($notes) { $notes } else { $null }
        Missing  = @($Results | ForEach-Object { @($_.Result.Missing) } | Where-Object { $null -ne $_ })
        Duration = $duration
    }
}

function Invoke-SAKodiUpdate {
    <#
    .SYNOPSIS
        Updates Kodi for a job's titles, then retries pending ones. Never throws.
    .DESCRIPTION
        The job's own titles go first. Pending titles only get the time left in the job's
        budget, so a backlog cannot hold up the queue. Entries past the age limit get one
        last try before they are dropped.
    .PARAMETER Config
        Full configuration hashtable.
    .PARAMETER Targets
        Titles from Get-SAKodiTargets.
    .PARAMETER QueueRoot
        Queue folder holding the pending list. Without it, nothing is retried.
    .OUTPUTS
        PSCustomObject with Status ('Updated', 'Partial', 'Skipped', 'Idle'), Text (everything),
        Summary (what worked), Notes (what did not), Missing and Duration. Partial means Kodi
        was reachable and refused something. Idle means nothing worth reporting.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter()]
        [AllowNull()]
        [object[]]$Targets,

        [Parameter()]
        [string]$QueueRoot
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $hostKey = "$($Config.kodi.host):$($Config.kodi.port)".ToLowerInvariant()
    $finish = {
        param($Status, $Summary, $Notes, $Missing = @())
        [PSCustomObject]@{
            Status   = $Status
            Text     = (@($Summary, $Notes) | Where-Object { $_ }) -join '; '
            Summary  = $Summary
            Notes    = $Notes
            Missing  = @($Missing)
            Duration = [int]$timer.Elapsed.TotalSeconds
        }
    }
    $stillNeeded = 'it stays out of Kodi until a scan runs'

    $now = [datetime]::UtcNow
    $own = @($Targets | Where-Object { $null -ne $_ })
    $useQueue = -not [string]::IsNullOrWhiteSpace($QueueRoot)
    $stored = @()
    $listNote = $null
    if ($useQueue) {
        try {
            $stored = @(Read-SAKodiPending -QueueRoot $QueueRoot)
        } catch {
            Write-SAVerbose -Text "Kodi pending list unreadable: $($_.Exception.Message)"
            try {
                $aside = Join-Path -Path $QueueRoot -ChildPath 'kodi-pending.bad.json'
                Move-Item -LiteralPath (Get-SAKodiPendingPath -QueueRoot $QueueRoot) -Destination $aside -Force -ErrorAction Stop
                $listNote = 'the retry list was unreadable and was kept as kodi-pending.bad.json'
            } catch {
                $useQueue = $false
                $listNote = 'the retry list could not be read, so it was left alone'
            }
        }
    }

    # A title being imported again is scanned as the job's own, so the list must not scan it
    # a second time or call it missed. Its waiting episodes are checked along with the new ones.
    $own = @(foreach ($target in $own) {
            $earlier = @($stored | Where-Object { $_.RootPath -ieq $target.RootPath })
            if ($earlier.Count -gt 0) {
                @(Merge-SAKodiPending -Existing $earlier -Add @($target) -Now $now)[0]
            } else {
                $target
            }
        })
    $ownKeys = @{}
    foreach ($target in $own) {
        $ownKeys[$target.RootPath.ToLowerInvariant()] = $true
    }
    $stored = @($stored | Where-Object { -not $ownKeys.ContainsKey($_.RootPath.ToLowerInvariant()) })

    $split = Split-SAKodiPending -Entries $stored -Now $now
    $waiting = @(@($split.Keep) + @($split.Expired) | Where-Object { $null -ne $_ })
    $expiredKeys = @{}
    foreach ($entry in @($split.Expired)) {
        $expiredKeys[$entry.RootPath.ToLowerInvariant()] = $true
    }

    if ($own.Count + $waiting.Count -eq 0 -and -not $listNote) {
        return & $finish 'Idle' $null $null
    }

    $problems = @(Test-SAKodiConfig -Config $Config)
    if ($problems.Count -gt 0) {
        if ($own.Count -eq 0) {
            return & $finish 'Idle' $null $null
        }
        return & $finish 'Skipped' $null "$($problems -join '; '), so $stillNeeded"
    }

    $updated = 0
    $missing = @()
    $caughtUp = @()
    $issues = @()
    $queued = @()
    $untried = @()
    $tried = @()
    $handled = @{}

    $note = {
        param($Title, $Reason, $Retry, $Items = @(), $Final = $false)
        [PSCustomObject]@{ Title = $Title; Reason = $Reason; Retry = $Retry; Items = @($Items); Final = $Final }
    }
    $ageNote = "still not scanned after $($script:SAConstants.KodiPendingMaxAgeDays) days"

    # Leaves an entry on the list, unless this was its last try
    $hold = {
        param($Entry)
        if ($expiredKeys.ContainsKey($Entry.RootPath.ToLowerInvariant())) {
            return @{ Issue = & $note $Entry.Title $ageNote $false }
        }
        return @{ Entry = $Entry }
    }

    try {
        $sources = @()
        $ownReason = $null
        $ownRetry = $true
        if ($script:SAKodiUnreachable[$hostKey]) {
            $ownReason = 'Kodi was unreachable earlier in this run'
        } else {
            $sourceResult = Get-SAKodiSources -Config $Config
            $sources = @($sourceResult.Sources)
            if ($sourceResult.Status -eq 'Unreachable') {
                $script:SAKodiUnreachable[$hostKey] = $true
                $ownReason = 'Kodi is unreachable'
            } elseif ($sourceResult.Status -eq 'Rejected') {
                $ownReason = $sourceResult.ErrorMessage
                $ownRetry = $false
                $untried = $waiting
                $waiting = @()
            }
        }

        if ($null -ne $ownReason) {
            foreach ($target in $own) {
                $issues += & $note $target.Title $ownReason $ownRetry
                if ($ownRetry) {
                    $queued += $target
                }
                $handled[$target.RootPath.ToLowerInvariant()] = $true
            }
        }

        $pathMap = Get-SAKodiPathMap -PathMap $Config.kodi.pathMap
        $itemCount = 0
        foreach ($target in $own) {
            $itemCount += [Math]::Max(1, @($target.Episodes).Count)
        }
        $budget = Get-SAKodiBudgetSeconds -ItemCount ([Math]::Max(1, $itemCount)) -TitleCount ([Math]::Max(1, $own.Count))

        $update = {
            param($Target)
            try {
                Invoke-SAKodiTargetUpdate -Config $Config -Target $Target -PathMap $pathMap -Sources $sources -Timer $timer -BudgetSeconds $budget
            } catch {
                Write-SAVerbose -Text "Kodi update failed: $($_.Exception.Message)"
                [PSCustomObject]@{ Status = 'Skipped'; Reason = 'the update failed'; Retry = $true; Missing = @(); Gone = $false }
            }
        }

        foreach ($target in $own) {
            $key = $target.RootPath.ToLowerInvariant()
            if ($handled.ContainsKey($key)) {
                continue
            }
            $handled[$key] = $true

            if ($script:SAKodiUnreachable[$hostKey]) {
                $issues += & $note $target.Title 'not attempted because Kodi dropped out' $true
                $queued += $target
                continue
            }

            $outcome = & $update $target
            if ($outcome.Status -eq 'Updated') {
                $updated++
                continue
            }
            if ($outcome.Status -eq 'Unreachable') {
                $script:SAKodiUnreachable[$hostKey] = $true
            }
            if ($outcome.Status -eq 'Missing' -and -not $outcome.Retry) {
                $missing += $outcome.Missing
            }
            $issues += & $note $target.Title $outcome.Reason $outcome.Retry $outcome.Missing
            if ($outcome.Retry) {
                $queued += $target
            }
        }

        foreach ($entry in $waiting) {
            $handled[$entry.RootPath.ToLowerInvariant()] = $true
            if ($script:SAKodiUnreachable[$hostKey] -or (Get-SAKodiElapsedSeconds -Timer $timer) -ge $budget) {
                $held = & $hold $entry
                if ($held.Entry) { $untried += $held.Entry } else { $issues += $held.Issue }
                continue
            }

            $outcome = & $update $entry
            if ($outcome.Status -eq 'Updated') {
                $caughtUp += $entry.Title
                continue
            }
            if ($outcome.Status -eq 'Unreachable') {
                $script:SAKodiUnreachable[$hostKey] = $true
            }
            if ($outcome.Retry) {
                # Behind the untried ones, so one stuck title cannot use every job's budget
                $held = & $hold $entry
                if ($held.Entry) { $tried += $held.Entry } else { $issues += $held.Issue }
                continue
            }
            if ($outcome.Gone) {
                $issues += & $note $entry.Title 'dropped from the retry list because its folder no longer exists' $false @() $true
                continue
            }
            if ($outcome.Status -eq 'Missing') {
                $missing += $outcome.Missing
            }
            $issues += & $note $entry.Title $outcome.Reason $false $outcome.Missing
        }
    } catch {
        Write-SAVerbose -Text "Kodi update failed: $($_.Exception.Message)"
        foreach ($target in $own) {
            if (-not $handled.ContainsKey($target.RootPath.ToLowerInvariant())) {
                $issues += & $note $target.Title 'the update failed' $true
                $queued += $target
            }
        }
        foreach ($entry in $waiting) {
            if (-not $handled.ContainsKey($entry.RootPath.ToLowerInvariant())) {
                $untried += $entry
            }
        }
    }

    # A worker that lost the lock must not overwrite what the new worker has written
    $saved = $false
    if ($useQueue) {
        try {
            if (Test-SALockStolen) {
                Write-SAVerbose -Text 'Kodi pending list not saved: lock lost'
            } else {
                $saved = Save-SAKodiPending -QueueRoot $QueueRoot -Entries (Merge-SAKodiPending -Existing (@($untried) + @($tried)) -Add $queued -Now $now)
            }
        } catch {
            Write-SAVerbose -Text "Kodi pending list not saved: $($_.Exception.Message)"
        }
    }

    $done = @()
    if ($updated -eq 1) {
        $done += 'Scanned and confirmed'
    } elseif ($updated -gt 1) {
        $done += "Scanned and confirmed $updated titles"
    }
    if ($caughtUp.Count -gt 0) {
        $done += "Caught up on $($caughtUp -join ', ')"
    }

    $lines = @()
    if ($listNote) {
        $lines += $listNote
    }
    foreach ($issue in $issues) {
        $line = "$($issue.Title): $($issue.Reason)"
        $named = @($issue.Items | Where-Object { $_ -ne $issue.Title })
        if ($named.Count -gt 0) {
            $line += " ($($named -join ', '))"
        }
        if ($issue.Retry -and $saved) {
            $line += '; Stagearr will retry on the next import'
        } elseif ($issue.Retry) {
            $line += "; $stillNeeded"
        } elseif ($issue.Items.Count -eq 0 -and -not $issue.Final) {
            $line += ", so $stillNeeded"
        }
        $lines += $line
    }

    $summary = if ($done.Count -gt 0) { $done -join '; ' } else { $null }
    $notes = if ($lines.Count -gt 0) { $lines -join '; ' } else { $null }

    if ($missing.Count -gt 0) {
        return & $finish 'Partial' $summary $notes $missing
    }
    if ($null -ne $summary) {
        return & $finish 'Updated' $summary $notes
    }
    if ($null -ne $notes) {
        return & $finish 'Skipped' $null $notes
    }
    return & $finish 'Idle' $null $null
}

#endregion
