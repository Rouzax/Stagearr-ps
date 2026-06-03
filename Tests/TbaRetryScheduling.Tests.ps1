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
