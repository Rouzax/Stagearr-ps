BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SASimplifiedRejectionReason' {

    Context 'Existing mappings' {
        It 'maps "<Reason>" to "<Expected>"' -ForEach @(
            @{ Reason = 'Not an upgrade for existing episode file(s)'; Expected = 'Quality exists' }
            @{ Reason = 'Sample'; Expected = 'Sample file' }
            @{ Reason = 'Unknown Series'; Expected = 'Cannot parse' }
            @{ Reason = 'Episode file already imported at 2026-03-30'; Expected = 'Already imported' }
            @{ Reason = 'Locked file, try again later'; Expected = 'File locked' }
        ) {
            InModuleScope 'Stagearr.Core' -Parameters @{ Reason = $Reason; Expected = $Expected } {
                Get-SASimplifiedRejectionReason -Reason $Reason | Should -Be $Expected
            }
        }
    }

    Context 'New mappings' {
        It 'maps "<Reason>" to "<Expected>"' -ForEach @(
            @{ Reason = 'Episode has a TBA title and recently aired'; Expected = 'Episode title TBA' }
            @{ Reason = 'Episode does not have a title and recently aired'; Expected = 'Episode title TBA' }
            @{ Reason = 'Not enough free space'; Expected = 'Not enough disk space' }
            @{ Reason = 'This show has individual episode mappings on TheXEM but the mapping for this episode has not been confirmed yet'; Expected = 'Unverified scene mapping' }
            @{ Reason = 'No audio tracks detected'; Expected = 'No audio tracks' }
            @{ Reason = 'Single episode file contains all episodes in seasons'; Expected = 'Full season file' }
            @{ Reason = 'Partial season packs are not supported'; Expected = 'Partial season pack' }
            @{ Reason = 'Episode does not have an absolute episode number and recently aired'; Expected = 'Missing absolute episode number' }
            @{ Reason = 'Episode 5 was unexpected considering the S01E04 folder name'; Expected = 'Unexpected episode' }
            @{ Reason = 'Episode file on disk contains more episodes than this file contains'; Expected = 'Existing file has more episodes' }
        ) {
            InModuleScope 'Stagearr.Core' -Parameters @{ Reason = $Reason; Expected = $Expected } {
                Get-SASimplifiedRejectionReason -Reason $Reason | Should -Be $Expected
            }
        }
    }
}
