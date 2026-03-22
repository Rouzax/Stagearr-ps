BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SARerunJobList' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $script:testDir -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $script:testDir 'completed') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $script:testDir 'failed') -ItemType Directory -Force | Out-Null
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            if (Test-Path $script:testDir) {
                Remove-Item -Path $script:testDir -Recurse -Force
            }
        }
    }

    It 'returns empty array when no jobs exist' {
        InModuleScope 'Stagearr.Core' {
            $result = Get-SARerunJobList -QueueRoot $script:testDir -Limit 10
            $result | Should -HaveCount 0
        }
    }

    It 'merges completed and failed jobs sorted by updatedAt descending' {
        InModuleScope 'Stagearr.Core' {
            # Create a completed job with an older timestamp
            $completedJob = @{
                id        = 'job-completed-1'
                state     = 'completed'
                createdAt = '2026-03-20T10:00:00Z'
                updatedAt = '2026-03-20T10:30:00Z'
                input     = @{
                    downloadPath  = 'C:\Downloads\Movie.2024'
                    downloadLabel = 'Movie'
                    torrentHash   = ''
                    noCleanup     = $false
                    noMail        = $false
                }
                result    = $null
            }

            # Create a failed job with a newer timestamp
            $failedJob = @{
                id        = 'job-failed-1'
                state     = 'failed'
                createdAt = '2026-03-21T08:00:00Z'
                updatedAt = '2026-03-21T08:15:00Z'
                input     = @{
                    downloadPath  = 'C:\Downloads\Show.S01E01'
                    downloadLabel = 'TV'
                    torrentHash   = ''
                    noCleanup     = $false
                    noMail        = $false
                }
                lastError = 'Import failed'
                result    = $null
            }

            # Create another completed job with the newest timestamp
            $completedJob2 = @{
                id        = 'job-completed-2'
                state     = 'completed'
                createdAt = '2026-03-22T14:00:00Z'
                updatedAt = '2026-03-22T14:05:00Z'
                input     = @{
                    downloadPath  = 'C:\Downloads\Movie.2025'
                    downloadLabel = 'Movie'
                    torrentHash   = ''
                    noCleanup     = $false
                    noMail        = $false
                }
                result    = $null
            }

            # Write job files
            $completedJob | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testDir 'completed/job-completed-1.json')
            $failedJob | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testDir 'failed/job-failed-1.json')
            $completedJob2 | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testDir 'completed/job-completed-2.json')

            $result = Get-SARerunJobList -QueueRoot $script:testDir -Limit 10

            $result | Should -HaveCount 3
            # Newest first
            $result[0].id | Should -Be 'job-completed-2'
            $result[1].id | Should -Be 'job-failed-1'
            $result[2].id | Should -Be 'job-completed-1'
        }
    }

    It 'respects the limit parameter' {
        InModuleScope 'Stagearr.Core' {
            # Create 3 completed jobs
            for ($i = 1; $i -le 3; $i++) {
                $job = @{
                    id        = "job-limit-$i"
                    state     = 'completed'
                    createdAt = "2026-03-${i}T10:00:00Z"
                    updatedAt = "2026-03-0${i}T10:00:00Z"
                    input     = @{
                        downloadPath  = "C:\Downloads\Movie.$i"
                        downloadLabel = 'Movie'
                        torrentHash   = ''
                        noCleanup     = $false
                        noMail        = $false
                    }
                    result    = $null
                }
                $job | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:testDir "completed/job-limit-$i.json")
            }

            $result = Get-SARerunJobList -QueueRoot $script:testDir -Limit 2
            $result | Should -HaveCount 2
        }
    }
}

Describe 'Invoke-SARerun edge cases' {
    It 'displays message and returns when no jobs exist' {
        InModuleScope 'Stagearr.Core' {
            $queueRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-rerun-test-$(New-Guid)"
            New-Item -Path "$queueRoot/completed" -ItemType Directory -Force | Out-Null
            New-Item -Path "$queueRoot/failed" -ItemType Directory -Force | Out-Null

            $config = @{ paths = @{ queueRoot = $queueRoot } }

            # Should return without prompting (no Read-Host call)
            Invoke-SARerun -QueueRoot $queueRoot -Config $config -Limit 10 -ProcessJob { }

            Remove-Item -Path $queueRoot -Recurse -Force
        }
    }
}
