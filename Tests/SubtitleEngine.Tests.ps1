BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Resolve-SASubtitleTool' {
    BeforeAll {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("setool_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterAll { Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'empty/whitespace path -> null engine' {
        InModuleScope 'Stagearr.Core' {
            (Resolve-SASubtitleTool -Path '').Engine | Should -BeNullOrEmpty
            (Resolve-SASubtitleTool -Path '   ').Engine | Should -BeNullOrEmpty
        }
    }

    It 'direct GUI binary path -> SubtitleEditGui' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Tmp = $script:tmp } {
            param($Tmp)
            $exe = Join-Path $Tmp 'SubtitleEdit.exe'; Set-Content -LiteralPath $exe -Value 'x'
            $r = Resolve-SASubtitleTool -Path $exe
            $r.Engine | Should -Be 'SubtitleEditGui'
            $r.Path   | Should -Be $exe
        }
    }

    It 'direct seconv binary path -> Seconv' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Tmp = $script:tmp } {
            param($Tmp)
            $exe = Join-Path $Tmp 'seconv'; Set-Content -LiteralPath $exe -Value 'x'
            (Resolve-SASubtitleTool -Path $exe).Engine | Should -Be 'Seconv'
        }
    }

    It 'directory containing only GUI -> resolves GUI binary' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Tmp = $script:tmp } {
            param($Tmp)
            $d = Join-Path $Tmp 'guidir'; New-Item -ItemType Directory -Path $d | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'SubtitleEdit.exe') -Value 'x'
            $r = Resolve-SASubtitleTool -Path $d
            $r.Engine | Should -Be 'SubtitleEditGui'
            $r.Path   | Should -Be (Join-Path $d 'SubtitleEdit.exe')
        }
    }

    It 'directory containing both -> prefers seconv' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Tmp = $script:tmp } {
            param($Tmp)
            $d = Join-Path $Tmp 'bothdir'; New-Item -ItemType Directory -Path $d | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'SubtitleEdit.exe') -Value 'x'
            Set-Content -LiteralPath (Join-Path $d 'seconv') -Value 'x'
            (Resolve-SASubtitleTool -Path $d).Engine | Should -Be 'Seconv'
        }
    }

    It 'directory with nothing recognized -> null engine, empty path' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Tmp = $script:tmp } {
            param($Tmp)
            $d = Join-Path $Tmp 'emptydir'; New-Item -ItemType Directory -Path $d | Out-Null
            $r = Resolve-SASubtitleTool -Path $d
            $r.Engine | Should -BeNullOrEmpty
            $r.Path   | Should -Be ''
        }
    }
}

Describe 'Get-SACleanupOperations' {
    It 'returns production-ordered keys with toggle values, defaulting missing keys to true (except split)' {
        InModuleScope 'Stagearr.Core' {
            $ops = Get-SACleanupOperations -CleanupConfig @{ enabled = $true }
            @($ops.Keys) | Should -Be @('MergeSameTexts','RemoveTextForHI','FixCommonErrors','SplitLongLines')
            $ops.MergeSameTexts  | Should -BeTrue
            $ops.RemoveTextForHI | Should -BeTrue
            $ops.FixCommonErrors | Should -BeTrue
            $ops.SplitLongLines  | Should -BeFalse
        }
    }
    It 'honors explicit toggles' {
        InModuleScope 'Stagearr.Core' {
            $ops = Get-SACleanupOperations -CleanupConfig @{ removeHearingImpaired = $false; splitLongLines = $true }
            $ops.RemoveTextForHI | Should -BeFalse
            $ops.SplitLongLines  | Should -BeTrue
        }
    }
}

Describe 'Get-SAGuiCleanupArgs' {
    It 'default ops produce the convert pipeline in order' {
        InModuleScope 'Stagearr.Core' {
            $ops = Get-SACleanupOperations -CleanupConfig @{}
            $a = Get-SAGuiCleanupArgs -FolderPath 'C:\stage' -Operations $ops
            $a | Should -Be @('/convert','*.srt','subrip','/inputfolder:C:\stage','/overwrite','/MergeSameTexts','/RemoveTextForHI','/FixCommonErrors','/outputfolder:C:\stage')
        }
    }
    It 'disabling an op drops its flag' {
        InModuleScope 'Stagearr.Core' {
            $ops = Get-SACleanupOperations -CleanupConfig @{ removeHearingImpaired = $false }
            (Get-SAGuiCleanupArgs -FolderPath '/stage' -Operations $ops) | Should -Not -Contain '/RemoveTextForHI'
        }
    }
}

