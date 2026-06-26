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
