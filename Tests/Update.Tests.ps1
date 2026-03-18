BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Compare-SAVersions' {
    It 'returns -1 when local is older than remote' {
        InModuleScope 'Stagearr.Core' {
            Compare-SAVersions -LocalVersion '2.0.2' -RemoteVersion '2.1.0' | Should -Be -1
        }
    }

    It 'returns 0 when versions are equal' {
        InModuleScope 'Stagearr.Core' {
            Compare-SAVersions -LocalVersion '2.0.2' -RemoteVersion '2.0.2' | Should -Be 0
        }
    }

    It 'returns 1 when local is newer than remote' {
        InModuleScope 'Stagearr.Core' {
            Compare-SAVersions -LocalVersion '2.1.0' -RemoteVersion '2.0.2' | Should -Be 1
        }
    }

    It 'handles major version differences' {
        InModuleScope 'Stagearr.Core' {
            Compare-SAVersions -LocalVersion '1.9.9' -RemoteVersion '2.0.0' | Should -Be -1
        }
    }
}

Describe 'Test-SAUpdateCheckDue' {
    It 'returns true when no timestamp file exists' {
        InModuleScope 'Stagearr.Core' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
            try {
                Test-SAUpdateCheckDue -QueueRoot $tempDir -IntervalHours 24 | Should -BeTrue
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force
            }
        }
    }

    It 'returns true when interval is 0 (check every run)' {
        InModuleScope 'Stagearr.Core' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
            try {
                Save-SAUpdateTimestamp -QueueRoot $tempDir
                Test-SAUpdateCheckDue -QueueRoot $tempDir -IntervalHours 0 | Should -BeTrue
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force
            }
        }
    }

    It 'returns false when check was recent' {
        InModuleScope 'Stagearr.Core' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
            try {
                Save-SAUpdateTimestamp -QueueRoot $tempDir
                Test-SAUpdateCheckDue -QueueRoot $tempDir -IntervalHours 24 | Should -BeFalse
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force
            }
        }
    }
}

Describe 'Invoke-SAUpdateCheck' {
    It 'skips when mode is off' {
        InModuleScope 'Stagearr.Core' {
            Mock Get-SALatestRelease {}

            $config = @{
                updates = @{ mode = 'off'; checkIntervalHours = 0 }
                paths   = @{ queueRoot = 'C:\fake' }
            }

            Invoke-SAUpdateCheck -Config $config -LocalVersion '2.0.2' -ScriptRoot 'C:\fake'

            Should -Not -Invoke Get-SALatestRelease
        }
    }

    It 'sets UpdateAvailable when remote is newer in notify mode' {
        InModuleScope 'Stagearr.Core' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            Mock Get-SALatestRelease {
                return @{ Version = '2.1.0'; TagName = 'v2.1.0'; Url = 'https://github.com/Rouzax/Stagearr-ps/releases/tag/v2.1.0' }
            }
            Mock Write-SAOutcome {}

            $config = @{
                updates = @{ mode = 'notify'; checkIntervalHours = 0 }
                paths   = @{ queueRoot = $tempDir }
            }

            try {
                Invoke-SAUpdateCheck -Config $config -LocalVersion '2.0.2' -ScriptRoot $tempDir

                $state = Get-SAUpdateState
                $state.UpdateAvailable | Should -BeTrue
                $state.NewVersion | Should -Be '2.1.0'
                $state.UpdateApplied | Should -BeFalse
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force
            }
        }
    }

    It 'does not flag update when local version equals remote' {
        InModuleScope 'Stagearr.Core' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            Mock Get-SALatestRelease {
                return @{ Version = '2.0.2'; TagName = 'v2.0.2'; Url = 'https://github.com/test' }
            }
            Mock Write-SAVerbose {}

            $config = @{
                updates = @{ mode = 'notify'; checkIntervalHours = 0 }
                paths   = @{ queueRoot = $tempDir }
            }

            try {
                Invoke-SAUpdateCheck -Config $config -LocalVersion '2.0.2' -ScriptRoot $tempDir

                $state = Get-SAUpdateState
                $state.UpdateAvailable | Should -BeFalse
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force
            }
        }
    }
}

