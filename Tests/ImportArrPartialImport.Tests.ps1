BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Invoke-SAArrImport partial import detection' {

    Context 'Sonarr: imports fewer files than expected' {

        It 'should return partial status with correct counts' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Write-SAPhaseHeader {}
                Mock Add-SAEmailException {}
                Mock Get-SAImportHint { return $null }

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Test-SAArrConnection { return $true }

                Mock Invoke-SAArrManualImportScan {
                    return [PSCustomObject]@{
                        Success      = $true
                        ScanResults  = @(
                            @{
                                path       = 'C:\Test\S01E01.mkv'
                                quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                episodes   = @( @{ id = 200 } )
                                languages  = @( @{ id = 1; name = 'English' } )
                                seriesId   = 100
                                rejections = @()
                            },
                            @{
                                path       = 'C:\Test\S01E02.mkv'
                                quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                episodes   = @( @{ id = 201 } )
                                languages  = @( @{ id = 1; name = 'English' } )
                                seriesId   = 100
                                rejections = @()
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }

                Mock ConvertTo-SAArrMetadata {
                    return @{ Title = 'Test Show'; Year = 2026 }
                }

                Mock Invoke-SAArrManualImportExecute {
                    return [PSCustomObject]@{
                        Success   = $true
                        Message   = 'Completed'
                        Duration  = 5
                        CommandId = 99999
                        Status    = 'completed'
                        Result    = 'successful'
                    }
                }

                # History shows only 1 of 2 files was actually imported
                Mock Get-SAImportVerification {
                    return [PSCustomObject]@{
                        ImportedCount = 1
                        ExpectedCount = 2
                        IsComplete    = $false
                        Records       = @( @{ eventType = 'downloadFolderImported'; downloadId = 'HASH-PARTIAL'; episodeId = 200 } )
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test' -DownloadId 'HASH-PARTIAL'

                $result.Success | Should -BeTrue
                $result.Status | Should -Be 'partial'
                $result.ImportedCount | Should -Be 1
                $result.AbortedCount | Should -Be 1
                $result.AbortReason | Should -Match 'silently skipped'
            }
        }
    }

    Context 'Radarr: all files imported successfully' {

        It 'should NOT have partial status' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Write-SAPhaseHeader {}
                Mock Add-SAEmailException {}
                Mock Get-SAImportHint { return $null }

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:7878'; DisplayUrl = 'http://localhost:7878'; HostHeader = $null }
                }

                Mock Test-SAArrConnection { return $true }

                Mock Invoke-SAArrManualImportScan {
                    return [PSCustomObject]@{
                        Success      = $true
                        ScanResults  = @(
                            @{
                                path       = 'C:\Test\Movie.2024.mkv'
                                quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                movie      = @{ id = 50; title = 'Test Movie'; year = 2024 }
                                movieId    = 50
                                rejections = @()
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }

                Mock ConvertTo-SAArrMetadata {
                    return @{ Title = 'Test Movie'; Year = 2024 }
                }

                Mock Invoke-SAArrManualImportExecute {
                    return [PSCustomObject]@{
                        Success   = $true
                        Message   = 'Completed'
                        Duration  = 3
                        CommandId = 88888
                        Status    = 'completed'
                        Result    = 'successful'
                    }
                }

                # History confirms the single file was imported
                Mock Get-SAImportVerification {
                    return [PSCustomObject]@{
                        ImportedCount = 1
                        ExpectedCount = 1
                        IsComplete    = $true
                        Records       = @( @{ eventType = 'downloadFolderImported'; downloadId = 'HASH-FULL' } )
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 7878; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Radarr' -Config $config -StagingPath 'C:\Test' -DownloadId 'HASH-FULL'

                $result.Success | Should -BeTrue
                $result.Status | Should -BeNullOrEmpty
                $result.AbortedCount | Should -Be 0
            }
        }
    }
}
