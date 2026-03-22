BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Restore-SAOrphanedJobs' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $script:testDir -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $script:testDir 'running') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $script:testDir 'pending') -ItemType Directory -Force | Out-Null
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            if (Test-Path $script:testDir) {
                Remove-Item -Path $script:testDir -Recurse -Force
            }
        }
    }

    It 'skips .tmp.* files and only recovers real job files' {
        InModuleScope 'Stagearr.Core' {
            $runningDir = Join-Path $script:testDir 'running'

            # Create a legitimate orphaned job file
            $validJob = @{
                id        = 'job-orphan-1'
                state     = 'running'
                createdAt = '2026-03-21T10:00:00Z'
                updatedAt = '2026-03-21T10:05:00Z'
                input     = @{
                    downloadPath  = 'C:\Downloads\Movie.2024'
                    downloadLabel = 'Movie'
                    torrentHash   = ''
                    noCleanup     = $false
                    noMail        = $false
                }
                result    = $null
            }
            $validJob | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $runningDir 'job-orphan-1.json')

            # Create a stale temp file (from crashed atomic write)
            '{"partial": true}' | Set-Content -Path (Join-Path $runningDir '.tmp.12345.job-orphan-1.json')

            $result = Restore-SAOrphanedJobs -QueueRoot $script:testDir

            # Should recover only the real job
            $result | Should -Be 1

            # The pending directory should contain the recovered job
            $pendingFiles = Get-ChildItem -LiteralPath (Join-Path $script:testDir 'pending') -Filter '*.json'
            $pendingFiles | Should -HaveCount 1
            $pendingFiles[0].Name | Should -Be 'job-orphan-1.json'
        }
    }

    It 'cleans up stale .tmp.* files from running directory' {
        InModuleScope 'Stagearr.Core' {
            $runningDir = Join-Path $script:testDir 'running'

            # Create multiple stale temp files
            '{"partial": true}' | Set-Content -Path (Join-Path $runningDir '.tmp.111.somejob.json')
            '' | Set-Content -Path (Join-Path $runningDir '.tmp.222.anotherjob.json')

            $result = Restore-SAOrphanedJobs -QueueRoot $script:testDir

            # No real jobs to recover
            $result | Should -Be 0

            # Temp files should be cleaned up
            $remainingFiles = Get-ChildItem -LiteralPath $runningDir -Filter '*.json' -ErrorAction SilentlyContinue
            $remainingFiles | Should -BeNullOrEmpty
        }
    }

    It 'recovers legitimate orphaned jobs (existing behavior preserved)' {
        InModuleScope 'Stagearr.Core' {
            $runningDir = Join-Path $script:testDir 'running'

            # Create two legitimate orphaned jobs
            $job1 = @{
                id        = 'job-recover-1'
                state     = 'running'
                createdAt = '2026-03-20T08:00:00Z'
                updatedAt = '2026-03-20T08:10:00Z'
                input     = @{
                    downloadPath  = 'C:\Downloads\Show.S01E01'
                    downloadLabel = 'TV'
                    torrentHash   = ''
                    noCleanup     = $false
                    noMail        = $false
                }
                result    = $null
            }

            $job2 = @{
                id        = 'job-recover-2'
                state     = 'running'
                createdAt = '2026-03-21T14:00:00Z'
                updatedAt = '2026-03-21T14:20:00Z'
                input     = @{
                    downloadPath  = 'C:\Downloads\Movie.2025'
                    downloadLabel = 'Movie'
                    torrentHash   = ''
                    noCleanup     = $false
                    noMail        = $false
                }
                result    = $null
            }

            $job1 | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $runningDir 'job-recover-1.json')
            $job2 | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $runningDir 'job-recover-2.json')

            $result = Restore-SAOrphanedJobs -QueueRoot $script:testDir

            $result | Should -Be 2

            # Both should be in pending
            $pendingFiles = Get-ChildItem -LiteralPath (Join-Path $script:testDir 'pending') -Filter '*.json'
            $pendingFiles | Should -HaveCount 2
        }
    }
}
