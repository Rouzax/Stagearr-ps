BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Add-SAJob retry parameters' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            $script:testQueue = Join-Path ([System.IO.Path]::GetTempPath()) "sa-test-queue-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            Mock Write-SAVerbose {}
            Mock Write-SAProgress {}
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            if (Test-Path $script:testQueue) {
                Remove-Item -Path $script:testQueue -Recurse -Force
            }
        }
    }

    It 'stores retryAfter in job JSON when provided' {
        InModuleScope 'Stagearr.Core' {
            $retryTime = [datetime]'2026-06-10T12:00:00Z'
            $job = Add-SAJob -QueueRoot $script:testQueue `
                -DownloadPath 'C:\Downloads\Show.S01E01' `
                -DownloadLabel 'TV' `
                -RetryAfter $retryTime `
                -TbaRetry `
                -StagingPath 'C:\Staging\Show.S01E01'

            $job | Should -Not -BeNullOrEmpty
            $job.input.tbaRetry | Should -Be $true
            $job.input.stagingPath | Should -Be 'C:\Staging\Show.S01E01'
            $job.input.retryAfter | Should -Not -BeNullOrEmpty
        }
    }

    It 'stores null retryAfter when not provided' {
        InModuleScope 'Stagearr.Core' {
            $job = Add-SAJob -QueueRoot $script:testQueue `
                -DownloadPath 'C:\Downloads\Movie.2024' `
                -DownloadLabel 'Movie'

            $job | Should -Not -BeNullOrEmpty
            $job.input.tbaRetry | Should -Be $false
            $job.input.stagingPath | Should -Be ''
            $job.input.retryAfter | Should -BeNullOrEmpty
        }
    }

    It 'persists retryAfter to disk as ISO 8601 string' {
        InModuleScope 'Stagearr.Core' {
            $retryTime = [datetime]'2026-06-15T08:30:00Z'
            $job = Add-SAJob -QueueRoot $script:testQueue `
                -DownloadPath 'C:\Downloads\Show.S02E05' `
                -DownloadLabel 'TV' `
                -RetryAfter $retryTime

            $job | Should -Not -BeNullOrEmpty

            $jobFile = Join-Path $script:testQueue "pending/$($job.id).json"
            $persisted = Get-Content -LiteralPath $jobFile -Raw | ConvertFrom-Json

            $persisted.input.retryAfter | Should -Not -BeNullOrEmpty
            $parsed = [datetime]::Parse($persisted.input.retryAfter)
            $parsed.ToUniversalTime() | Should -Be $retryTime.ToUniversalTime()
        }
    }
}

