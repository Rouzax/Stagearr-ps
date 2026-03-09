#Requires -Version 5.1
<#
.SYNOPSIS
    Queue-based enrichment for ManualImport scan results.
.DESCRIPTION
    Queries the *arr queue API by download hash to retrieve series/movie identity,
    then injects that data into scan results where the filename parser failed.
#>

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
        [hashtable]$Config,

        [Parameter()]
        [string]$DownloadId
    )

    if ([string]::IsNullOrWhiteSpace($DownloadId)) {
        return @()
    }

    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $baseUrl = $urlInfo.Url
    $uri = "$baseUrl/api/v3/queue?downloadId=$DownloadId&pageSize=100"

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

    Write-SAVerbose -Text "Queue lookup: $($records.Count) record(s) found"
    return , $records
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
        [string]$DownloadId
    )

    if ([string]::IsNullOrWhiteSpace($DownloadId)) {
        return , $ScanResults
    }

    $queueRecords = Get-SAArrQueueRecords -Config $Config -DownloadId $DownloadId
    if ($null -eq $queueRecords -or @($queueRecords).Count -eq 0) {
        return , $ScanResults
    }

    $queueRecords = @($queueRecords)

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
            $file.series = $seriesData
            $enrichedCount++

            # Match episodes by season/episode number
            if ($null -ne $file.episodes -and @($file.episodes).Count -gt 0) {
                foreach ($scanEp in @($file.episodes)) {
                    $key = "$($scanEp.seasonNumber):$($scanEp.episodeNumber)"
                    if ($episodeLookup.ContainsKey($key)) {
                        $scanEp.id = $episodeLookup[$key].episode.id
                    }
                }
            }

            # Remove "Unknown Series" rejections
            $file.rejections = @($file.rejections | Where-Object {
                $_.reason -notmatch 'Unknown Series'
            })
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
            $file.movie = $movieData
            $enrichedCount++

            # Remove "Unknown Movie" rejections
            $file.rejections = @($file.rejections | Where-Object {
                $_.reason -notmatch 'Unknown Movie'
            })
        }
    }

    if ($enrichedCount -gt 0) {
        Write-SAVerbose -Text "Queue enrichment: updated $enrichedCount file(s) with movie data"
    }

    return , $ScanResults
}
