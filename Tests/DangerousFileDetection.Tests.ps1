BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Test-SADangerousDownload' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $script:testDir -ItemType Directory -Force | Out-Null
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            if (Test-Path $script:testDir) {
                Remove-Item -Path $script:testDir -Recurse -Force
            }
        }
    }

    It 'returns dangerous when folder contains only exe files' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'malware.exe') -Value 'bad'

            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -BeTrue
            $result.DangerousFiles.Count | Should -Be 1
        }
    }

    It 'returns not dangerous when folder contains only media files' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'movie.mkv') -Value 'video'

            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -BeFalse
        }
    }

    It 'returns not dangerous when folder has mixed media and exe files' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'movie.mkv') -Value 'video'
            Set-Content -Path (Join-Path $script:testDir 'setup.exe') -Value 'bad'

            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -BeFalse
        }
    }

    It 'returns dangerous when source is a single dangerous file' {
        InModuleScope 'Stagearr.Core' {
            $filePath = Join-Path $script:testDir 'trojan.exe'
            Set-Content -Path $filePath -Value 'bad'

            $result = Test-SADangerousDownload -SourcePath $filePath
            $result.IsDangerous | Should -BeTrue
        }
    }

    It 'returns dangerous when folder has multiple dangerous extensions' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'payload.exe') -Value 'bad'
            Set-Content -Path (Join-Path $script:testDir 'script.bat') -Value 'bad'
            Set-Content -Path (Join-Path $script:testDir 'screensaver.scr') -Value 'bad'

            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -BeTrue
            $result.DangerousFiles.Count | Should -Be 3
        }
    }

    It 'returns not dangerous for empty folder' {
        InModuleScope 'Stagearr.Core' {
            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -BeFalse
        }
    }

    It 'returns not dangerous when folder has only harmless non-media files' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'info.nfo') -Value 'nfo content'
            Set-Content -Path (Join-Path $script:testDir 'readme.txt') -Value 'text content'

            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -BeFalse
        }
    }

    It 'detects dangerous extensions case-insensitively' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'MALWARE.EXE') -Value 'bad'

            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -BeTrue
        }
    }
}
