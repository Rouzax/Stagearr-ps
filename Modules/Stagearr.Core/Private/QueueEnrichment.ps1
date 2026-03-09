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
