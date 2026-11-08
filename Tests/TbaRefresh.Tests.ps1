BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Invoke-SAArrSeriesRefresh' {

    Context 'successful refresh' {
        It 'sends RefreshSeries command and returns success' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Invoke-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success   = $true
                        CommandId = 12345
                        Status    = 'queued'
                        Message   = $null
                    }
                }

                Mock Wait-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success  = $true
                        Message  = 'Completed'
                        Duration = 10
                        Status   = 'completed'
                        Result   = 'successful'
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrSeriesRefresh -Config $config -SeriesId 100

                $result.Success | Should -BeTrue

                # Verify RefreshSeries command was sent with correct body
                Should -Invoke Invoke-SAImporterCommand -Times 1 -ParameterFilter {
                    $Body.name -eq 'RefreshSeries' -and $Body.seriesId -eq 100
                }

                # Verify polling used the TBA timeout
                Should -Invoke Wait-SAImporterCommand -Times 1 -ParameterFilter {
                    $CommandId -eq 12345 -and $TimeoutMinutes -eq $script:SAConstants.TbaRefreshTimeoutMinutes
                }
            }
        }
    }

    Context 'command send failure' {
        It 'returns failure without polling' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Invoke-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success   = $false
                        CommandId = $null
                        Status    = $null
                        Message   = 'API error'
                    }
                }

                Mock Wait-SAImporterCommand {}

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrSeriesRefresh -Config $config -SeriesId 100

                $result.Success | Should -BeFalse
                Should -Invoke Wait-SAImporterCommand -Times 0
            }
        }
    }
}

Describe 'Invoke-SAArrImport TBA refresh and retry' {

    Context 'TBA rejection triggers refresh and re-scan succeeds' {
        It 'should refresh metadata and import successfully' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Write-SAPhaseHeader {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Test-SAArrConnection { return $true }
                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
                Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }
                Mock Add-SAEmailException {}
                Mock Get-SAImportHint { return $null }

                # First scan: TBA rejection. Second scan: importable.
                $scanCallCount = 0
                Mock Invoke-SAArrManualImportScan {
                    $script:scanCallCount++
                    if ($script:scanCallCount -eq 1) {
                        return [PSCustomObject]@{
                            Success      = $true
                            ScanResults  = @(
                                @{
                                    path       = 'C:\Test\S01E01.mkv'
                                    quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                    series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                    episodes   = @( @{ id = 200 } )
                                    rejections = @( @{ type = 'permanent'; reason = 'Episode has a TBA title and recently aired' } )
                                }
                            )
                            ErrorMessage = $null
                        }
                    } else {
                        return [PSCustomObject]@{
                            Success      = $true
                            ScanResults  = @(
                                @{
                                    path       = 'C:\Test\S01E01.mkv'
                                    quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                    series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                    episodes   = @( @{ id = 200 } )
                                    languages  = @( @{ id = 1; name = 'English' } )
                                    rejections = @()
                                }
                            )
                            ErrorMessage = $null
                        }
                    }
                }

                Mock Invoke-SAArrSeriesRefresh {
                    return [PSCustomObject]@{ Success = $true; Message = 'Completed' }
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

                Mock Get-SAImportVerification {
                    return [PSCustomObject]@{
                        ImportedCount = 1
                        ExpectedCount = 1
                        IsComplete    = $true
                        Records       = @()
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

                $result.Success | Should -BeTrue
                $result.Skipped | Should -Not -BeTrue

                Should -Invoke Invoke-SAArrSeriesRefresh -Times 1 -ParameterFilter {
                    $SeriesId -eq 100
                }
                Should -Invoke Invoke-SAArrManualImportScan -Times 2
            }
        }
    }

    Context 'TBA rejection persists after refresh' {
        It 'should return warning with TBA hint' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Write-SAPhaseHeader {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Test-SAArrConnection { return $true }
                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
                Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }

                $capturedMessages = [System.Collections.Generic.List[string]]::new()
                Mock Add-SAEmailException {
                    $capturedMessages.Add($Message)
                }

                Mock Invoke-SAArrManualImportScan {
                    return [PSCustomObject]@{
                        Success      = $true
                        ScanResults  = @(
                            @{
                                path       = 'C:\Test\S01E01.mkv'
                                quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                episodes   = @( @{ id = 200; airDateUtc = '2026-11-06T19:30:00Z' } )
                                rejections = @( @{ type = 'permanent'; reason = 'Episode has a TBA title and recently aired' } )
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrSeriesRefresh {
                    return [PSCustomObject]@{ Success = $true; Message = 'Completed' }
                }

                Mock Get-SAImportHint { return 'test hint' }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

                $result.Success | Should -BeTrue
                $result.Skipped | Should -BeTrue
                $result.ErrorType | Should -Be 'tba'
                $result.LatestAirDateUtc | Should -Be ([datetime]::new(2026, 11, 6, 19, 30, 0, [DateTimeKind]::Utc))

                Should -Invoke Get-SAImportHint -Times 1 -ParameterFilter {
                    $ErrorType -eq 'tba'
                }
            }
        }
    }

    Context 'non-TBA rejection does not trigger refresh' {
        It 'should not call refresh for quality rejections' {
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
                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
                Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }

                Mock Invoke-SAArrManualImportScan {
                    return [PSCustomObject]@{
                        Success      = $true
                        ScanResults  = @(
                            @{
                                path       = 'C:\Test\S01E01.mkv'
                                quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                episodes   = @( @{ id = 200 } )
                                rejections = @( @{ type = 'permanent'; reason = 'Not an upgrade for existing episode file(s)' } )
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrSeriesRefresh {}

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

                Should -Invoke Invoke-SAArrSeriesRefresh -Times 0
            }
        }
    }
}

Describe 'Invoke-SAArrImport TBA retry pre-import refresh' {

    It 'refreshes series metadata before scanning on TBA retry' {
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
            Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
            Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }

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
                            rejections = @()
                        }
                    )
                    ErrorMessage = $null
                }
            }

            Mock Invoke-SAArrSeriesRefresh {
                return [PSCustomObject]@{ Success = $true; Message = 'Completed' }
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

            Mock Get-SAImportVerification {
                return [PSCustomObject]@{
                    ImportedCount = 1
                    ExpectedCount = 1
                    IsComplete    = $true
                    Records       = @()
                }
            }

            $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
            $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test' -IsTbaRetry

            Should -Invoke Invoke-SAArrSeriesRefresh -Times 1 -ParameterFilter {
                $SeriesId -eq 100
            }

            Should -Invoke Invoke-SAArrManualImportScan -Times 2
        }
    }

    It 'does not refresh on non-retry imports' {
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
            Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
            Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }

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
                            rejections = @()
                        }
                    )
                    ErrorMessage = $null
                }
            }

            Mock Invoke-SAArrSeriesRefresh {}

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

            Mock Get-SAImportVerification {
                return [PSCustomObject]@{
                    ImportedCount = 1
                    ExpectedCount = 1
                    IsComplete    = $true
                    Records       = @()
                }
            }

            $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
            $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

            Should -Invoke Invoke-SAArrSeriesRefresh -Times 0
        }
    }
}

