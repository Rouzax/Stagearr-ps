#Requires -Version 7.0
<#
.SYNOPSIS
    MDBList API client for Stagearr
.DESCRIPTION
    Marks imported items as "collected" / In Library on MDBList after a successful
    import. This populates MDBList's collection so dynamic lists (e.g. "not collected")
    exclude titles you already own.

    Design principles:
    - Opt-in: only runs when [mdblist] enabled with an API key.
    - Best-effort: never throws; a failure is reported to the caller but must never
      fail the overall job (the import already succeeded).
    - Verbose-only mechanics: the chosen IDs and API response go to verbose; the
      API key is never logged.
    - Works on a free MDBList account (no Patreon required).

    Endpoint: POST {base}/sync/collection?apikey=KEY
      Movies: { movies: [ { ids: { tmdb, imdb } } ] }
      TV:     { shows:  [ { ids: { tvdb, tmdb, imdb }, seasons: [ { number, episodes: [ { number } ] } ] } ] }

    API Reference: https://api.mdblist.com/
#>

#region Pure Helper Functions

function New-SAMDBListPayload {
    <#
    .SYNOPSIS
        Builds the MDBList /sync/collection request body. Pure function - no I/O.
    .DESCRIPTION
        Constructs the collection payload from the available external IDs and, for TV,
        the imported (season, episode) pairs.

        - All available IDs are included in the `ids` object (MDBList resolves by any of
          tmdb/tvdb/imdb); numeric IDs are emitted as integers, imdb stays a string.
        - Returns $null when there is nothing useful to send: no usable ID, or a TV
          payload with no episodes.
    .PARAMETER MediaType
        'movie' or 'tv'.
    .PARAMETER Ids
        Hashtable of external IDs: tmdb, tvdb, imdb, trakt (any subset, empty allowed).
    .PARAMETER Episodes
        For TV: array of objects with Season and Episode (int). Ignored for movies and
        when -ShowLevel is set.
    .PARAMETER ShowLevel
        For TV: mark the whole show as collected (a show entry with ids only, no seasons).
        MDBList's list filters ("not collected" etc.) only treat a show as collected when
        it has a show-level entry, so this is used when the show is fully downloaded.
        Episode-level marking (the default) does NOT remove a show from those lists.
    .OUTPUTS
        Hashtable payload ready for ConvertTo-Json, or $null when nothing to send.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('movie', 'tv')]
        [string]$MediaType,

        [Parameter()]
        [hashtable]$Ids = @{},

        [Parameter()]
        [AllowNull()]
        [object]$Episodes,

        [Parameter()]
        [switch]$ShowLevel
    )

    # Build a clean ids object, dropping empty values. Numeric ids (tmdb/tvdb/trakt)
    # become integers; imdb stays a string (e.g. "tt1234567").
    $cleanIds = @{}
    foreach ($key in @('tmdb', 'tvdb', 'trakt')) {
        if ($Ids.ContainsKey($key)) {
            $value = $Ids[$key]
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                $intVal = 0
                if ([int]::TryParse([string]$value, [ref]$intVal) -and $intVal -gt 0) {
                    $cleanIds[$key] = $intVal
                }
            }
        }
    }
    if ($Ids.ContainsKey('imdb')) {
        $imdb = $Ids['imdb']
        if ($null -ne $imdb -and -not [string]::IsNullOrWhiteSpace([string]$imdb)) {
            $cleanIds['imdb'] = [string]$imdb
        }
    }

    if ($cleanIds.Count -eq 0) {
        return $null
    }

    if ($MediaType -eq 'movie') {
        return @{ movies = @(@{ ids = $cleanIds }) }
    }

    # TV, show-level: mark the whole show (ids only, no seasons). This is what makes the
    # show drop off MDBList "not collected" list filters.
    if ($ShowLevel) {
        return @{ shows = @(@{ ids = $cleanIds }) }
    }

    # TV: group imported episodes by season -> distinct, sorted episode numbers
    $epList = @()
    if ($null -ne $Episodes) {
        $epList = @($Episodes | Where-Object { $null -ne $_ })
    }
    if ($epList.Count -eq 0) {
        return $null
    }

    $seasonMap = @{}
    foreach ($ep in $epList) {
        $s = [int]$ep.Season
        $e = [int]$ep.Episode
        if (-not $seasonMap.ContainsKey($s)) {
            $seasonMap[$s] = New-Object System.Collections.Generic.List[int]
        }
        if (-not $seasonMap[$s].Contains($e)) {
            $seasonMap[$s].Add($e)
        }
    }

    $seasons = @()
    foreach ($s in ($seasonMap.Keys | Sort-Object)) {
        $episodeObjs = @($seasonMap[$s] | Sort-Object | ForEach-Object { @{ number = $_ } })
        $seasons += @{ number = $s; episodes = $episodeObjs }
    }

    return @{ shows = @(@{ ids = $cleanIds; seasons = $seasons }) }
}