Describe 'Get-SAEmailUpdateSection' {
    It 'returns empty string when no update activity' {
        InModuleScope 'Stagearr.Core' {
            Reset-SAUpdateState
            Get-SAEmailUpdateSection | Should -BeNullOrEmpty
        }
    }

    It 'returns amber card for notify mode' {
        InModuleScope 'Stagearr.Core' {
            $script:SAUpdateState = @{
                CheckPerformed  = $true
                UpdateAvailable = $true
                UpdateApplied   = $false
                OldVersion      = '2.0.2'
                NewVersion      = '2.1.0'
                ReleaseUrl      = 'https://github.com/test/releases/tag/v2.1.0'
                ErrorMessage    = ''
            }

            $html = Get-SAEmailUpdateSection
            $html | Should -Not -BeNullOrEmpty
            $html | Should -Match '#f59e0b'
            $html | Should -Match 'Update Available'
            $html | Should -Match '2\.1\.0'
            $html | Should -Match 'View release notes'

            Reset-SAUpdateState
        }
    }

    It 'returns empty string when check performed but up to date' {
        InModuleScope 'Stagearr.Core' {
            $script:SAUpdateState = @{
                CheckPerformed  = $true
                UpdateAvailable = $false
                UpdateApplied   = $false
                OldVersion      = '2.0.3'
                NewVersion      = ''
                ReleaseUrl      = ''
                ErrorMessage    = ''
            }

            $html = Get-SAEmailUpdateSection
            $html | Should -BeNullOrEmpty

            Reset-SAUpdateState
        }
    }

    It 'returns green card for successful auto-update' {
        InModuleScope 'Stagearr.Core' {
            $script:SAUpdateState = @{
                CheckPerformed  = $true
                UpdateAvailable = $true
                UpdateApplied   = $true
                OldVersion      = '2.0.2'
                NewVersion      = '2.1.0'
                ReleaseUrl      = 'https://github.com/test/releases/tag/v2.1.0'
                ErrorMessage    = ''
            }

            $html = Get-SAEmailUpdateSection
            $html | Should -Not -BeNullOrEmpty
            $html | Should -Match '#22c55e'
            $html | Should -Match 'Updated'
            $html | Should -Match '2\.0\.2'
            $html | Should -Match '2\.1\.0'

            Reset-SAUpdateState
        }
    }
}

Describe 'Get-SAFileLogHeader update status' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            Initialize-SAFileLogRenderer -LogFolder ([System.IO.Path]::GetTempPath()) -JobName 'test'
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            Reset-SAUpdateState
            Reset-SAFileLogRenderer
        }
    }

    It 'includes version line in header' {
        InModuleScope 'Stagearr.Core' {
            $header = Get-SAFileLogHeader -JobMetadata @{ StartTime = Get-Date; Name = 'test'; Label = 'TV' }
            $header -join "`n" | Should -Match 'Version:'
        }
    }

    It 'shows Up to date when check performed with no update' {
        InModuleScope 'Stagearr.Core' {
            $script:SAUpdateState = @{
                CheckPerformed  = $true
                UpdateAvailable = $false
                UpdateApplied   = $false
                OldVersion      = '2.0.5'
                NewVersion      = ''
                ReleaseUrl      = ''
                ErrorMessage    = ''
            }

            $header = Get-SAFileLogHeader -JobMetadata @{ StartTime = Get-Date; Name = 'test'; Label = 'TV' }
            $header -join "`n" | Should -Match 'Update:.*Up to date'
        }
    }

    It 'shows updated version when auto-update applied' {
        InModuleScope 'Stagearr.Core' {
            $script:SAUpdateState = @{
                CheckPerformed  = $true
                UpdateAvailable = $true
                UpdateApplied   = $true
                OldVersion      = '2.0.3'
                NewVersion      = '2.0.5'
                ReleaseUrl      = ''
                ErrorMessage    = ''
            }

            $header = Get-SAFileLogHeader -JobMetadata @{ StartTime = Get-Date; Name = 'test'; Label = 'TV' }
            $joined = $header -join "`n"
            $joined | Should -Match 'Update:.*Updated from v2\.0\.3 to v2\.0\.5'
        }
    }

    It 'shows available version in notify mode' {
        InModuleScope 'Stagearr.Core' {
            $script:SAUpdateState = @{
                CheckPerformed  = $true
                UpdateAvailable = $true
                UpdateApplied   = $false
                OldVersion      = '2.0.3'
                NewVersion      = '2.1.0'
                ReleaseUrl      = ''
                ErrorMessage    = ''
            }

            $header = Get-SAFileLogHeader -JobMetadata @{ StartTime = Get-Date; Name = 'test'; Label = 'TV' }
            $header -join "`n" | Should -Match 'Update:.*v2\.1\.0 available'
        }
    }

    It 'omits update line when no check performed' {
        InModuleScope 'Stagearr.Core' {
            Reset-SAUpdateState

            $header = Get-SAFileLogHeader -JobMetadata @{ StartTime = Get-Date; Name = 'test'; Label = 'TV' }
            $header -join "`n" | Should -Not -Match 'Update:'
        }
    }
}
