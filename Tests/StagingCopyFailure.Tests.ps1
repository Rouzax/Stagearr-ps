BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Write-SAToolError pipeline output' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            Mock Write-SAOutcome {}
            Mock Write-SAProgress {}
            Mock Write-SAVerbose {}
        }
    }

    It 'emits nothing, so callers that return a bool after it stay a bool' {
        $output = InModuleScope 'Stagearr.Core' {
            Write-SAToolError -Label 'Copy' -ToolName 'robocopy' -ExitCode 8 -FilePath 'x.mkv'
        }

        @($output).Count | Should -Be 0
    }
}

Describe 'Get-SARobocopyErrorText' {
    It 'returns the last error code with its message line' {
        InModuleScope 'Stagearr.Core' {
            $stdout = @(
                "`t    New File  `t`t   7.5 g`tShow.S01E01.mkv"
                '2026/10/26 12:03:01 ERROR 112 (0x00000070) Copying File C:\Downloads\Show\Show.S01E01.mkv'
                'There is not enough space on the disk.'
                ''
                'Waiting 5 seconds... Retrying...'
                "`t    New File  `t`t   7.5 g`tShow.S01E01.mkv"
                '2026/10/26 12:03:06 ERROR 112 (0x00000070) Copying File C:\Downloads\Show\Show.S01E01.mkv'
                'There is not enough space on the disk.'
                ''
                'ERROR: RETRY LIMIT EXCEEDED.'
            ) -join "`r`n"

            Get-SARobocopyErrorText -StdOut $stdout |
                Should -Be 'ERROR 112 (0x00000070): There is not enough space on the disk.'
        }
    }

    It 'returns an empty string when stdout holds no error' {
        InModuleScope 'Stagearr.Core' {
            Get-SARobocopyErrorText -StdOut "`t    New File  `t`t   7.5 g`tShow.S01E01.mkv" | Should -Be ''
            Get-SARobocopyErrorText -StdOut '' | Should -Be ''
        }
    }
}

Describe 'Get-SAToolErrorInfo for robocopy' {
    It 'prefers a matching error text over the catch-all exit code 8 mapping' {
        InModuleScope 'Stagearr.Core' {
            $info = Get-SAToolErrorInfo -ToolName 'robocopy' -ExitCode 8 `
                -ErrorMessage 'ERROR 112 (0x00000070): There is not enough space on the disk.'

            $info.Problem | Should -Be 'Disk is full'
        }
    }

    It 'falls back to the exit code mapping when no error text matches' {
        InModuleScope 'Stagearr.Core' {
            $info = Get-SAToolErrorInfo -ToolName 'robocopy' -ExitCode 8 -ErrorMessage ''

            $info.Problem | Should -Be 'Some files could not be copied'
        }
    }

    It 'keeps a specific exit code mapping ahead of error text for other tools' {
        InModuleScope 'Stagearr.Core' {
            $info = Get-SAToolErrorInfo -ToolName 'rar' -ExitCode 11 `
                -ErrorMessage 'Checksum error in the encrypted file. Corrupt file or wrong password.'

            $info.Problem | Should -Not -Be 'File appears corrupted'
        }
    }
}

Describe 'Copy-SASingleFile robocopy failure' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            Mock Write-SAOutcome {}
            Mock Write-SAProgress {}
            Mock Write-SAVerbose {}
            Mock Get-Item { [PSCustomObject]@{ Length = 7GB } }
            Mock Invoke-SAProcessWithRetry {
                [PSCustomObject]@{
                    ExitCode = 8
                    Success  = $false
                    StdErr   = ''
                    StdOut   = "2026/10/26 12:03:01 ERROR 112 (0x00000070) Copying File C:\src\a.mkv`r`nThere is not enough space on the disk.`r`n"
                }
            }
        }
    }

    It 'returns exactly $false' {
        $output = InModuleScope 'Stagearr.Core' {
            Copy-SASingleFile -SourcePath '/src/a.mkv' -DestinationFolder '/staging'
        }

        @($output).Count | Should -Be 1
        $output | Should -BeOfType [bool]
        $output | Should -BeFalse
    }

    It 'reports the robocopy error text from stdout' {
        InModuleScope 'Stagearr.Core' {
            $null = Copy-SASingleFile -SourcePath '/src/a.mkv' -DestinationFolder '/staging'

            Should -Invoke Write-SAOutcome -ParameterFilter { $Level -eq 'Error' -and $Text -eq 'Disk is full' }
        }
    }
}

