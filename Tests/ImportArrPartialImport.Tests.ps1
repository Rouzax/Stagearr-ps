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
                # ImportedFiles must NOT contain the attempted-but-not-verified paths.
                # We cannot tell which specific files were silently skipped, so leaving
                # the array populated would let JobProcessor emit misleading per-file
                # notes like "Imported 2 files" when only 1 was actually imported.
                @($result.ImportedFiles).Count | Should -Be 0
            }
        }
    }

    Context 'Sonarr: imports zero files when one was sent (Sonarr silently skipped)' {

        It 'should return partial status with empty ImportedFiles array' {
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
                    # Use PSCustomObject (not hashtable) to match production scan results
                    # which come from JSON deserialization. Hashtables would expose .Count
                    # as the key count when PowerShell unwraps a single-element array.
                    return [PSCustomObject]@{
                        Success      = $true
                        ScanResults  = @(
                            [PSCustomObject]@{
                                path       = 'C:\Test\S05E01.mkv'
                                quality    = @{ quality = @{ id = 18 }; revision = @{ version = 1 } }
                                series     = @{ id = 248; title = 'The Boys'; year = 2019 }
                                episodes   = @( @{ id = 5928 } )
                                languages  = @( @{ id = 1; name = 'English' } )
                                seriesId   = 248
                                rejections = @()
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }

                Mock ConvertTo-SAArrMetadata {
                    return @{ Title = 'The Boys'; Year = 2019 }
                }

                Mock Invoke-SAArrManualImportExecute {
                    return [PSCustomObject]@{
                        Success   = $true
                        Message   = 'Completed'
                        Duration  = 5
                        CommandId = 122285
                        Status    = 'completed'
                        Result    = 'successful'
                    }
                }

                # History shows ZERO files imported (the file lock scenario from sonarr.txt)
                Mock Get-SAImportVerification {
                    return [PSCustomObject]@{
                        ImportedCount = 0
                        ExpectedCount = 1
                        IsComplete    = $false
                        Records       = @()
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test' -DownloadId 'EBC236C9AF096B3DA8FB9459107552C22BC6C7BB'

                $result.Success | Should -BeTrue
                $result.Status | Should -Be 'partial'
                $result.ImportedCount | Should -Be 0
                $result.AbortedCount | Should -Be 1
                $result.AbortReason | Should -Match 'silently skipped'
                # The fix: ImportedFiles must be empty so JobProcessor falls back to
                # the count-based note path and does not emit "Imported 1 file" when
                # zero files were verified.
                @($result.ImportedFiles).Count | Should -Be 0
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
                # Full-success path: ImportedFiles should still be populated for
                # downstream consumers (JobProcessor episode-level notes).
                @($result.ImportedFiles).Count | Should -Be 1
            }
        }
    }
}
