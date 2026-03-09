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

            # Mock URL builder
            Mock Get-SAImporterBaseUrl {
                return @{ Url = 'http://localhost:8989'; DisplayUrl = 'localhost:8989'; HostHeader = $null }
            }

            # Mock connection test
            Mock Test-SAArrConnection { return $true }

            # Mock scan - returns file with series data
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

            # Mock metadata extraction
            Mock ConvertTo-SAArrMetadata {
                return @{ Title = 'Test'; Year = 2024 }
            }

            # Mock filter functions
            Mock Get-SAImportableFiles {
                return @(
                    @{
                        path       = '\\server\file.mkv'
                        series     = @{ id = 1; title = 'Test' }
                        episodes   = @(@{ id = 100; seasonNumber = 1; episodeNumber = 1 })
                        quality    = @{ quality = @{ name = 'WEBDL-1080p' } }
                        languages  = @(@{ name = 'English' })
                        rejections = @()
                    }
                )
            }

            Mock Get-SARejectionSummary {
                return @{
                    IsAllRejected  = $false
                    HasPartial     = $false
                    RejectedCount  = 0
                    TotalCount     = 1
                    PrimaryReason  = $null
                    Message        = $null
                }
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
