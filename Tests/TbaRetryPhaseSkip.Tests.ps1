BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Test-SATbaRetryMode' {

    It 'returns ImportOnly when staging path exists' {
        InModuleScope 'Stagearr.Core' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "sa-test-staging-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            try {
                $job = @{
                    input = @{
                        tbaRetry      = $true
                        stagingPath   = $testDir
                        downloadPath  = 'C:\Downloads\Test'
                    }
                }

                $result = Test-SATbaRetryMode -Job $job
                $result.Mode | Should -Be 'ImportOnly'
                $result.StagingPath | Should -Be $testDir
            } finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force
            }
        }
    }

    It 'returns FullPipeline when staging path is gone but download exists' {
        InModuleScope 'Stagearr.Core' {
            $downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) "sa-test-download-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null

            try {
                $job = @{
                    input = @{
                        tbaRetry      = $true
                        stagingPath   = 'C:\NonExistent\Staging'
                        downloadPath  = $downloadDir
                    }
                }

                $result = Test-SATbaRetryMode -Job $job
                $result.Mode | Should -Be 'FullPipeline'
            } finally {
                Remove-Item -LiteralPath $downloadDir -Recurse -Force
            }
        }
    }

    It 'returns Failed when both staging and download are gone' {
        InModuleScope 'Stagearr.Core' {
            $job = @{
                input = @{
                    tbaRetry      = $true
                    stagingPath   = 'C:\NonExistent\Staging'
                    downloadPath  = 'C:\NonExistent\Download'
                }
            }

            $result = Test-SATbaRetryMode -Job $job
            $result.Mode | Should -Be 'Failed'
        }
    }

    It 'returns null for non-retry jobs' {
        InModuleScope 'Stagearr.Core' {
            $job = @{
                input = @{
                    tbaRetry = $false
                }
            }

            $result = Test-SATbaRetryMode -Job $job
            $result | Should -BeNullOrEmpty
        }
    }
}
