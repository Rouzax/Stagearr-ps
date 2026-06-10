BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SALockInfo heartbeatAt parsing' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sa-lock-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force }
    }

    It 'parses heartbeatAt as a UTC datetime' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            $lockPath = Join-Path $tmp '.lock'
            $hb = '2026-06-10T07:30:00.0000000Z'
            @{ pid = 111; hostname = 'H'; processStartTimeUnix = 1; startedAt = '2026-06-10T07:00:00Z'; heartbeatAt = $hb; version = 4 } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $lockPath -Encoding UTF8
            $info = Get-SALockInfo -LockPath $lockPath
            $info.heartbeatAt | Should -BeOfType ([datetime])
            $info.heartbeatAt.ToUniversalTime().ToString('o') | Should -Be '2026-06-10T07:30:00.0000000Z'
            $info.processStartTimeUnix | Should -Be 1
        }
    }

    It 'returns null heartbeatAt for a legacy v3 lock' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            $lockPath = Join-Path $tmp '.lock'
            @{ pid = 111; hostname = 'H'; processStartTimeUnix = 1; startedAt = '2026-06-10T07:00:00Z'; version = 3 } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $lockPath -Encoding UTF8
            $info = Get-SALockInfo -LockPath $lockPath
            $info.heartbeatAt | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-SALockStale (heartbeat-based)' {
    It 'fresh heartbeat on same machine is not stale' {
        InModuleScope 'Stagearr.Core' {
            $info = @{
                pid = $PID; hostname = $env:COMPUTERNAME
                processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime()
                heartbeatAt = [datetime]::UtcNow.AddSeconds(-10); startedAt = (Get-Date).AddMinutes(-30)
            }
            Test-SALockStale -LockInfo $info -StaleSeconds 120 | Should -BeFalse
        }
    }

    It 'silent heartbeat past threshold is stale (remote machine)' {
        InModuleScope 'Stagearr.Core' {
            $info = @{
                pid = 999999; hostname = 'OTHER-HOST'
                processStartTime = [datetime]::UtcNow
                heartbeatAt = [datetime]::UtcNow.AddSeconds(-200); startedAt = (Get-Date).AddMinutes(-30)
            }
            Test-SALockStale -LockInfo $info -StaleSeconds 120 | Should -BeTrue
        }
    }

    It 'future-dated heartbeat is treated as alive (clock-backward safety)' {
        InModuleScope 'Stagearr.Core' {
            $info = @{
                pid = 999999; hostname = 'OTHER-HOST'
                processStartTime = [datetime]::UtcNow
                heartbeatAt = [datetime]::UtcNow.AddSeconds(120); startedAt = (Get-Date)
            }
            Test-SALockStale -LockInfo $info -StaleSeconds 120 | Should -BeFalse
        }
    }

    It 'dead PID on same machine is stale immediately even with fresh heartbeat' {
        InModuleScope 'Stagearr.Core' {
            $info = @{
                pid = 999999; hostname = $env:COMPUTERNAME
                processStartTime = [datetime]::UtcNow
                heartbeatAt = [datetime]::UtcNow.AddSeconds(-5); startedAt = (Get-Date)
            }
            Test-SALockStale -LockInfo $info -StaleSeconds 120 | Should -BeTrue
        }
    }

    It 'legacy v3 remote lock falls back to startedAt age' {
        InModuleScope 'Stagearr.Core' {
            $info = @{
                pid = 999999; hostname = 'OTHER-HOST'
                processStartTime = [datetime]::UtcNow
                heartbeatAt = $null; startedAt = (Get-Date).AddSeconds(-200)
            }
            Test-SALockStale -LockInfo $info -StaleSeconds 120 | Should -BeTrue
        }
    }
}
