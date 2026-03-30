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

Describe 'Get-SAErrorTypeFromRejection' {

    It 'maps Episode title TBA to tba' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Episode title TBA' | Should -Be 'tba'
        }
    }

    It 'maps Missing absolute episode number to tba' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Missing absolute episode number' | Should -Be 'tba'
        }
    }

    It 'maps Not enough disk space to disk-space' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Not enough disk space' | Should -Be 'disk-space'
        }
    }

    It 'maps Unverified scene mapping to scene-mapping' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Unverified scene mapping' | Should -Be 'scene-mapping'
        }
    }

    It 'maps No audio tracks to corrupt-file' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'No audio tracks' | Should -Be 'corrupt-file'
        }
    }

    It 'maps Full season file to full-season' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Full season file' | Should -Be 'full-season'
        }
    }

    It 'maps Partial season pack to partial-season' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Partial season pack' | Should -Be 'partial-season'
        }
    }

    It 'maps Unexpected episode to episode-mismatch' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Unexpected episode' | Should -Be 'episode-mismatch'
        }
    }

    It 'maps Existing file has more episodes to episode-mismatch' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Existing file has more episodes' | Should -Be 'episode-mismatch'
        }
    }

    # Existing mappings still work
    It 'maps Quality exists to quality' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Quality exists' | Should -Be 'quality'
        }
    }
}

Describe 'Get-SAImportHint' {

    It 'returns TBA hint for Sonarr' {
        InModuleScope 'Stagearr.Core' {
            $hint = Get-SAImportHint -ErrorType 'tba' -ImporterLabel 'Sonarr'
            $hint | Should -BeLike '*48 hours*'
            $hint | Should -BeLike '*-Rerun*'
        }
    }

    It 'returns disk space hint' {
        InModuleScope 'Stagearr.Core' {
            $hint = Get-SAImportHint -ErrorType 'disk-space' -ImporterLabel 'Sonarr'
            $hint | Should -BeLike '*space*'
        }
    }

    It 'returns scene mapping hint' {
        InModuleScope 'Stagearr.Core' {
            $hint = Get-SAImportHint -ErrorType 'scene-mapping' -ImporterLabel 'Sonarr'
            $hint | Should -BeLike '*TheXEM*'
        }
    }

    It 'returns corrupt file hint' {
        InModuleScope 'Stagearr.Core' {
            $hint = Get-SAImportHint -ErrorType 'corrupt-file' -ImporterLabel 'Sonarr'
            $hint | Should -BeLike '*corrupt*'
        }
    }
}