#endregion

#region Main Entry Point

function Invoke-SAMDBListCollect {
    <#
    .SYNOPSIS
        Marks an imported item as collected on MDBList. Best-effort, never throws.
    .DESCRIPTION
        Called after a successful import. Builds the collection payload from *arr
        metadata (and imported episodes for TV) and POSTs it to MDBList.

        Returns a result object the caller uses to render output:
        - Success = $true             -> marked; Updated = count of updated entries
        - Skipped = $true             -> nothing to do (disabled, no key, no usable ID,
                                          or TV with no episodes); render quietly/verbose
        - Success = $false (not Skipped) -> a real failure; render a non-fatal warning
    .PARAMETER Config
        The [mdblist] config hashtable (enabled, apiKey, timeoutSeconds).
    .PARAMETER ArrMetadata
        Metadata hashtable from the import result (provides ImdbId/TmdbId/TvdbId).
    .PARAMETER MediaType
        'movie' or 'tv'.
    .PARAMETER ImportedEpisodes
        For TV: array of objects with Season and Episode (int). Ignored for movies and
        when -ShowComplete is set.
    .PARAMETER ShowComplete
        For TV: the show is fully downloaded, so mark it at the show level (whole show)
        instead of per-episode. This is what removes a show from MDBList "not collected"
        list filters; per-episode marking does not. Partial shows omit this and stay
        episode-level (accurate, and they remain on "get more" lists).
    .OUTPUTS
        PSCustomObject: Success, Skipped, Updated, ErrorMessage, Duration.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [AllowNull()]
        [hashtable]$Config,

        [Parameter()]
        [AllowNull()]
        [object]$ArrMetadata,

        [Parameter(Mandatory = $true)]
        [ValidateSet('movie', 'tv')]
        [string]$MediaType,

        [Parameter()]
        [AllowNull()]
        [object]$ImportedEpisodes,

        [Parameter()]
        [switch]$ShowComplete
    )

    $startTime = Get-Date
    $elapsed = { [int]((Get-Date) - $startTime).TotalSeconds }

    $makeResult = {
        param([bool]$Ok, [bool]$Skip, [int]$Updated, [string]$ErrMsg)
        [PSCustomObject]@{
            Success      = $Ok
            Skipped      = $Skip
            Updated      = $Updated
            ErrorMessage = $ErrMsg
            Duration     = & $elapsed
        }
    }

    # Config / enablement (defensive - caller already gates on Test-SAFeatureEnabled)
    if ($null -eq $Config -or $Config.enabled -ne $true) {
        Write-SAVerbose -Label 'MDBList' -Text 'Feature disabled in configuration'
        return & $makeResult $false $true 0 ''
    }

    $apiKey = $Config.apiKey
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-SAVerbose -Label 'MDBList' -Text 'No API key configured'
        return & $makeResult $false $true 0 ''
    }

    if ($null -eq $ArrMetadata) {
        Write-SAVerbose -Label 'MDBList' -Text 'No metadata available - skipping'
        return & $makeResult $false $true 0 ''
    }

    # Collect available external IDs from the import metadata
    $ids = @{
        tmdb = $ArrMetadata.TmdbId
        tvdb = $ArrMetadata.TvdbId
        imdb = $ArrMetadata.ImdbId
    }

    # TV: a fully-downloaded show is marked show-level (drops off "not collected" lists);
    # a partial show is marked episode-level (accurate, stays on "get more" lists).
    $useShowLevel = ($MediaType -eq 'tv' -and $ShowComplete)
    $payload = New-SAMDBListPayload -MediaType $MediaType -Ids $ids -Episodes $ImportedEpisodes -ShowLevel:$useShowLevel
    if ($null -eq $payload) {
        if ($MediaType -eq 'tv' -and -not $useShowLevel) {
            Write-SAVerbose -Label 'MDBList' -Text 'No usable ID or no imported episodes - skipping'
        } else {
            Write-SAVerbose -Label 'MDBList' -Text 'No usable ID (tmdb/tvdb/imdb) - skipping'
        }
        return & $makeResult $false $true 0 ''
    }

    # Build endpoint. API key travels as a query parameter and is never logged.
    $baseUrl = $script:SAConstants.MDBListApiUrl
    $uri = "$baseUrl/sync/collection?apikey=$apiKey"
    $timeout = if ($Config.timeoutSeconds -gt 0) { $Config.timeoutSeconds } else { $script:SAConstants.MDBListTimeoutSeconds }

    # Verbose: log what we are about to send (IDs + episode summary, never the key)
    $idParts = @()
    foreach ($k in @('tmdb', 'tvdb', 'imdb')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$ids[$k])) {
            $idParts += "${k}:$($ids[$k])"
        }
    }
    $scopeDesc = ''
    if ($MediaType -eq 'tv') {
        if ($useShowLevel) {
            $scopeDesc = ', whole show (fully downloaded)'
        } else {
            $epCount = @($ImportedEpisodes | Where-Object { $null -ne $_ }).Count
            $scopeDesc = ", $epCount episode(s) (partial)"
        }
    }
    Write-SAVerbose -Label 'MDBList' -Text "Marking $MediaType as collected ($($idParts -join ', ')$scopeDesc)"

    try {
        $result = Invoke-SAWebRequest -Uri $uri -Method POST -Body $payload -TimeoutSeconds $timeout -MaxRetries 2
    } catch {
        # Defensive: the HTTP helper normally returns a failure object rather than
        # throwing, but a post-import side effect must never bubble an exception up.
        Write-SAVerbose -Label 'MDBList' -Text "Collection sync error: $($_.Exception.Message)"
        return & $makeResult $false $false 0 $_.Exception.Message
    }

    if ($null -eq $result -or -not $result.Success) {
        $msg = if ($null -ne $result -and $result.ErrorMessage) { $result.ErrorMessage } else { 'request failed' }
        Write-SAVerbose -Label 'MDBList' -Text "Collection sync failed: $msg"
        return & $makeResult $false $false 0 $msg
    }

    # Sum the per-type updated counts MDBList returns: { updated: { movies, shows, seasons, episodes } }
    $updated = 0
    if ($null -ne $result.Data -and $null -ne $result.Data.updated) {
        foreach ($prop in @('movies', 'shows', 'seasons', 'episodes')) {
            $val = $result.Data.updated.$prop
            if ($null -ne $val) {
                $intVal = 0
                if ([int]::TryParse([string]$val, [ref]$intVal)) {
                    $updated += $intVal
                }
            }
        }
    }

    Write-SAVerbose -Label 'MDBList' -Text "Collection sync OK (updated: $updated)"
    return & $makeResult $true $false $updated ''
}

#endregion
