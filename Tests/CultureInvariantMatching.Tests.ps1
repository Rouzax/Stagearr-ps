BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

# Regression coverage for the "Turkish-I" class of culture bugs: case-insensitive
# matching done with .ToLower()/.ToUpper() breaks under tr-TR/az locales, where
# "I".ToLower() is the dotless "ı" and "i".ToUpper() is the dotted "İ". Anything
# that lowercases an identifier (extension, language code, ...) containing an I/i
# and then compares it against an ASCII literal must use the invariant variant.
Describe 'Case-insensitive matching is culture-invariant (tr-TR)' {
    BeforeEach {
        $script:originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('tr-TR')
    }

    AfterEach {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:originalCulture
        InModuleScope 'Stagearr.Core' {
            if ($script:testDir -and (Test-Path $script:testDir)) {
                Remove-Item -Path $script:testDir -Recurse -Force
            }
        }
    }

    It 'flags an uppercase dangerous extension that contains an I (.MSI)' {
        InModuleScope 'Stagearr.Core' {
            $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $script:testDir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $script:testDir 'installer.MSI') -Value 'bad'

            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -BeTrue
        }
    }

    It 'resolves uppercase language codes that contain an I' {
        InModuleScope 'Stagearr.Core' {
            # id=Indonesian, is=Icelandic, fi=Finnish, hi=Hindi, vi=Vietnamese
            foreach ($code in 'ID', 'IS', 'FI', 'HI', 'VI') {
                Test-SALanguageCode -Code $code | Should -BeTrue -Because "$code should be recognized under tr-TR"
                Get-SALanguageInfo -Code $code | Should -Not -BeNullOrEmpty
            }
        }
    }
}
