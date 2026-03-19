BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Invoke-SAArrManualImportExecute downloadId placement' {

    Context 'Sonarr: DownloadId goes per-file' {

        It 'should include downloadId on each file, not on the command body' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedBody = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    if ($Method -eq 'POST') {
                        $script:CapturedBody = $Body
                        return @{
                            Success = $true
                            Data    = @{ id = 12345 }
                        }
                    }
                    # Poll response - command completed
                    return @{
                        Success = $true
                        Data    = @{ status = 'completed'; result = 'successful' }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $files = @(
                    @{
                        path       = 'C:\Test\S01E01.mkv'
                        quality    = @{ quality = @{ id = 3; name = 'WEBDL-1080p' }; revision = @{ version = 1 } }
                        series     = @{ id = 100 }
                        episodes   = @( @{ id = 200 } )
                        languages  = @( @{ id = 1; name = 'English' } )
                        seriesId   = 100
                    },
                    @{
                        path       = 'C:\Test\S01E02.mkv'
                        quality    = @{ quality = @{ id = 3; name = 'WEBDL-1080p' }; revision = @{ version = 2; isRepack = $true } }
                        series     = @{ id = 100 }
                        episodes   = @( @{ id = 201 } )
                        languages  = @( @{ id = 1; name = 'English' } )
                        seriesId   = 100
                    }
                )

                $null = Invoke-SAArrManualImportExecute -AppType 'Sonarr' -Config $config -Files $files -DownloadId 'AABB1234'

                # Parse the captured body (it's JSON-encoded by Invoke-SAWebRequest)
                $body = $script:CapturedBody
                if ($body -is [string]) {
                    $body = $body | ConvertFrom-Json
                }

                # Both files should be present
                $body.files.Count | Should -Be 2

                # Each file should have downloadId
                $body.files | ForEach-Object {
                    $_.downloadId | Should -Be 'AABB1234'
                }

                # Command body itself should NOT have downloadId (it's ignored by Sonarr)
                $body.PSObject.Properties.Name | Should -Not -Contain 'downloadId'
            }
        }
    }

    Context 'Radarr: DownloadId goes per-file (same as Sonarr)' {

        It 'should include downloadId on each file, not on the command body' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedBody = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    if ($Method -eq 'POST') {
                        $script:CapturedBody = $Body
                        return @{
                            Success = $true
                            Data    = @{ id = 12345 }
                        }
                    }
                    return @{
                        Success = $true
                        Data    = @{ status = 'completed'; result = 'successful' }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 7878; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $files = @(
                    @{
                        path     = 'C:\Test\Movie.mkv'
                        quality  = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                        movie    = @{ id = 50 }
                        movieId  = 50
                    }
                )

                $null = Invoke-SAArrManualImportExecute -AppType 'Radarr' -Config $config -Files $files -DownloadId 'CCDD5678'

                $body = $script:CapturedBody
                if ($body -is [string]) {
                    $body = $body | ConvertFrom-Json
                }

                # downloadId should be on each file (ManualImportFile.DownloadId)
                $body.files[0].downloadId | Should -Be 'CCDD5678'

                # Command body itself should NOT have downloadId (ManualImportCommand has no such property)
                $body.PSObject.Properties.Name | Should -Not -Contain 'downloadId'
            }
        }
    }

    Context 'When DownloadId is not provided' {

        It 'should not include downloadId anywhere' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedBody = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    if ($Method -eq 'POST') {
                        $script:CapturedBody = $Body
                        return @{
                            Success = $true
                            Data    = @{ id = 12345 }
                        }
                    }
                    return @{
                        Success = $true
                        Data    = @{ status = 'completed'; result = 'successful' }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $files = @(
                    @{
                        path     = 'C:\Test\Movie.mkv'
                        quality  = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                        movie    = @{ id = 50 }
                        movieId  = 50
                    }
                )

                $null = Invoke-SAArrManualImportExecute -AppType 'Radarr' -Config $config -Files $files

                $body = $script:CapturedBody
                if ($body -is [string]) {
                    $body = $body | ConvertFrom-Json
                }

                $body.PSObject.Properties.Name | Should -Not -Contain 'downloadId'
                $body.files[0].PSObject.Properties.Name | Should -Not -Contain 'downloadId'
            }
        }
    }
}

