BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Start-SAWorker TBA retry completion handling' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            $script:testQueue = Join-Path ([System.IO.Path]::GetTempPath()) "sa-worker-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            foreach ($s in 'pending', 'running', 'completed', 'failed') {
                New-Item -Path (Join-Path $script:testQueue $s) -ItemType Directory -Force | Out-Null
            }

            # Quiet output and stub the heavy context/log machinery so the test
            # exercises only the worker's completion/state-machine logic.
            Mock Write-SAOutcome {}
            Mock Write-SAProgress {}
            Mock Write-SAVerbose {}
            Mock Write-SAPhaseHeader {}
            Mock Reset-SAJobState {}
            Mock Initialize-SAContext {}
            Mock Get-SAContextDuration { [timespan]::FromSeconds(5) }
            Mock Get-SAContextLogPath { '' }
            Mock Save-SAFileLog { '' }
            Mock Unlock-SAGlobalLock {}
            Mock Get-SAGlobalLock { @{ path = 'fake-lock'; pid = 1 } }
            # Fresh context per job; ProcessJob mutates Flags and the worker reads them.
            Mock New-SAContext {
                @{
                    Flags = @{ NoCleanup = $false; TbaRetryScheduled = $false }
                    Paths = @{ QueueRoot = $script:testQueue }
                }
            }

            $script:testConfig = @{
                processing = @{ staleHeartbeatSeconds = 300; heartbeatSeconds = 30 }
            }
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            if (Test-Path $script:testQueue) {
                Remove-Item -Path $script:testQueue -Recurse -Force
            }
        }
    }

    It 'does not write a completed record when the job re-queued a TBA retry' {
        InModuleScope 'Stagearr.Core' {
            $dp = 'C:\Downloads\Show.S01E01\Show.S01E01.mkv'
            $hash = 'ABCDEF123456'
            Add-SAJob -QueueRoot $script:testQueue -DownloadPath $dp -DownloadLabel 'TV' -TorrentHash $hash | Out-Null

            # Mimic Invoke-SAJobProcessing detecting TBA: re-queue the retry under
            # the same deterministic id, set the flag, and report success.
            $processJob = {
                param($Context, $Job)
                Add-SAJob -QueueRoot $Context.Paths.QueueRoot `
                    -DownloadPath $Job.input.downloadPath `
                    -DownloadLabel $Job.input.downloadLabel `
                    -TorrentHash $Job.input.torrentHash `
                    -RetryAfter (Get-Date).AddHours(49) `
                    -TbaRetry -Force | Out-Null
                $Context.Flags.TbaRetryScheduled = $true
                return $true
            }

            Start-SAWorker -QueueRoot $script:testQueue -Config $script:testConfig -MaxJobs 1 -ProcessJob $processJob

            $completed = @(Get-ChildItem -LiteralPath (Join-Path $script:testQueue 'completed') -Filter '*.json')
            $running = @(Get-ChildItem -LiteralPath (Join-Path $script:testQueue 'running') -Filter '*.json')
            $pending = @(Get-ChildItem -LiteralPath (Join-Path $script:testQueue 'pending') -Filter '*.json')

            $completed | Should -HaveCount 0
            $running | Should -HaveCount 0
            $pending | Should -HaveCount 1

            # The single remaining file is the pending retry.
            $retry = Get-Content -LiteralPath $pending[0].FullName -Raw | ConvertFrom-Json
            $retry.state | Should -Be 'pending'
            $retry.input.tbaRetry | Should -BeTrue
            $retry.input.retryAfter | Should -Not -BeNullOrEmpty
        }
    }

    It 'still writes a completed record for a normal successful job' {
        InModuleScope 'Stagearr.Core' {
            $dp = 'C:\Downloads\Movie.2024\Movie.2024.mkv'
            Add-SAJob -QueueRoot $script:testQueue -DownloadPath $dp -DownloadLabel 'Movie' -TorrentHash 'FFFFFF' | Out-Null

            # Worker passes ($context, $job) positionally; this stub ignores them.
            $processJob = { $true }

            Start-SAWorker -QueueRoot $script:testQueue -Config $script:testConfig -MaxJobs 1 -ProcessJob $processJob

            $completed = @(Get-ChildItem -LiteralPath (Join-Path $script:testQueue 'completed') -Filter '*.json')
            $pending = @(Get-ChildItem -LiteralPath (Join-Path $script:testQueue 'pending') -Filter '*.json')

            $completed | Should -HaveCount 1
            $pending | Should -HaveCount 0
        }
    }
}