Describe 'Test-SATbaRetrySuperseded' {

    It 'is true when every file was rejected as Quality exists' {
        InModuleScope 'Stagearr.Core' {
            $summary = [PSCustomObject]@{ IsAllRejected = $true; RejectedCount = 6; Reasons = @{ 'Quality exists' = 6 } }
            Test-SATbaRetrySuperseded -RejectionSummary $summary | Should -BeTrue
        }
    }

    It 'is false when another reason is mixed in' {
        InModuleScope 'Stagearr.Core' {
            $summary = [PSCustomObject]@{ IsAllRejected = $true; RejectedCount = 6; Reasons = @{ 'Quality exists' = 5; 'Episode title TBA' = 1 } }
            Test-SATbaRetrySuperseded -RejectionSummary $summary | Should -BeFalse
        }
    }

    It 'is false when some files are importable' {
        InModuleScope 'Stagearr.Core' {
            $summary = [PSCustomObject]@{ IsAllRejected = $false; RejectedCount = 2; Reasons = @{ 'Quality exists' = 2 } }
            Test-SATbaRetrySuperseded -RejectionSummary $summary | Should -BeFalse
        }
    }

    It 'is false when nothing was scanned' {
        InModuleScope 'Stagearr.Core' {
            $summary = [PSCustomObject]@{ IsAllRejected = $true; RejectedCount = 0; Reasons = @{} }
            Test-SATbaRetrySuperseded -RejectionSummary $summary | Should -BeFalse
        }
    }
}

Describe 'Invoke-SAArrImport quality rejection on a TBA retry' {

    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            Mock Write-SAVerbose {}
            Mock Write-SAProgress {}
            Mock Write-SAOutcome {}
            Mock Write-SAPhaseHeader {}
            Mock Add-SAEmailException {}
            Mock Get-SAImportHint { return 'hint' }
            Mock Get-SAImporterBaseUrl {
                return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
            }
            Mock Test-SAArrConnection { return $true }
            Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
            Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }
            Mock Invoke-SAArrSeriesRefresh { return [PSCustomObject]@{ Success = $true; Message = 'Completed' } }
            Mock Invoke-SAArrManualImportExecute {}
            Mock Invoke-SAArrManualImportScan {
                return [PSCustomObject]@{
                    Success      = $true
                    ScanResults  = @(
                        @{
                            path       = 'C:\Test\S01E01.mkv'
                            series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                            episodes   = @( @{ id = 200 } )
                            rejections = @( @{ type = 'permanent'; reason = 'Not an upgrade for existing episode file(s). Existing quality: WEBDL-2160p. New Quality WEBDL-1080p.' } )
                        }
                    )
                    ErrorMessage = $null
                }
            }
        }
    }

    It 'ends quietly as superseded on a retry' {
        InModuleScope 'Stagearr.Core' {
            $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
            $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test' -IsTbaRetry

            $result.Success | Should -BeTrue
            $result.Skipped | Should -BeTrue
            $result.QualityRejected | Should -BeTrue
            $result.Superseded | Should -BeTrue
            Should -Invoke Write-SAOutcome -Times 0 -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Skip' -and $Text -like '*equal or better quality*' }
            Should -Invoke Add-SAEmailException -Times 0
            Should -Invoke Get-SAImportHint -Times 0
            Should -Invoke Invoke-SAArrManualImportExecute -Times 0
        }
    }

    It 'still warns on a normal import' {
        InModuleScope 'Stagearr.Core' {
            $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
            $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

            $result.QualityRejected | Should -BeTrue
            $result.Superseded | Should -Not -BeTrue
            Should -Invoke Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke Add-SAEmailException -Times 1 -ParameterFilter { $Type -eq 'Warning' }
        }
    }
}