Describe 'Invoke-SAVideoProcessing staging space preflight' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            Mock Write-SAOutcome {}
            Mock Write-SAProgress {}
            Mock Write-SAVerbose {}
            Mock Write-SAPhaseHeader {}
            Mock Initialize-SAStagingFolder { '/staging/job' }
            Mock Get-SASourceMediaFiles {
                @([PSCustomObject]@{
                    Type          = 'MKV'
                    SourcePath    = '/src/a.mkv'
                    FileName      = 'a.mkv'
                    Size          = 7GB
                    NeedsUnrar    = $false
                    NeedsRemux    = $false
                    NeedsAnalysis = $true
                })
            }
            Mock Invoke-SAProcessMediaFile {
                [PSCustomObject]@{ Success = $true; OutputPath = '/staging/job/a.mkv'; Type = 'Copy' }
            }
        }
    }

    It 'fails before copying when the staging drive lacks room' {
        $result = InModuleScope 'Stagearr.Core' {
            Mock Get-SAAvailableFreeSpace { 1GB }
            $ctx = @{ State = @{ StagingPath = '/staging/job'; IsRarArchive = $false }; Results = @{} }

            $r = Invoke-SAVideoProcessing -Context $ctx
            Should -Invoke Invoke-SAProcessMediaFile -Times 0
            $r
        }

        @($result).Count | Should -Be 1
        $result.Success | Should -BeFalse
        $result.Reason | Should -Be 'InsufficientSpace'
        $result.Error | Should -Match 'disk space'
    }

    It 'proceeds when free space cannot be determined' {
        $result = InModuleScope 'Stagearr.Core' {
            Mock Get-SAAvailableFreeSpace { $null }
            $ctx = @{ State = @{ StagingPath = '/staging/job'; IsRarArchive = $false }; Results = @{} }

            $r = Invoke-SAVideoProcessing -Context $ctx
            Should -Invoke Invoke-SAProcessMediaFile -Times 1
            $r
        }

        @($result).Count | Should -Be 1
        $result.Success | Should -BeTrue
    }

    It 'proceeds when the staging drive has room' {
        $result = InModuleScope 'Stagearr.Core' {
            Mock Get-SAAvailableFreeSpace { 100GB }
            $ctx = @{ State = @{ StagingPath = '/staging/job'; IsRarArchive = $false }; Results = @{} }

            Invoke-SAVideoProcessing -Context $ctx
        }

        $result.Success | Should -BeTrue
    }
}

Describe 'Get-SAStagingRequiredBytes' {
    BeforeAll {
        $script:rarDir = Join-Path $TestDrive 'Release'
        New-Item -ItemType Directory -Path $script:rarDir | Out-Null
        foreach ($name in 'release.rar', 'release.r00', 'release.r01') {
            [System.IO.File]::WriteAllBytes((Join-Path $script:rarDir $name), [byte[]]::new(1000))
        }
        [System.IO.File]::WriteAllBytes((Join-Path $script:rarDir 'release.nfo'), [byte[]]::new(50))
    }

    It 'sums the media file sizes for non-RAR sources' {
        InModuleScope 'Stagearr.Core' {
            $ctx = @{ State = @{ IsRarArchive = $false } }
            $files = @([PSCustomObject]@{ Size = 100 }, [PSCustomObject]@{ Size = 250 })

            Get-SAStagingRequiredBytes -Context $ctx -MediaFiles $files | Should -Be 350
        }
    }

    It 'sums every volume of a multi-part RAR set, not just the first' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Dir = $script:rarDir } {
            $ctx = @{ State = @{ IsRarArchive = $true; IsSingleFile = $false; SourcePath = $Dir } }
            $files = @([PSCustomObject]@{ Size = 1000; NeedsUnrar = $true })

            Get-SAStagingRequiredBytes -Context $ctx -MediaFiles $files | Should -Be 3000
        }
    }
}

Describe 'Invoke-SAProcessMkv copy failure' {
    It 'sets an error message so the failure email names the cause' {
        $result = InModuleScope 'Stagearr.Core' {
            Mock Write-SAOutcome {}
            Mock Write-SAProgress {}
            Mock Write-SAVerbose {}
            Mock Write-SAPhaseHeader {}
            Mock Get-Item { [PSCustomObject]@{ Length = 7GB } }
            Mock Test-SAFeatureEnabled { $false }
            Mock Get-SAMkvInfo {
                [PSCustomObject]@{ OpenSubsHash = 'abc'; VideoTracks = @(1); AudioTracks = @(1); SubtitleCount = 0 }
            }
            Mock Copy-SASingleFile { $false }
            $ctx = @{
                Config  = @{}
                State   = @{ VideoFileIndex = 1; VideoFileCount = 1; OpenSubsDisabledMsgShown = $true; SubtitlesBothDisabledMsgShown = $true }
                Results = @{}
                Tools   = @{ MkvMerge = 'mkvmerge' }
            }
            Invoke-SAProcessMkv -Context $ctx -SourcePath '/src/a.mkv' -StagingPath '/staging/job'
        }

        $result.Success | Should -BeFalse
        $result.Error | Should -Not -BeNullOrEmpty
        $result.FailedFile | Should -Be 'a.mkv'
    }
}
