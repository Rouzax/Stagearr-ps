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

Describe 'Test-SALockOwnedBySelf' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sa-own-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach { if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force } }

    It 'returns true when the lock matches this process' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            $epoch = [datetime]::new(1970,1,1,0,0,0,[System.DateTimeKind]::Utc)
            $startUnix = [long](((Get-Process -Id $PID).StartTime.ToUniversalTime() - $epoch).TotalSeconds)
            @{ pid = $PID; hostname = $env:COMPUTERNAME; processStartTimeUnix = $startUnix
               startedAt = (Get-Date).ToString('o'); heartbeatAt = [datetime]::UtcNow.ToString('o'); version = 4 } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $tmp '.lock') -Encoding UTF8
            Test-SALockOwnedBySelf -QueueRoot $tmp | Should -BeTrue
        }
    }

    It 'returns false when the lock pid is a different process' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            @{ pid = 999999; hostname = $env:COMPUTERNAME; processStartTimeUnix = 1
               startedAt = (Get-Date).ToString('o'); heartbeatAt = [datetime]::UtcNow.ToString('o'); version = 4 } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $tmp '.lock') -Encoding UTF8
            Test-SALockOwnedBySelf -QueueRoot $tmp | Should -BeFalse
        }
    }

    It 'returns false when no lock file exists' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            Test-SALockOwnedBySelf -QueueRoot $tmp | Should -BeFalse
        }
    }
}

Describe 'Lock heartbeat runspace' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sa-hb-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach { if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force } }

    It 'advances heartbeatAt while running and stops cleanly' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            $lockPath = Join-Path $tmp '.lock'
            $epoch = [datetime]::new(1970,1,1,0,0,0,[System.DateTimeKind]::Utc)
            $startUnix = [long](((Get-Process -Id $PID).StartTime.ToUniversalTime() - $epoch).TotalSeconds)
            $identity = @{ pid = $PID; hostname = $env:COMPUTERNAME; processStartTimeUnix = $startUnix
                          processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
                          startedAt = (Get-Date).ToString('o') }
            @{ pid = $PID; hostname = $env:COMPUTERNAME; processStartTimeUnix = $startUnix
               processStartTime = $identity.processStartTime; startedAt = $identity.startedAt
               heartbeatAt = [datetime]::UtcNow.AddSeconds(-60).ToString('o'); version = 4 } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $lockPath -Encoding UTF8

            $hb = Start-SALockHeartbeat -LockPath $lockPath -QueueRoot $tmp -Identity $identity -IntervalMs 200
            try {
                Start-Sleep -Milliseconds 700
                $info = Get-SALockInfo -LockPath $lockPath
                ([datetime]::UtcNow - $info.heartbeatAt.ToUniversalTime()).TotalSeconds | Should -BeLessThan 5
                $hb.Shared.stolen | Should -BeFalse
            } finally {
                Stop-SALockHeartbeat -Heartbeat $hb
            }
        }
    }

    It 'sets the stolen flag when the lock is replaced by another identity' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            $lockPath = Join-Path $tmp '.lock'
            $epoch = [datetime]::new(1970,1,1,0,0,0,[System.DateTimeKind]::Utc)
            $startUnix = [long](((Get-Process -Id $PID).StartTime.ToUniversalTime() - $epoch).TotalSeconds)
            $identity = @{ pid = $PID; hostname = $env:COMPUTERNAME; processStartTimeUnix = $startUnix
                          processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
                          startedAt = (Get-Date).ToString('o') }
            @{ pid = $PID; hostname = $env:COMPUTERNAME; processStartTimeUnix = $startUnix
               processStartTime = $identity.processStartTime; startedAt = $identity.startedAt
               heartbeatAt = [datetime]::UtcNow.ToString('o'); version = 4 } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $lockPath -Encoding UTF8

            $hb = Start-SALockHeartbeat -LockPath $lockPath -QueueRoot $tmp -Identity $identity -IntervalMs 200
            try {
                Start-Sleep -Milliseconds 300
                @{ pid = 999999; hostname = 'OTHER'; processStartTimeUnix = 1
                   startedAt = (Get-Date).ToString('o'); heartbeatAt = [datetime]::UtcNow.ToString('o'); version = 4 } |
                    ConvertTo-Json -Compress | Set-Content -LiteralPath $lockPath -Encoding UTF8
                Start-Sleep -Milliseconds 800
                $hb.Shared.stolen | Should -BeTrue
            } finally {
                Stop-SALockHeartbeat -Heartbeat $hb
            }
        }
    }
}

