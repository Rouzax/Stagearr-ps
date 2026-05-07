BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Test-SAProcessResult pipeline output' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            Mock Write-SAOutcome {}
            Mock Write-SAProgress {}
            Mock Write-SAVerbose {}
        }
    }

    It 'returns exactly $false when tool fails (exit code 2)' {
        $output = InModuleScope 'Stagearr.Core' {
            $fakeResult = [PSCustomObject]@{
                Success  = $false
                ExitCode = 2
                StdErr   = 'some error'
                StdOut   = ''
            }
            Test-SAProcessResult -Result $fakeResult -ToolName 'mkvmerge' -Label 'Remux' -FilePath 'test.mkv'
        }

        $output | Should -BeOfType [bool]
        $output | Should -BeFalse
        @($output).Count | Should -Be 1
    }

    It 'returns exactly $true when tool succeeds (exit code 0)' {
        $output = InModuleScope 'Stagearr.Core' {
            $fakeResult = [PSCustomObject]@{
                Success  = $true
                ExitCode = 0
                StdErr   = ''
                StdOut   = 'ok'
            }
            Test-SAProcessResult -Result $fakeResult -ToolName 'mkvmerge' -Label 'Remux' -FilePath 'test.mkv'
        }

        $output | Should -BeOfType [bool]
        $output | Should -BeTrue
        @($output).Count | Should -Be 1
    }

    It 'returns exactly $true when tool returns warning code treated as success' {
        $output = InModuleScope 'Stagearr.Core' {
            $fakeResult = [PSCustomObject]@{
                Success  = $false
                ExitCode = 1
                StdErr   = 'warning: something'
                StdOut   = ''
            }
            Test-SAProcessResult -Result $fakeResult -ToolName 'mkvmerge' -Label 'Remux' -FilePath 'test.mkv' -SuccessCodes @(1)
        }

        $output | Should -BeOfType [bool]
        $output | Should -BeTrue
        @($output).Count | Should -Be 1
    }
}
