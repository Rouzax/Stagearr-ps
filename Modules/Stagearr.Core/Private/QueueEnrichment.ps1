#Requires -Version 5.1
<#
.SYNOPSIS
    Queue-based enrichment for ManualImport scan results.
.DESCRIPTION
    Queries the *arr queue API by download hash to retrieve series/movie identity,
    then injects that data into scan results where the filename parser failed.
#>

function Set-SAScanResultProperty {
    <#
    .SYNOPSIS
        Safely sets a property on a PSCustomObject (from JSON deserialization).
    .DESCRIPTION
        ManualImport scan results are PSCustomObjects where null JSON fields may
        not exist as properties. Direct assignment throws; this uses Add-Member.
    #>
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Get-SAArrQueueRecords {
    <#
    .SYNOPSIS
        Queries the *arr queue API for records matching a download ID (torrent hash).
    .PARAMETER Config
        Application configuration hashtable (host, port, apiKey, etc.).
    .PARAMETER DownloadId
        Download client ID (torrent hash) to filter by.
    .OUTPUTS
        Array of queue record objects, or empty array on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter()]
        [string]$DownloadId
    )

    if ([string]::IsNullOrWhiteSpace($DownloadId)) {
        return @()
    }

    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $baseUrl = $urlInfo.Url
    $includeParams = if ($AppType -eq 'Sonarr') {
        '&includeSeries=true&includeEpisode=true'
    } else {
        '&includeMovie=true'
    }
    $uri = "$baseUrl/api/v3/queue?downloadId=$DownloadId&pageSize=100$includeParams"

    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }

    Write-SAVerbose -Text "Queue lookup for download ID: $DownloadId"

    $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -TimeoutSeconds 15
    if (-not $result.Success) {
        Write-SAVerbose -Text "Queue lookup failed: $($result.ErrorMessage)"
        return @()
    }

    $records = @()
    if ($null -ne $result.Data) {
        if ($null -ne $result.Data.records) {
            $records = @($result.Data.records)
        } elseif ($result.Data -is [array]) {
            $records = @($result.Data)
        }
    }

    # Client-side filter: the queue API may return all records regardless of downloadId parameter
    if ($records.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($DownloadId)) {
        $filtered = @($records | Where-Object { $_.downloadId -eq $DownloadId })
        if ($filtered.Count -ne $records.Count) {
            Write-SAVerbose -Text "Queue lookup: $($records.Count) record(s) returned, $($filtered.Count) match download ID"
        }
        $records = $filtered
    }

    Write-SAVerbose -Text "Queue lookup: $($records.Count) record(s) found"
    return , $records
}