Describe 'Get-SANextPendingJob retryAfter filtering' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            $script:testQueue = Join-Path ([System.IO.Path]::GetTempPath()) "sa-test-queue-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -Path (Join-Path $script:testQueue 'pending') -ItemType Directory -Force | Out-Null
            Mock Write-SAVerbose {}
            Mock Write-SAProgress {}
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            if (Test-Path $script:testQueue) {
                Remove-Item -Path $script:testQueue -Recurse -Force
            }
        }
    }

    It 'skips jobs whose retryAfter is in the future' {
        InModuleScope 'Stagearr.Core' {
            $futureTime = (Get-Date).AddHours(2).ToString('o')
            $job = @{
                id        = 'job-future-retry'
                version   = 1
                state     = 'pending'
                attempts  = 0
                lastError = $null
                input     = @{
                    downloadPath  = 'C:\Downloads\Show.S01E01'
                    downloadLabel = 'TV'
                    torrentHash   = ''
                    downloadRoot  = ''
                    noCleanup     = $false
                    noMail        = $false
                    retryAfter    = $futureTime
                    tbaRetry      = $true
                    stagingPath   = ''
                }
                result    = $null
            }
            $job | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testQueue 'pending/job-future-retry.json')

            $result = Get-SANextPendingJob -QueueRoot $script:testQueue

            $result | Should -BeNullOrEmpty
        }
    }

    It 'returns jobs whose retryAfter has passed' {
        InModuleScope 'Stagearr.Core' {
            $pastTime = (Get-Date).AddHours(-1).ToString('o')
            $job = @{
                id        = 'job-past-retry'
                version   = 1
                state     = 'pending'
                attempts  = 0
                lastError = $null
                input     = @{
                    downloadPath  = 'C:\Downloads\Show.S01E02'
                    downloadLabel = 'TV'
                    torrentHash   = ''
                    downloadRoot  = ''
                    noCleanup     = $false
                    noMail        = $false
                    retryAfter    = $pastTime
                    tbaRetry      = $true
                    stagingPath   = ''
                }
                result    = $null
            }
            $job | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testQueue 'pending/job-past-retry.json')

            $result = Get-SANextPendingJob -QueueRoot $script:testQueue

            $result | Should -Not -BeNullOrEmpty
            $result.id | Should -Be 'job-past-retry'
        }
    }

    It 'returns regular jobs even when retry jobs are pending' {
        InModuleScope 'Stagearr.Core' {
            $futureTime = (Get-Date).AddHours(3).ToString('o')
            $futureRetryJob = @{
                id        = 'aaaa-future-retry'
                version   = 1
                state     = 'pending'
                attempts  = 0
                lastError = $null
                input     = @{
                    downloadPath  = 'C:\Downloads\Show.S01E03'
                    downloadLabel = 'TV'
                    torrentHash   = ''
                    downloadRoot  = ''
                    noCleanup     = $false
                    noMail        = $false
                    retryAfter    = $futureTime
                    tbaRetry      = $true
                    stagingPath   = ''
                }
                result    = $null
            }

            $regularJob = @{
                id        = 'zzzz-regular-job'
                version   = 1
                state     = 'pending'
                attempts  = 0
                lastError = $null
                input     = @{
                    downloadPath  = 'C:\Downloads\Movie.2024'
                    downloadLabel = 'Movie'
                    torrentHash   = ''
                    downloadRoot  = ''
                    noCleanup     = $false
                    noMail        = $false
                    retryAfter    = $null
                    tbaRetry      = $false
                    stagingPath   = ''
                }
                result    = $null
            }

            $futureRetryJob | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testQueue 'pending/aaaa-future-retry.json')
            $regularJob | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testQueue 'pending/zzzz-regular-job.json')

            $result = Get-SANextPendingJob -QueueRoot $script:testQueue

            $result | Should -Not -BeNullOrEmpty
            $result.id | Should -Be 'zzzz-regular-job'
        }
    }

    It 'skips future retry jobs under a non-US date culture (nl-NL)' {
        InModuleScope 'Stagearr.Core' {
            # Regression: ConvertFrom-Json turns retryAfter into a [datetime], which
            # PowerShell coerces back to an invariant MM/dd/yyyy string. The old code
            # called [datetime]::Parse without a culture, so under nl-NL (and other
            # non-US cultures) the day/month swap made the parse throw, and the catch
            # block processed the TBA retry immediately instead of waiting.
            $futureTime = (Get-Date).AddHours(49).ToString('o')
            $job = @{
                id        = 'job-future-culture'
                version   = 1
                state     = 'pending'
                attempts  = 0
                lastError = $null
                input     = @{
                    downloadPath  = 'C:\Downloads\Show.S01E06'
                    downloadLabel = 'TV'
                    torrentHash   = ''
                    downloadRoot  = ''
                    noCleanup     = $false
                    noMail        = $false
                    retryAfter    = $futureTime
                    tbaRetry      = $true
                    stagingPath   = ''
                }
                result    = $null
            }
            $job | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testQueue 'pending/job-future-culture.json')

            $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('nl-NL')
                $result = Get-SANextPendingJob -QueueRoot $script:testQueue
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
            }

            $result | Should -BeNullOrEmpty
        }
    }

    It 'returns null when only future retry jobs exist' {
        InModuleScope 'Stagearr.Core' {
            $futureTime1 = (Get-Date).AddHours(1).ToString('o')
            $futureTime2 = (Get-Date).AddHours(2).ToString('o')

            $job1 = @{
                id        = 'job-future-1'
                version   = 1
                state     = 'pending'
                attempts  = 0
                lastError = $null
                input     = @{
                    downloadPath  = 'C:\Downloads\Show.S01E04'
                    downloadLabel = 'TV'
                    torrentHash   = ''
                    downloadRoot  = ''
                    noCleanup     = $false
                    noMail        = $false
                    retryAfter    = $futureTime1
                    tbaRetry      = $true
                    stagingPath   = ''
                }
                result    = $null
            }

            $job2 = @{
                id        = 'job-future-2'
                version   = 1
                state     = 'pending'
                attempts  = 0
                lastError = $null
                input     = @{
                    downloadPath  = 'C:\Downloads\Show.S01E05'
                    downloadLabel = 'TV'
                    torrentHash   = ''
                    downloadRoot  = ''
                    noCleanup     = $false
                    noMail        = $false
                    retryAfter    = $futureTime2
                    tbaRetry      = $true
                    stagingPath   = ''
                }
                result    = $null
            }

            $job1 | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testQueue 'pending/job-future-1.json')
            $job2 | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testQueue 'pending/job-future-2.json')

            $result = Get-SANextPendingJob -QueueRoot $script:testQueue

            $result | Should -BeNullOrEmpty
        }
    }
}
