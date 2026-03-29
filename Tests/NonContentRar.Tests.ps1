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
