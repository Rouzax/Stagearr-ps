# Queue-Based Scan Enrichment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enrich ManualImport scan results with queue data so misspelled release names don't cause "Unknown Series/Movie" rejections.

**Architecture:** After the scan step, query the *arr queue API by torrent hash to get the correct series/movie identity. Inject that into scan results missing it. Single new private helper, small integration in ImportArr.ps1.

**Tech Stack:** PowerShell 5.1+, Pester 5, Sonarr/Radarr v3 API

---

### Task 1: Create QueueEnrichment.ps1 with queue lookup helper

**Files:**
- Create: `Modules/Stagearr.Core/Private/QueueEnrichment.ps1`
- Test: `Tests/QueueEnrichment.Tests.ps1`

**Step 1: Write the failing tests**

Create `Tests/QueueEnrichment.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SAArrQueueRecords' {

    Context 'When DownloadId is provided' {

        It 'should query the queue API with downloadId filter' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    $script:CapturedUri = $Uri
                    return @{
                        Success = $true
                        Data    = @{
                            records = @(
                                @{
                                    seriesId  = 380
                                    episodeId = 9766
                                    downloadId = 'ABC123'
                                }
                            )
                        }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAArrQueueRecords -Config $config -DownloadId 'ABC123'

                $script:CapturedUri | Should -Match 'downloadId=ABC123'
                $result.Count | Should -Be 1
                $result[0].seriesId | Should -Be 380
            }
        }
    }

    Context 'When DownloadId is empty' {

        It 'should return empty array without calling API' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {}

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAArrQueueRecords -Config $config -DownloadId ''

                $result | Should -BeNullOrEmpty
                Should -Invoke Invoke-SAWebRequest -Times 0
            }
        }
    }

    Context 'When API call fails' {

        It 'should return empty array and not throw' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    return @{ Success = $false; ErrorMessage = 'Connection refused' }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAArrQueueRecords -Config $config -DownloadId 'ABC123'

                $result | Should -BeNullOrEmpty
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `pwsh -Command "Invoke-Pester Tests/QueueEnrichment.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-SAArrQueueRecords` not found

**Step 3: Write minimal implementation**

Create `Modules/Stagearr.Core/Private/QueueEnrichment.ps1`:

```powershell
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
    return $records
}
```

**Step 4: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/QueueEnrichment.Tests.ps1 -Output Detailed"`
Expected: PASS (3 tests)

**Step 5: Commit**

```bash
git add Tests/QueueEnrichment.Tests.ps1 Modules/Stagearr.Core/Private/QueueEnrichment.ps1
git commit -m "feat: add queue record lookup helper for scan enrichment"
```

---

### Task 2: Add enrichment function that injects queue data into scan results

**Files:**
- Modify: `Modules/Stagearr.Core/Private/QueueEnrichment.ps1`
- Modify: `Tests/QueueEnrichment.Tests.ps1`

**Step 1: Write the failing tests**

Append to `Tests/QueueEnrichment.Tests.ps1`:

