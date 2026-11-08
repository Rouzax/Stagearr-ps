BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'TBA retry scheduling in JobProcessor' {

    Context 'scheduling a retry from import result' {
        It 'queues a retry job when import returns TBA skip on non-retry job' {
            InModuleScope 'Stagearr.Core' {
                $importResult = [PSCustomObject]@{
                    Success         = $true
                    Skipped         = $true
                    ErrorType       = 'tba'
                    Message         = '1 file skipped (Episode title TBA)'
                    Duration        = 6
                    ImportedFiles   = @()
                    SkippedFiles    = @('C:\Test\S01E01.mkv')
                    SkippedCount    = 1
                    ArrMetadata     = @{ Title = 'Test Show'; Year = 2026 }
                    QualityRejected = $false
                }

                $job = @{
                    id    = 'test-job-123'
                    input = @{
                        downloadPath  = 'C:\Downloads\Test'
                        downloadLabel = 'TV'
                        torrentHash   = 'ABCDEF'
                        downloadRoot  = 'C:\Downloads'
                        tbaRetry      = $false
                    }
                }

                $result = Test-SATbaRetryNeeded -ImportResult $importResult -Job $job
                $result | Should -BeTrue

                # Verify it does NOT trigger on retry jobs
                $job.input.tbaRetry = $true
                $retryResult = Test-SATbaRetryNeeded -ImportResult $importResult -Job $job
                $retryResult | Should -BeFalse
            }
        }

        It 'does not trigger for non-TBA skips' {
            InModuleScope 'Stagearr.Core' {
                $importResult = [PSCustomObject]@{
                    Success         = $true
                    Skipped         = $true
                    ErrorType       = 'quality'
                    Message         = '1 file skipped (Quality exists)'
                    QualityRejected = $true
                }

                $job = @{
                    id    = 'test-job-456'
                    input = @{ tbaRetry = $false }
                }

                $result = Test-SATbaRetryNeeded -ImportResult $importResult -Job $job
                $result | Should -BeFalse
            }
        }

        It 'does not trigger for failed imports' {
            InModuleScope 'Stagearr.Core' {
                $importResult = [PSCustomObject]@{
                    Success   = $false
                    Skipped   = $false
                    ErrorType = $null
                    Message   = 'Connection failed'
                }

                $job = @{
                    id    = 'test-job-789'
                    input = @{ tbaRetry = $false }
                }

                $result = Test-SATbaRetryNeeded -ImportResult $importResult -Job $job
                $result | Should -BeFalse
            }
        }
    }
}

Describe 'Get-SATbaRetryAfter' {

    It 'waits 49 hours after the latest air date' {
        InModuleScope 'Stagearr.Core' {
            $now = [datetime]::new(2026, 11, 6, 0, 42, 0, [DateTimeKind]::Local)
            $air = $now.AddHours(20).ToUniversalTime()
            $retry = Get-SATbaRetryAfter -Now $now -LatestAirDateUtc $air
            $retry | Should -Be $now.AddHours(69)
        }
    }

    It 'can be sooner than 49 hours from now when the episode aired earlier' {
        InModuleScope 'Stagearr.Core' {
            $now = [datetime]::new(2026, 11, 6, 0, 42, 0, [DateTimeKind]::Local)
            $air = $now.AddHours(-10).ToUniversalTime()
            $retry = Get-SATbaRetryAfter -Now $now -LatestAirDateUtc $air
            $retry | Should -Be $now.AddHours(39)
        }
    }

    It 'falls back to 49 hours from now without an air date' {
        InModuleScope 'Stagearr.Core' {
            $now = [datetime]::new(2026, 11, 6, 0, 42, 0, [DateTimeKind]::Local)
            Get-SATbaRetryAfter -Now $now -LatestAirDateUtc $null | Should -Be $now.AddHours(49)
        }
    }

    It 'falls back to 49 hours from now when the window has already passed' {
        InModuleScope 'Stagearr.Core' {
            $now = [datetime]::new(2026, 11, 6, 0, 42, 0, [DateTimeKind]::Local)
            $air = $now.AddHours(-60).ToUniversalTime()
            Get-SATbaRetryAfter -Now $now -LatestAirDateUtc $air | Should -Be $now.AddHours(49)
        }
    }

    It 'waits no longer than the maximum delay for a far-future air date' {
        InModuleScope 'Stagearr.Core' {
            $now = [datetime]::new(2026, 11, 6, 0, 42, 0, [DateTimeKind]::Local)
            $air = $now.AddDays(90).ToUniversalTime()
            $retry = Get-SATbaRetryAfter -Now $now -LatestAirDateUtc $air
            $retry | Should -Be $now.AddDays($script:SAConstants.TbaRetryMaxDelayDays)
        }
    }
}

Describe 'Get-SALatestEpisodeAirDate' {

    It 'returns the latest air date across all files and episodes, as UTC' {
        InModuleScope 'Stagearr.Core' {
            $scan = @(
                @{ episodes = @( @{ airDateUtc = [datetime]::new(2026, 11, 5, 19, 0, 0, [DateTimeKind]::Utc) } ) },
                @{ episodes = @( @{ airDateUtc = '2026-11-06T19:30:00Z' }, @{ airDateUtc = $null } ) }
            )
            $latest = Get-SALatestEpisodeAirDate -ScanResults $scan
            $latest | Should -Be ([datetime]::new(2026, 11, 6, 19, 30, 0, [DateTimeKind]::Utc))
            $latest.Kind | Should -Be 'Utc'
        }
    }

    It 'returns null when no episode has an air date' {
        InModuleScope 'Stagearr.Core' {
            $scan = @( @{ episodes = @( @{ airDateUtc = $null } ) }, @{ path = 'x' } )
            Get-SALatestEpisodeAirDate -ScanResults $scan | Should -BeNullOrEmpty
        }
    }

    It 'ignores an unreadable air date' {
        InModuleScope 'Stagearr.Core' {
            $scan = @( @{ episodes = @( @{ airDateUtc = 'not a date' } ) } )
            Get-SALatestEpisodeAirDate -ScanResults $scan | Should -BeNullOrEmpty
        }
    }
}
