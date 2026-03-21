BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Dangerous file detection integration' {
    It 'Test-SADangerousDownload returns danger for exe-only folder, safe for media folder' {
        InModuleScope 'Stagearr.Core' {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "SA-integ-$(New-Guid)"

            try {
                # Dangerous folder (exe only)
                $dangerDir = Join-Path $tempRoot 'danger'
                New-Item -ItemType Directory -Path $dangerDir -Force | Out-Null
                Set-Content -Path (Join-Path $dangerDir 'Show.S01E01.1080p.WEB-DL.exe') -Value 'malware'

                $result = Test-SADangerousDownload -SourcePath $dangerDir
                $result.IsDangerous | Should -BeTrue

                # Safe folder (mkv)
                $safeDir = Join-Path $tempRoot 'safe'
                New-Item -ItemType Directory -Path $safeDir -Force | Out-Null
                Set-Content -Path (Join-Path $safeDir 'Show.S01E01.1080p.WEB-DL.mkv') -Value 'media'

                $result2 = Test-SADangerousDownload -SourcePath $safeDir
                $result2.IsDangerous | Should -BeFalse
            }
            finally {
                if (Test-Path $tempRoot) {
                    Remove-Item $tempRoot -Recurse -Force
                }
            }
        }
    }

    It 'DangerousExtensions constant contains expected extensions' {
        InModuleScope 'Stagearr.Core' {
            $exts = $script:SAConstants.DangerousExtensions
            $exts | Should -Contain '.exe'
            $exts | Should -Contain '.msi'
            $exts | Should -Contain '.bat'
            $exts | Should -Contain '.scr'
            $exts | Should -Contain '.lnk'
            $exts | Should -Not -Contain '.mkv'
            $exts | Should -Not -Contain '.mp4'
        }
    }
}