```powershell
Describe 'Invoke-SAArrQueueEnrichment' {

    Context 'Sonarr: scan results missing series data' {

        It 'should inject seriesId and series object from queue into unmatched files' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAArrQueueRecords {
                    return @(
                        @{ seriesId = 380; episodeId = 9766; series = @{ id = 380; title = 'Vanished'; year = 2026 } }
                        @{ seriesId = 380; episodeId = 9767; series = @{ id = 380; title = 'Vanished'; year = 2026 } }
                    )
                }

                # Simulate scan result with no series (Unknown Series rejection)
                $scanResults = @(
                    @{
                        path       = '\\server\staging\Vanised.S01E01.mkv'
                        series     = $null
                        episodes   = @(@{ id = 0; seasonNumber = 1; episodeNumber = 1 })
                        quality    = @{ quality = @{ name = 'WEBDL-2160p' } }
                        languages  = @(@{ name = 'English' })
                        rejections = @(@{ type = 'permanent'; reason = 'Unknown Series' })
                    }
                    @{
                        path       = '\\server\staging\Vanised.S01E02.mkv'
                        series     = $null
                        episodes   = @(@{ id = 0; seasonNumber = 1; episodeNumber = 2 })
                        quality    = @{ quality = @{ name = 'WEBDL-2160p' } }
                        languages  = @(@{ name = 'English' })
                        rejections = @(@{ type = 'permanent'; reason = 'Unknown Series' })
                    }
                )

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrQueueEnrichment -AppType 'Sonarr' -Config $config `
                    -ScanResults $scanResults -DownloadId 'ABC123'

                $result[0].series.id | Should -Be 380
                $result[0].series.title | Should -Be 'Vanished'
                $result[1].series.id | Should -Be 380
                # Unknown Series rejection should be removed
                $result[0].rejections | Where-Object { $_.reason -match 'Unknown Series' } | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Sonarr: scan results already have series data' {

        It 'should not overwrite existing series data' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAArrQueueRecords {
                    return @(
                        @{ seriesId = 380; episodeId = 9766; series = @{ id = 380; title = 'Vanished'; year = 2026 } }
                    )
                }

                $scanResults = @(
                    @{
                        path       = '\\server\staging\Vanished.S01E01.mkv'
                        series     = @{ id = 380; title = 'Vanished'; year = 2026 }
                        episodes   = @(@{ id = 9766; seasonNumber = 1; episodeNumber = 1 })
                        quality    = @{ quality = @{ name = 'WEBDL-2160p' } }
                        languages  = @(@{ name = 'English' })
                        rejections = @()
                    }
                )

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrQueueEnrichment -AppType 'Sonarr' -Config $config `
                    -ScanResults $scanResults -DownloadId 'ABC123'

                $result[0].series.id | Should -Be 380
                $result[0].episodes[0].id | Should -Be 9766
            }
        }
    }

    Context 'Radarr: scan results missing movie data' {

        It 'should inject movieId and movie object from queue' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAArrQueueRecords {
                    return @(
                        @{ movieId = 42; movie = @{ id = 42; title = 'Some Movie'; year = 2026 } }
                    )
                }

                $scanResults = @(
                    @{
                        path       = '\\server\staging\SomeMovie.2026.mkv'
                        movie      = $null
                        quality    = @{ quality = @{ name = 'WEBDL-2160p' } }
                        languages  = @(@{ name = 'English' })
                        rejections = @(@{ type = 'permanent'; reason = 'Unknown Movie' })
                    }
                )

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 7878; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrQueueEnrichment -AppType 'Radarr' -Config $config `
                    -ScanResults $scanResults -DownloadId 'DEF456'

                $result[0].movie.id | Should -Be 42
                $result[0].movie.title | Should -Be 'Some Movie'
                $result[0].rejections | Where-Object { $_.reason -match 'Unknown Movie' } | Should -BeNullOrEmpty
            }
        }
    }

    Context 'No queue records found' {

        It 'should return scan results unchanged' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAArrQueueRecords { return @() }

                $scanResults = @(
                    @{
                        path       = '\\server\staging\file.mkv'
                        series     = $null
                        rejections = @(@{ type = 'permanent'; reason = 'Unknown Series' })
                    }
                )

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrQueueEnrichment -AppType 'Sonarr' -Config $config `
                    -ScanResults $scanResults -DownloadId 'ABC123'

                $result[0].series | Should -BeNullOrEmpty
                $result[0].rejections.Count | Should -Be 1
            }
        }
    }

    Context 'Sonarr: episode matching from queue by season/episode number' {

        It 'should match queue episodeId to scan episode by season and episode number' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAArrQueueRecords {
                    return @(
                        @{ seriesId = 380; episodeId = 9766; seasonNumber = 1; episode = @{ id = 9766; seasonNumber = 1; episodeNumber = 1 }; series = @{ id = 380; title = 'Vanished' } }
                        @{ seriesId = 380; episodeId = 9767; seasonNumber = 1; episode = @{ id = 9767; seasonNumber = 1; episodeNumber = 2 }; series = @{ id = 380; title = 'Vanished' } }
                    )
                }

                $scanResults = @(
                    @{
                        path       = '\\server\staging\Vanised.S01E01.mkv'
                        series     = $null
                        episodes   = @(@{ id = 0; seasonNumber = 1; episodeNumber = 1 })
                        quality    = @{ quality = @{ name = 'WEBDL-2160p' } }
                        languages  = @(@{ name = 'English' })
                        rejections = @(@{ type = 'permanent'; reason = 'Unknown Series' })
                    }
                )

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrQueueEnrichment -AppType 'Sonarr' -Config $config `
                    -ScanResults $scanResults -DownloadId 'ABC123'

                $result[0].episodes[0].id | Should -Be 9766
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `pwsh -Command "Invoke-Pester Tests/QueueEnrichment.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Invoke-SAArrQueueEnrichment` not found

**Step 3: Write implementation**

Append to `Modules/Stagearr.Core/Private/QueueEnrichment.ps1`:

```powershell
function Invoke-SAArrQueueEnrichment {
    <#
    .SYNOPSIS
        Enriches ManualImport scan results with series/movie data from the *arr queue.
    .DESCRIPTION
        Queries the *arr queue API by download hash to find what series/movie the download
        belongs to. For any scan result missing that identity (e.g., due to misspelled
        release names), injects the correct data and removes "Unknown Series/Movie" rejections.

        Always runs when a DownloadId is available. Files that already have correct
        series/movie data are left unchanged.
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
        return $ScanResults
    }

    $queueRecords = Get-SAArrQueueRecords -Config $Config -DownloadId $DownloadId
    if ($null -eq $queueRecords -or @($queueRecords).Count -eq 0) {
        return $ScanResults
    }

    $queueRecords = @($queueRecords)

    if ($AppType -eq 'Sonarr') {
        return Update-SASonarrScanFromQueue -ScanResults $ScanResults -QueueRecords $queueRecords
    } else {
        return Update-SARadarrScanFromQueue -ScanResults $ScanResults -QueueRecords $queueRecords
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
    $seriesId = $QueueRecords[0].seriesId

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

    return $ScanResults
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

    return $ScanResults
}
```

**Step 4: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/QueueEnrichment.Tests.ps1 -Output Detailed"`
Expected: PASS (all 8 tests)

**Step 5: Commit**

```bash
git add Modules/Stagearr.Core/Private/QueueEnrichment.ps1 Tests/QueueEnrichment.Tests.ps1
git commit -m "feat: add queue enrichment for scan results (Sonarr + Radarr)"
```

---

### Task 3: Register QueueEnrichment.ps1 in module loader

**Files:**
- Modify: `Modules/Stagearr.Core/Stagearr.Core.psm1`

**Step 1: Add to module loader**

In `Stagearr.Core.psm1`, add `'QueueEnrichment.ps1'` to `$PrivateLoadOrder` after `'ArrMetadata.ps1'` (it depends on `ImportUtility.ps1` for `Get-SAImporterBaseUrl` and `Http.ps1` for `Invoke-SAWebRequest`, both loaded earlier):

```
    'ArrMetadata.ps1'             # *arr metadata extraction and normalization (ManualImport scan results)
    'QueueEnrichment.ps1'         # Queue-based enrichment for ManualImport scan results
```

**Step 2: Run tests to verify module loads correctly**

Run: `pwsh -Command "Invoke-Pester Tests/QueueEnrichment.Tests.ps1 -Output Detailed"`
Expected: PASS (all tests still pass, now loading via module order)

**Step 3: Commit**

```bash
git add Modules/Stagearr.Core/Stagearr.Core.psm1
git commit -m "chore: register QueueEnrichment.ps1 in module loader"
```

---

### Task 4: Integrate enrichment into ImportArr.ps1

**Files:**
- Modify: `Modules/Stagearr.Core/Public/ImportArr.ps1:206-211` (between SCAN and EXTRACT steps)

**Step 1: Write integration test**

Create `Tests/QueueEnrichmentIntegration.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Invoke-SAArrImport queue enrichment integration' {

    It 'should call Invoke-SAArrQueueEnrichment between scan and filter steps' {
        InModuleScope 'Stagearr.Core' {
            $script:EnrichmentCalled = $false
            $script:EnrichmentDownloadId = $null

            Mock Write-SAVerbose {}
            Mock Write-SAProgress {}
            Mock Write-SAOutcome {}
            Mock Write-SAKeyValue {}
            Mock Add-SAEmailException {}
            Mock Add-SAEmailKeyValue {}
            Mock Set-SAEmailMetadata {}

            # Mock connection test
            Mock Invoke-SAImporterConnectionTest {
                return @{ Success = $true; Message = 'OK' }
            }

            # Mock scan - returns files with series data (enrichment already done)
            Mock Invoke-SAArrManualImportScan {
                return [PSCustomObject]@{
                    Success      = $true
                    ScanResults  = @(
                        @{
                            path       = '\\server\file.mkv'
                            series     = @{ id = 1; title = 'Test' }
                            episodes   = @(@{ id = 100; seasonNumber = 1; episodeNumber = 1 })
                            quality    = @{ quality = @{ name = 'WEBDL-1080p' } }
                            languages  = @(@{ name = 'English' })
                            rejections = @()
                        }
                    )
                    ErrorMessage = $null
                }
            }

            # Track enrichment call
            Mock Invoke-SAArrQueueEnrichment {
                $script:EnrichmentCalled = $true
                $script:EnrichmentDownloadId = $DownloadId
                return $ScanResults
            }

            # Mock execute
            Mock Invoke-SAArrManualImportExecute {
                return [PSCustomObject]@{
                    Success   = $true
                    Message   = 'Import complete'
                    Duration  = 5
                    CommandId = 1
                    Status    = 'completed'
                    Result    = 'successful'
                }
            }

            $config = @{
                apiKey = 'test-key'; host = 'localhost'; port = 8989
                ssl = $false; urlRoot = ''; importMode = 'move'
                timeoutMinutes = 1
            }

            $null = Invoke-SAArrImport -AppType 'Sonarr' -Config $config `
                -StagingPath 'C:\staging\test' -DownloadId 'HASH123'

            $script:EnrichmentCalled | Should -BeTrue
            $script:EnrichmentDownloadId | Should -Be 'HASH123'
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run: `pwsh -Command "Invoke-Pester Tests/QueueEnrichmentIntegration.Tests.ps1 -Output Detailed"`
Expected: FAIL — enrichment not called (not integrated yet)

**Step 3: Add enrichment call to ImportArr.ps1**

In `Modules/Stagearr.Core/Public/ImportArr.ps1`, after line 211 (`$scanItems = @($scanResult.ScanResults)`), insert:

```powershell
    # ==========================================================================
    # STEP 1.5: ENRICH - Use queue data to fill missing series/movie info
    # ==========================================================================
    # When *arr grabs a torrent, it records which series/movie it belongs to.
    # If the scan couldn't match files (e.g., misspelled release name), we use
    # the queue to inject the correct identity before filtering.
    if (-not [string]::IsNullOrWhiteSpace($DownloadId)) {
        $scanItems = @(Invoke-SAArrQueueEnrichment -AppType $AppType -Config $Config `
            -ScanResults $scanItems -DownloadId $DownloadId)
    }
```

**Step 4: Run all tests**

Run: `pwsh -Command "Invoke-Pester Tests/QueueEnrichment*.Tests.ps1 -Output Detailed"`
Expected: PASS (all tests)

**Step 5: Commit**

```bash
git add Modules/Stagearr.Core/Public/ImportArr.ps1 Tests/QueueEnrichmentIntegration.Tests.ps1
git commit -m "feat: integrate queue enrichment into ManualImport pipeline"
```

---

### Task 5: Run full test suite and verify

**Step 1: Run all Pester tests**

Run: `pwsh -Command "Invoke-Pester Tests/ -Output Detailed"`
Expected: All tests pass, no regressions

**Step 2: Verify module loads cleanly**

Run: `pwsh -Command "Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force -Verbose"`
Expected: No errors, QueueEnrichment.ps1 loaded

**Step 3: Commit if any fixes were needed, otherwise done**
