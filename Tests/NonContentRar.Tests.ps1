BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Test-SANonContentRar' {
    It 'detects proof RAR: <Name>' -ForEach @(
        @{ Name = 'tm-theruleofjenny-2160p-hevc-proof.rar'; Expected = $true }
        @{ Name = 'group-proof.rar'; Expected = $true }
        @{ Name = 'PROOF.rar'; Expected = $true }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Name = $Name; Expected = $Expected } {
            Test-SANonContentRar -Name $Name | Should -Be $Expected
        }
    }

    It 'detects sample RAR: <Name>' -ForEach @(
        @{ Name = 'movie-sample.rar'; Expected = $true }
        @{ Name = 'Sample.rar'; Expected = $true }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Name = $Name; Expected = $Expected } {
            Test-SANonContentRar -Name $Name | Should -Be $Expected
        }
    }

    It 'detects nfo RAR: <Name>' -ForEach @(
        @{ Name = 'group-nfo.rar'; Expected = $true }
        @{ Name = 'release.nfo.rar'; Expected = $true }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Name = $Name; Expected = $Expected } {
            Test-SANonContentRar -Name $Name | Should -Be $Expected
        }
    }

    It 'allows content RAR: <Name>' -ForEach @(
        @{ Name = 'tm-theruleofjenny-2160p-hevc.rar'; Expected = $false }
        @{ Name = 'movie.part01.rar'; Expected = $false }
        @{ Name = 'release-group.rar'; Expected = $false }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Name = $Name; Expected = $Expected } {
            Test-SANonContentRar -Name $Name | Should -Be $Expected
        }
    }
}

Describe 'Context IsRarArchive detection' {
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

    It 'sets IsRarArchive false when folder has only proof RAR and a video file' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'movie.mkv') -Value 'video'
            Set-Content -Path (Join-Path $script:testDir 'group-proof.rar') -Value 'proof'

            $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-staging-$(New-Guid)"
            $config = @{
                logging = @{ consoleColors = $false }
                tools = @{ winrar = ''; mkvmerge = ''; mkvextract = ''; subtitleEdit = '' }
                paths = @{ stagingRoot = $stagingRoot; logArchive = (Join-Path $stagingRoot 'logs'); queueRoot = (Join-Path $stagingRoot 'queue') }
                processing = @{ cleanupStaging = $true }
            }
            $job = @{ input = @{ downloadPath = $script:testDir; downloadLabel = 'Movie' } }
            $context = New-SAContext -Config $config
            Initialize-SAContext -Context $context -Job $job
            $context.State.IsRarArchive | Should -BeFalse
        }
    }

    It 'sets IsRarArchive true when folder has content RAR and proof RAR' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'movie.rar') -Value 'content'
            Set-Content -Path (Join-Path $script:testDir 'group-proof.rar') -Value 'proof'

            $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-staging-$(New-Guid)"
            $config = @{
                logging = @{ consoleColors = $false }
                tools = @{ winrar = ''; mkvmerge = ''; mkvextract = ''; subtitleEdit = '' }
                paths = @{ stagingRoot = $stagingRoot; logArchive = (Join-Path $stagingRoot 'logs'); queueRoot = (Join-Path $stagingRoot 'queue') }
                processing = @{ cleanupStaging = $true }
            }
            $job = @{ input = @{ downloadPath = $script:testDir; downloadLabel = 'Movie' } }
            $context = New-SAContext -Config $config
            Initialize-SAContext -Context $context -Job $job
            $context.State.IsRarArchive | Should -BeTrue
        }
    }

    It 'sets IsRarArchive true when folder has only content RAR' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'movie.rar') -Value 'content'

            $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-staging-$(New-Guid)"
            $config = @{
                logging = @{ consoleColors = $false }
                tools = @{ winrar = ''; mkvmerge = ''; mkvextract = ''; subtitleEdit = '' }
                paths = @{ stagingRoot = $stagingRoot; logArchive = (Join-Path $stagingRoot 'logs'); queueRoot = (Join-Path $stagingRoot 'queue') }
                processing = @{ cleanupStaging = $true }
            }
            $job = @{ input = @{ downloadPath = $script:testDir; downloadLabel = 'Movie' } }
            $context = New-SAContext -Config $config
            Initialize-SAContext -Context $context -Job $job
            $context.State.IsRarArchive | Should -BeTrue
        }
    }
}