Describe 'Get-SASeconvCleanupArgs' {
    It 'builds full SE4-parity invocation in order, single FCE, rules + settings' {
        InModuleScope 'Stagearr.Core' {
            $ops = Get-SACleanupOperations -CleanupConfig @{}
            $a = Get-SASeconvCleanupArgs -FolderPath '/stage' -Operations $ops `
                    -FixCommonErrorsRules 'all,-FixShortGaps,-FixShortLinesPixelWidth' -SettingsPath '/cfg/se.json'
            $a | Should -Be @('*.srt','subrip','--input-folder:/stage','--output-folder:/stage','--overwrite','--merge-same-texts','--remove-text-for-hi','--fix-common-errors-rules:all,-FixShortGaps,-FixShortLinesPixelWidth','--settings:/cfg/se.json')
            ($a | Where-Object { $_ -eq '--fix-common-errors' }).Count | Should -Be 0  # rules flag implies FCE; no bare flag
        }
    }
    It 'uses bare --fix-common-errors when no rules string is given' {
        InModuleScope 'Stagearr.Core' {
            $ops = Get-SACleanupOperations -CleanupConfig @{}
            $a = Get-SASeconvCleanupArgs -FolderPath '/stage' -Operations $ops -FixCommonErrorsRules '' -SettingsPath ''
            $a | Should -Contain '--fix-common-errors'
            $a | Should -Not -Contain '--settings:'
        }
    }
    It 'adds --split-long-lines only when enabled' {
        InModuleScope 'Stagearr.Core' {
            $ops = Get-SACleanupOperations -CleanupConfig @{ splitLongLines = $true }
            (Get-SASeconvCleanupArgs -FolderPath '/s' -Operations $ops -FixCommonErrorsRules '' -SettingsPath '') | Should -Contain '--split-long-lines'
        }
    }
    It 'omits FCE entirely when fixCommonErrors is off' {
        InModuleScope 'Stagearr.Core' {
            $ops = Get-SACleanupOperations -CleanupConfig @{ fixCommonErrors = $false }
            $a = Get-SASeconvCleanupArgs -FolderPath '/s' -Operations $ops -FixCommonErrorsRules 'all,-FixShortGaps' -SettingsPath ''
            $a | Should -Not -Contain '--fix-common-errors'
            ($a | Where-Object { $_ -like '--fix-common-errors-rules:*' }).Count | Should -Be 0
        }
    }
}

Describe 'seconv settings JSON + resolver' {
    It 'bundled JSON parses and has the SE4-profile keys' {
        InModuleScope 'Stagearr.Core' {
            $p = Join-Path $script:SAModuleRoot 'Data/seconv-settings.json'
            Test-Path -LiteralPath $p | Should -BeTrue
            $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            $j.general.minimumMillisecondsBetweenLines | Should -Be 24
            $j.general.maxNumberOfLines | Should -Be 2
            $j.removeTextForHearingImpaired.removeIfOnlyMusicSymbols | Should -BeTrue
        }
    }
    It 'resolver returns bundled path when override empty' {
        InModuleScope 'Stagearr.Core' {
            $r = Resolve-SASeconvSettingsPath -OverridePath ''
            $r | Should -Be (Join-Path $script:SAModuleRoot 'Data/seconv-settings.json')
        }
    }
    It 'resolver returns override when it exists' {
        InModuleScope 'Stagearr.Core' {
            $tmp = New-TemporaryFile
            try { (Resolve-SASeconvSettingsPath -OverridePath $tmp.FullName) | Should -Be $tmp.FullName }
            finally { Remove-Item -LiteralPath $tmp.FullName -Force }
        }
    }
    It 'resolver falls back to bundled when override path is missing' {
        InModuleScope 'Stagearr.Core' {
            $r = Resolve-SASeconvSettingsPath -OverridePath '/nope/missing.json'
            $r | Should -Be (Join-Path $script:SAModuleRoot 'Data/seconv-settings.json')
        }
    }
}