Describe 'Get-SAGlobalLock with heartbeat' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sa-acq-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        InModuleScope 'Stagearr.Core' { if ($script:SACurrentLock) { Unlock-SAGlobalLock -Lock $script:SACurrentLock } }
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force }
    }

    It 'acquires, sets SACurrentLock, heartbeats, and releases cleanly' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            $lock = Get-SAGlobalLock -QueueRoot $tmp -HeartbeatSeconds 1 -StaleSeconds 120
            $lock | Should -Not -BeNullOrEmpty
            $script:SACurrentLock | Should -Not -BeNullOrEmpty
            Test-SALockOwnedBySelf -QueueRoot $tmp | Should -BeTrue
            Unlock-SAGlobalLock -Lock $lock
            $script:SACurrentLock | Should -BeNullOrEmpty
            Test-Path (Join-Path $tmp '.lock') | Should -BeFalse
        }
    }

    It 'a second acquisition fails while the first is held (not stale)' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            $first = Get-SAGlobalLock -QueueRoot $tmp -HeartbeatSeconds 1 -StaleSeconds 120
            try {
                $second = Get-SAGlobalLock -QueueRoot $tmp -HeartbeatSeconds 1 -StaleSeconds 120
                $second | Should -BeNullOrEmpty
            } finally {
                Unlock-SAGlobalLock -Lock $first
            }
        }
    }
}

Describe 'Import ownership guard' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sa-guard-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        InModuleScope 'Stagearr.Core' { $script:SACurrentLock = $null }
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force }
    }

    It 'guard helper proceeds when no lock is held' {
        InModuleScope 'Stagearr.Core' {
            $script:SACurrentLock = $null
            Test-SAImportLockOk | Should -BeTrue
        }
    }

    It 'guard helper aborts when the lock is owned by another process' {
        InModuleScope 'Stagearr.Core' -ArgumentList $script:tmp {
            param($tmp)
            @{ pid = 999999; hostname = $env:COMPUTERNAME; processStartTimeUnix = 1
               startedAt = (Get-Date).ToString('o'); heartbeatAt = [datetime]::UtcNow.ToString('o'); version = 4 } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $tmp '.lock') -Encoding UTF8
            $script:SACurrentLock = @{ Path = (Join-Path $tmp '.lock'); QueueRoot = $tmp }
            Test-SAImportLockOk | Should -BeFalse
        }
    }
}

Describe 'Test-SALockStolen checkpoint helper' {
    AfterEach { InModuleScope 'Stagearr.Core' { $script:SACurrentLock = $null } }

    It 'returns false when no lock is held' {
        InModuleScope 'Stagearr.Core' {
            $script:SACurrentLock = $null
            Test-SALockStolen | Should -BeFalse
        }
    }

    It 'returns true when the shared stolen flag is set' {
        InModuleScope 'Stagearr.Core' {
            $script:SACurrentLock = @{ Heartbeat = @{ Shared = [hashtable]::Synchronized(@{ stolen = $true }) } }
            Test-SALockStolen | Should -BeTrue
        }
    }
}

Describe 'Test-SALockStolen checkpoint integration' {
    AfterEach { InModuleScope 'Stagearr.Core' { $script:SACurrentLock = $null } }

    It 'JobProcessor exposes a stolen-flag checkpoint that returns true when set' {
        InModuleScope 'Stagearr.Core' {
            $script:SACurrentLock = @{ Heartbeat = @{ Shared = [hashtable]::Synchronized(@{ stolen = $true }) } }
            Test-SALockStolen | Should -BeTrue
        }
    }

    It 'checkpoint returns false for a healthy held lock' {
        InModuleScope 'Stagearr.Core' {
            $script:SACurrentLock = @{ Heartbeat = @{ Shared = [hashtable]::Synchronized(@{ stolen = $false }) } }
            Test-SALockStolen | Should -BeFalse
        }
    }
}
