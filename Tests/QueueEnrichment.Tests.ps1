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
                $result = Get-SAArrQueueRecords -AppType 'Sonarr' -Config $config -DownloadId 'ABC123'

                $script:CapturedUri | Should -Match 'downloadId=ABC123'
                $script:CapturedUri | Should -Match 'includeSeries=true'
                $script:CapturedUri | Should -Match 'includeEpisode=true'
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
                $result = Get-SAArrQueueRecords -AppType 'Sonarr' -Config $config -DownloadId ''

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
                $result = Get-SAArrQueueRecords -AppType 'Sonarr' -Config $config -DownloadId 'ABC123'

                $result | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Invoke-SAArrQueueEnrichment' {

    Context 'Sonarr: scan results missing series data' {

        It 'should inject seriesId and series object from queue into unmatched files' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAArrQueueRecords {
                    return @(
                        @{ seriesId = 380; episodeId = 9766; series = @{ id = 380; title = 'Vanished'; year = 2026 }; episode = @{ id = 9766; seasonNumber = 1; episodeNumber = 1 } }
                        @{ seriesId = 380; episodeId = 9767; series = @{ id = 380; title = 'Vanished'; year = 2026 }; episode = @{ id = 9767; seasonNumber = 1; episodeNumber = 2 } }
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
                        @{ seriesId = 380; episodeId = 9766; series = @{ id = 380; title = 'Vanished'; year = 2026 }; episode = @{ id = 9766; seasonNumber = 1; episodeNumber = 1 } }
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