Describe 'Get-SAImportVerification' {

    Context 'When all files were imported' {

        It 'should return correct counts' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    return @{
                        Success = $true
                        Data    = @{
                            totalRecords = 3
                            records      = @(
                                @{ eventType = 'downloadFolderImported'; downloadId = 'HASH1'; episodeId = 1 },
                                @{ eventType = 'downloadFolderImported'; downloadId = 'HASH1'; episodeId = 2 },
                                @{ eventType = 'downloadFolderImported'; downloadId = 'HASH1'; episodeId = 3 }
                            )
                        }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAImportVerification -AppType 'Sonarr' -Config $config -DownloadId 'HASH1' -ExpectedCount 3

                $result.ImportedCount | Should -Be 3
                $result.ExpectedCount | Should -Be 3
                $result.IsComplete | Should -BeTrue
            }
        }
    }

    Context 'When some files were silently skipped' {

        It 'should detect the mismatch' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    return @{
                        Success = $true
                        Data    = @{
                            totalRecords = 2
                            records      = @(
                                @{ eventType = 'downloadFolderImported'; downloadId = 'HASH2'; episodeId = 1 },
                                @{ eventType = 'downloadFolderImported'; downloadId = 'HASH2'; episodeId = 2 }
                            )
                        }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAImportVerification -AppType 'Sonarr' -Config $config -DownloadId 'HASH2' -ExpectedCount 5

                $result.ImportedCount | Should -Be 2
                $result.ExpectedCount | Should -Be 5
                $result.IsComplete | Should -BeFalse
            }
        }
    }

    Context 'When API call fails' {

        It 'should return null and not throw' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    return @{ Success = $false; ErrorMessage = 'timeout' }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAImportVerification -AppType 'Sonarr' -Config $config -DownloadId 'HASH3' -ExpectedCount 3

                $result | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Invoke-SAArrImport NullReferenceException recovery' {

    Context 'When Sonarr command fails with NRE but history shows import succeeded' {

        It 'should recover and return success' {
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
                        Success   = $false
                        Message   = 'System.NullReferenceException: Object reference not set to an instance of an object.'
                        Duration  = 5
                        CommandId = 42531
                        Status    = 'failed'
                        Result    = 'unknown'
                    }
                }

                Mock Get-SAImportVerification {
                    return [PSCustomObject]@{
                        ImportedCount = 1
                        ExpectedCount = 1
                        IsComplete    = $true
                        Records       = @( @{ eventType = 'downloadFolderImported'; downloadId = 'HASH123' } )
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test' -DownloadId 'HASH123'

                $result.Success | Should -BeTrue
                $result.Message | Should -Match 'verified via history'
                $result.ImportedFiles.Count | Should -Be 1
            }
        }
    }

    Context 'When command fails with NRE and history shows nothing imported' {

        It 'should still report failure' {
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
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
                Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }

                Mock Invoke-SAArrManualImportExecute {
                    return [PSCustomObject]@{
                        Success   = $false
                        Message   = 'System.NullReferenceException: Object reference not set to an instance of an object.'
                        Duration  = 5
                        CommandId = 42531
                        Status    = 'failed'
                        Result    = 'unknown'
                    }
                }

                Mock Get-SAImportVerification {
                    return [PSCustomObject]@{
                        ImportedCount = 0
                        ExpectedCount = 1
                        IsComplete    = $false
                        Records       = @()
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test' -DownloadId 'HASH123'

                $result.Success | Should -BeFalse
            }
        }
    }
}

Describe 'Invoke-SAArrImport NullReferenceException recovery for Radarr' {

    Context 'When Radarr command fails with NRE but history shows import succeeded' {

        It 'should recover and return success' {
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
                                path       = 'C:\Test\Movie.mkv'
                                quality    = @{ quality = @{ id = 31 }; revision = @{ version = 1 } }
                                movie      = @{ id = 50; title = 'Test Movie'; year = 2025 }
                                movieId    = 50
                                languages  = @( @{ id = 1; name = 'English' } )
                                rejections = @()
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
                Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Movie'; Year = 2025 } }

                Mock Invoke-SAArrManualImportExecute {
                    return [PSCustomObject]@{
                        Success   = $false
                        Message   = 'System.NullReferenceException: Object reference not set to an instance of an object.'
                        Duration  = 5
                        CommandId = 99999
                        Status    = 'failed'
                        Result    = 'unknown'
                    }
                }

                Mock Get-SAImportVerification {
                    return [PSCustomObject]@{
                        ImportedCount = 1
                        ExpectedCount = 1
                        IsComplete    = $true
                        Records       = @( @{ eventType = 'downloadFolderImported'; downloadId = 'RADARRHASH' } )
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 7878; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Radarr' -Config $config -StagingPath 'C:\Test' -DownloadId 'RADARRHASH'

                $result.Success | Should -BeTrue
                $result.Message | Should -Match 'verified via history'
            }
        }
    }
}