function Get-SAArrHistoryRecords {
    <#
    .SYNOPSIS
        Queries the *arr history API for the series/movie associated with a download ID.
    .DESCRIPTION
        Fallback for when Get-SAArrQueueRecords returns empty (torrent already finished
        and removed from queue). The history API retains records indefinitely.
        Returns the series or movie object from the first history record.
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER Config
        Application configuration hashtable (host, port, apiKey, etc.).
    .PARAMETER DownloadId
        Download client ID (torrent hash) to filter by.
    .OUTPUTS
        Series or movie object from history, or $null on failure/empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter()]
        [string]$DownloadId
    )

    if ([string]::IsNullOrWhiteSpace($DownloadId)) {
        return $null
    }

    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $baseUrl = $urlInfo.Url
    $includeParams = if ($AppType -eq 'Sonarr') {
        '&includeSeries=true&includeEpisode=true'
    } else {
        '&includeMovie=true'
    }
    $uri = "$baseUrl/api/v3/history?downloadId=$DownloadId&pageSize=1$includeParams"

    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }

    Write-SAVerbose -Text "History lookup for download ID: $DownloadId"

    $result = Invoke-SAWebRequest -Uri $uri -Method GET -Headers $headers -TimeoutSeconds 15
    if (-not $result.Success) {
        Write-SAVerbose -Text "History lookup failed: $($result.ErrorMessage)"
        return $null
    }

    $records = @()
    if ($null -ne $result.Data -and $null -ne $result.Data.records) {
        $records = @($result.Data.records)
    }

    if ($records.Count -eq 0) {
        Write-SAVerbose -Text "History lookup: no records found"
        return $null
    }

    # Extract the series/movie object from the first history record
    $mediaObj = if ($AppType -eq 'Sonarr') { $records[0].series } else { $records[0].movie }

    if ($null -ne $mediaObj) {
        $title = if ($mediaObj.title) { $mediaObj.title } else { '?' }
        Write-SAVerbose -Text "History lookup: found `"$title`""
    } else {
        Write-SAVerbose -Text "History lookup: record found but no media data"
    }

    return $mediaObj
}

function Invoke-SAArrQueueEnrichment {
    <#
    .SYNOPSIS
        Enriches ManualImport scan results with series/movie data from the *arr queue.
    .DESCRIPTION
        Queries the *arr queue API by download hash to find what series/movie the download
        belongs to. For any scan result missing that identity (e.g., due to misspelled
        release names), injects the correct data and removes "Unknown Series/Movie" rejections.
    .PARAMETER AppType
        The *arr application type: 'Radarr' or 'Sonarr'.
    .PARAMETER Config
        Application configuration hashtable (host, port, apiKey, etc.).
    .PARAMETER ScanResults
        Array of file objects from Invoke-SAArrManualImportScan.
    .PARAMETER DownloadId
        Download client ID (torrent hash).
    .PARAMETER CachedQueueRecords
        Pre-fetched queue records from early pipeline lookup. When provided,
        skips the queue API call to avoid duplicate requests.
    .OUTPUTS
        Array of enriched scan result objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Radarr', 'Sonarr')]
        [string]$AppType,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [array]$ScanResults,

        [Parameter()]
        [string]$DownloadId,

        [Parameter()]
        [array]$CachedQueueRecords
    )

    # Use cached records if available, otherwise fetch from API
    if ($null -ne $CachedQueueRecords -and @($CachedQueueRecords).Count -gt 0) {
        Write-SAVerbose -Text "Queue enrichment: using cached queue data ($(@($CachedQueueRecords).Count) records)"
        $queueRecords = @($CachedQueueRecords)
    } else {
        if ([string]::IsNullOrWhiteSpace($DownloadId)) {
            return , $ScanResults
        }

        $queueRecords = Get-SAArrQueueRecords -AppType $AppType -Config $Config -DownloadId $DownloadId
        if ($null -eq $queueRecords -or @($queueRecords).Count -eq 0) {
            return , $ScanResults
        }

        $queueRecords = @($queueRecords)
    }

    if ($AppType -eq 'Sonarr') {
        return , (Update-SASonarrScanFromQueue -ScanResults $ScanResults -QueueRecords $queueRecords)
    } else {
        return , (Update-SARadarrScanFromQueue -ScanResults $ScanResults -QueueRecords $queueRecords)
    }
}

function Update-SASonarrScanFromQueue {
    <#
    .SYNOPSIS
        Injects series and episode data from queue records into Sonarr scan results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ScanResults,

        [Parameter(Mandatory = $true)]
        [array]$QueueRecords
    )

    # Get series info from first queue record
    $seriesData = $QueueRecords[0].series

    # Build episode lookup: season:episode -> queue record
    $episodeLookup = @{}
    foreach ($qr in $QueueRecords) {
        $ep = $qr.episode
        if ($null -ne $ep) {
            $key = "$($ep.seasonNumber):$($ep.episodeNumber)"
            $episodeLookup[$key] = $qr
        }
    }

    $enrichedCount = 0
    foreach ($file in $ScanResults) {
        $needsSeries = ($null -eq $file.series -or $null -eq $file.series.id -or $file.series.id -eq 0)

        if ($needsSeries -and $null -ne $seriesData) {
            Set-SAScanResultProperty $file 'series' $seriesData
            $enrichedCount++

            # Match episodes by season/episode number from scan data
            if ($null -ne $file.episodes -and @($file.episodes).Count -gt 0) {
                foreach ($scanEp in @($file.episodes)) {
                    $key = "$($scanEp.seasonNumber):$($scanEp.episodeNumber)"
                    if ($episodeLookup.ContainsKey($key)) {
                        $scanEp.id = $episodeLookup[$key].episode.id
                    }
                }
            } else {
                # Scan returned no episodes (Unknown Series = no parsing).
                # Parse S01E01 from filename and match to queue episode data.
                $fileName = Split-Path -Path $file.path -Leaf
                if ($fileName -match '[Ss](\d+)[Ee](\d+)') {
                    $parsedSeason = [int]$Matches[1]
                    $parsedEpisode = [int]$Matches[2]
                    $key = "$($parsedSeason):$($parsedEpisode)"
                    if ($episodeLookup.ContainsKey($key)) {
                        $queueEp = $episodeLookup[$key].episode
                        Set-SAScanResultProperty $file 'episodes' @($queueEp)
                        Write-SAVerbose -Text "Queue enrichment: matched $fileName to S${parsedSeason}E${parsedEpisode}"
                    }
                }
            }

            # Remove "Unknown Series" rejections
            $filtered = @($file.rejections | Where-Object {
                $_.reason -notmatch 'Unknown Series'
            })
            Set-SAScanResultProperty $file 'rejections' $filtered
        }
    }

    if ($enrichedCount -gt 0) {
        Write-SAVerbose -Text "Queue enrichment: updated $enrichedCount file(s) with series data"
    }

    return , $ScanResults
}

function Update-SARadarrScanFromQueue {
    <#
    .SYNOPSIS
        Injects movie data from queue records into Radarr scan results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ScanResults,

        [Parameter(Mandatory = $true)]
        [array]$QueueRecords
    )

    $movieData = $QueueRecords[0].movie
    $enrichedCount = 0

    foreach ($file in $ScanResults) {
        $needsMovie = ($null -eq $file.movie -or $null -eq $file.movie.id -or $file.movie.id -eq 0)

        if ($needsMovie -and $null -ne $movieData) {
            Set-SAScanResultProperty $file 'movie' $movieData
            $enrichedCount++

            # Remove "Unknown Movie" rejections
            $filtered = @($file.rejections | Where-Object {
                $_.reason -notmatch 'Unknown Movie'
            })
            Set-SAScanResultProperty $file 'rejections' $filtered
        }
    }

    if ($enrichedCount -gt 0) {
        Write-SAVerbose -Text "Queue enrichment: updated $enrichedCount file(s) with movie data"
    }

    return , $ScanResults
}
