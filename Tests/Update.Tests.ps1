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

Describe 'Get-SALatestRelease' {
    It 'returns ZipUrl and ChecksumUrl when release has matching assets' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAWebRequest {
                return [PSCustomObject]@{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        tag_name  = 'v2.2.0'
                        html_url  = 'https://github.com/Rouzax/Stagearr-ps/releases/tag/v2.2.0'
                        assets    = @(
                            [PSCustomObject]@{
                                name                 = 'Stagearr-v2.2.0.zip'
                                browser_download_url = 'https://github.com/Rouzax/Stagearr-ps/releases/download/v2.2.0/Stagearr-v2.2.0.zip'
                            },
                            [PSCustomObject]@{
                                name                 = 'checksums.txt'
                                browser_download_url = 'https://github.com/Rouzax/Stagearr-ps/releases/download/v2.2.0/checksums.txt'
                            }
                        )
                    }
                }
            }

            $result = Get-SALatestRelease
            $result | Should -Not -BeNullOrEmpty
            $result.Version | Should -Be '2.2.0'
            $result.ZipUrl | Should -Be 'https://github.com/Rouzax/Stagearr-ps/releases/download/v2.2.0/Stagearr-v2.2.0.zip'
            $result.ChecksumUrl | Should -Be 'https://github.com/Rouzax/Stagearr-ps/releases/download/v2.2.0/checksums.txt'
        }
    }

    It 'returns null ZipUrl when no matching asset exists' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAWebRequest {
                return [PSCustomObject]@{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        tag_name  = 'v2.2.0'
                        html_url  = 'https://github.com/Rouzax/Stagearr-ps/releases/tag/v2.2.0'
                        assets    = @()
                    }
                }
            }

            $result = Get-SALatestRelease
            $result | Should -Not -BeNullOrEmpty
            $result.Version | Should -Be '2.2.0'
            $result.ZipUrl | Should -BeNullOrEmpty
            $result.ChecksumUrl | Should -BeNullOrEmpty
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

Describe 'Invoke-SAZipUpdate' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            $script:testScriptRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-root-$(New-Guid)"
            New-Item -Path $script:testScriptRoot -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $script:testScriptRoot 'Stagearr.ps1') -Value 'old-content'
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            if (Test-Path $script:testScriptRoot) {
                Remove-Item -Path $script:testScriptRoot -Recurse -Force
            }
        }
    }

    It 'returns false when ZipUrl is null' {
        InModuleScope 'Stagearr.Core' {
            $release = @{
                Version     = '2.2.0'
                TagName     = 'v2.2.0'
                Url         = 'https://github.com/test'
                ZipUrl      = $null
                ChecksumUrl = $null
            }

            Mock Write-SAVerbose {}

            $result = Invoke-SAZipUpdate -Release $release -ScriptRoot $script:testScriptRoot
            $result | Should -BeFalse
        }
    }

    It 'returns false when ChecksumUrl is null' {
        InModuleScope 'Stagearr.Core' {
            $release = @{
                Version     = '2.2.0'
                TagName     = 'v2.2.0'
                Url         = 'https://github.com/test'
                ZipUrl      = 'https://github.com/test/Stagearr-v2.2.0.zip'
                ChecksumUrl = $null
            }

            Mock Write-SAVerbose {}

            $result = Invoke-SAZipUpdate -Release $release -ScriptRoot $script:testScriptRoot
            $result | Should -BeFalse
        }
    }

    It 'returns false when checksum verification fails' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SADownloadFile {
                param($Uri, $OutFile)
                if ($Uri -like '*.zip') {
                    Set-Content -Path $OutFile -Value 'fake-zip-content'
                } elseif ($Uri -like '*checksums*') {
                    Set-Content -Path $OutFile -Value 'deadbeef00000000000000000000000000000000000000000000000000000000  Stagearr-v2.2.0.zip'
                }
                return $true
            }

            Mock Write-SAVerbose {}
            Mock Write-SAProgress {}

            $release = @{
                Version     = '2.2.0'
                TagName     = 'v2.2.0'
                Url         = 'https://github.com/test'
                ZipUrl      = 'https://github.com/test/Stagearr-v2.2.0.zip'
                ChecksumUrl = 'https://github.com/test/checksums.txt'
            }

            $result = Invoke-SAZipUpdate -Release $release -ScriptRoot $script:testScriptRoot
            $result | Should -BeFalse
        }
    }

    It 'extracts and overwrites files on valid update' {
        InModuleScope 'Stagearr.Core' {
            # Build a real ZIP with files inside
            $tempBuildDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-build-$(New-Guid)"
            New-Item -Path $tempBuildDir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $tempBuildDir 'Stagearr.ps1') -Value 'new-content'
            Set-Content -Path (Join-Path $tempBuildDir 'config-sample.toml') -Value 'sample'
            New-Item -Path (Join-Path $tempBuildDir 'Modules') -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $tempBuildDir 'Modules/test.psm1') -Value 'module'

            $script:testZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-zip-$(New-Guid).zip"
            Compress-Archive -Path "$tempBuildDir/*" -DestinationPath $script:testZipPath -Force

            # Compute real checksum
            $hash = (Get-FileHash -Path $script:testZipPath -Algorithm SHA256).Hash.ToLower()
            $script:testChecksumContent = "$hash  Stagearr-v2.2.0.zip"

            Mock Invoke-SADownloadFile {
                param($Uri, $OutFile)
                if ($Uri -like '*.zip') {
                    Copy-Item -Path $script:testZipPath -Destination $OutFile
                } elseif ($Uri -like '*checksums*') {
                    Set-Content -Path $OutFile -Value $script:testChecksumContent
                }
                return $true
            }

            Mock Write-SAVerbose {}
            Mock Write-SAProgress {}

            $release = @{
                Version     = '2.2.0'
                TagName     = 'v2.2.0'
                Url         = 'https://github.com/test'
                ZipUrl      = 'https://github.com/test/Stagearr-v2.2.0.zip'
                ChecksumUrl = 'https://github.com/test/checksums.txt'
            }

            $result = Invoke-SAZipUpdate -Release $release -ScriptRoot $script:testScriptRoot
            $result | Should -BeTrue

            # Verify files were overwritten
            $newContent = Get-Content -Path (Join-Path $script:testScriptRoot 'Stagearr.ps1') -Raw
            $newContent.Trim() | Should -Be 'new-content'

            # Verify Modules directory was copied
            Test-Path (Join-Path $script:testScriptRoot 'Modules/test.psm1') | Should -BeTrue

            # Cleanup
            Remove-Item -Path $tempBuildDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $script:testZipPath -Force -ErrorAction SilentlyContinue
        }
    }
}
