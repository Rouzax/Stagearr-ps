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
