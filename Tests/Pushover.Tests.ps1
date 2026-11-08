BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'ConvertFrom-SAPushoverConfig' {

    It 'parses recipients and routes' {
        InModuleScope 'Stagearr.Core' {
            $p = ConvertFrom-SAPushoverConfig -Config @{
                recipients = @('me|uAAA|all', 'partner|uBBB|success')
                routes     = @('tv,movie|me,partner', 'software|me')
            }
            $p.Recipients['me'].Key | Should -Be 'uAAA'
            $p.Recipients['me'].Notify | Should -Be 'all'
            $p.Recipients['partner'].Notify | Should -Be 'success'
            $p.Routes | Should -HaveCount 2
            $p.Routes[0].Labels | Should -Be @('tv', 'movie')
            $p.Routes[0].Recipients | Should -Be @('me', 'partner')
            $p.Errors | Should -BeNullOrEmpty
        }
    }

    It 'trims spaces and lower-cases the notify value' {
        InModuleScope 'Stagearr.Core' {
            $p = ConvertFrom-SAPushoverConfig -Config @{
                recipients = @(' me | uAAA | All ')
                routes     = @(' tv , movie | me ')
            }
            $p.Recipients['me'].Key | Should -Be 'uAAA'
            $p.Recipients['me'].Notify | Should -Be 'all'
            $p.Routes[0].Labels | Should -Be @('tv', 'movie')
            $p.Routes[0].Recipients | Should -Be @('me')
        }
    }

    It 'reports malformed entries without the key and keeps the valid ones' {
        InModuleScope 'Stagearr.Core' {
            $p = ConvertFrom-SAPushoverConfig -Config @{
                recipients = @('me|uAAA|all', 'bad', 'x|uXXX|sometimes', 'me|uDUP|all')
                routes     = @('tv|me,ghost', 'nolabels')
            }
            $p.Recipients.Keys | Should -Be @('me')
            $p.Recipients['me'].Key | Should -Be 'uAAA'
            $p.Routes | Should -HaveCount 1
            $p.Routes[0].Recipients | Should -Be @('me')
            $p.Errors | Should -HaveCount 5
            ($p.Errors -join ' ') | Should -Not -Match 'uAAA|uXXX|uDUP'
            ($p.Errors -join ' ') | Should -Match 'ghost'
        }
    }

    It 'returns empty collections for an empty config' {
        InModuleScope 'Stagearr.Core' {
            $p = ConvertFrom-SAPushoverConfig -Config @{}
            $p.Recipients.Count | Should -Be 0
            @($p.Routes).Count | Should -Be 0
            @($p.Errors).Count | Should -Be 0
        }
    }
}

Describe 'Get-SAPushoverRecipients' {

    BeforeAll {
        $script:labelConfig = @{
            labels = @{ tv = 'tv'; tvLabels = @('sonarr'); movie = 'movie'; movieLabels = @('radarr') }
        }
    }

    It 'matches a tv route to a tv alias label' {
        InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:labelConfig } {
            param($C)
            $p = ConvertFrom-SAPushoverConfig -Config @{ recipients = @('me|uA|all'); routes = @('tv|me') }
            $r = @(Get-SAPushoverRecipients -Parsed $p -Label 'Sonarr' -Config $C)
            $r.Name | Should -Be @('me')
        }
    }

    It 'matches a movie route to a movie alias label' {
        InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:labelConfig } {
            param($C)
            $p = ConvertFrom-SAPushoverConfig -Config @{ recipients = @('me|uA|all'); routes = @('movie|me') }
            @(Get-SAPushoverRecipients -Parsed $p -Label 'radarr' -Config $C).Name | Should -Be @('me')
        }
    }

    It 'matches a named label case-insensitively' {
        InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:labelConfig } {
            param($C)
            $p = ConvertFrom-SAPushoverConfig -Config @{ recipients = @('me|uA|all'); routes = @('software|me') }
            @(Get-SAPushoverRecipients -Parsed $p -Label 'Software' -Config $C).Name | Should -Be @('me')
        }
    }

    It 'uses the catch-all only when no named route matches' {
        InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:labelConfig } {
            param($C)
            $p = ConvertFrom-SAPushoverConfig -Config @{
                recipients = @('me|uA|all', 'partner|uB|success')
                routes     = @('tv|me', '*|partner')
            }
            @(Get-SAPushoverRecipients -Parsed $p -Label 'tv' -Config $C).Name | Should -Be @('me')
            @(Get-SAPushoverRecipients -Parsed $p -Label 'games' -Config $C).Name | Should -Be @('partner')
        }
    }

    It 'returns nothing when no route matches and there is no catch-all' {
        InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:labelConfig } {
            param($C)
            $p = ConvertFrom-SAPushoverConfig -Config @{ recipients = @('me|uA|all'); routes = @('tv|me') }
            @(Get-SAPushoverRecipients -Parsed $p -Label 'software' -Config $C).Count | Should -Be 0
        }
    }

    It 'unions recipients of several matching routes without duplicates' {
        InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:labelConfig } {
            param($C)
            $p = ConvertFrom-SAPushoverConfig -Config @{
                recipients = @('me|uA|all', 'partner|uB|success')
                routes     = @('tv|me', 'sonarr|me,partner')
            }
            $names = @(Get-SAPushoverRecipients -Parsed $p -Label 'sonarr' -Config $C).Name
            $names | Should -HaveCount 2
            $names | Should -Contain 'me'
            $names | Should -Contain 'partner'
        }
    }
}

Describe 'Pushover config masking' {
    It 'masks pushover values in sync previews' {
        InModuleScope 'Stagearr.Core' {
            Format-SAConfigValuePreview -Path 'notifications.pushover.recipients' -Value @('me|uAAA|all') | Should -Be '***'
            Format-SAConfigValuePreview -Path 'notifications.pushover.appToken' -Value 'aXXX' | Should -Be '***'
        }
    }
}

Describe 'Get-SAPushoverState' {

    It 'is Failed when the job failed before import' {
        InModuleScope 'Stagearr.Core' {
            $s = Get-SAPushoverState -JobSuccess $false -ImportResult $null
            $s.State | Should -Be 'Failed'
            $s.ImportedCount | Should -Be 0
        }
    }

    It 'is Imported for a successful passthrough job' {
        InModuleScope 'Stagearr.Core' {
            $s = Get-SAPushoverState -JobSuccess $true -IsPassthrough $true
            $s.State | Should -Be 'Imported'
            $s.ImportedCount | Should -Be 1
        }
    }

    It 'is Imported when every file imported' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; Status = $null; ImportedCount = 8; AbortedCount = 0; Skipped = $false; QualityRejected = $false }
            $s = Get-SAPushoverState -JobSuccess $true -ImportResult $r
            $s.State | Should -Be 'Imported'
            $s.ImportedCount | Should -Be 8
            $s.HasWarnings | Should -BeFalse
        }
    }

    It 'stays Imported when other files were skipped as already in library' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; Status = $null; ImportedCount = 7; SkippedCount = 1; AbortedCount = 0; Skipped = $false; QualityRejected = $false }
            (Get-SAPushoverState -JobSuccess $true -ImportResult $r).State | Should -Be 'Imported'
        }
    }

    It 'is Partial when some files imported and a TBA retry is scheduled' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; Status = $null; ImportedCount = 7; AbortedCount = 0; Skipped = $false; QualityRejected = $false }
            $s = Get-SAPushoverState -JobSuccess $true -ImportResult $r -TbaRetryScheduled $true
            $s.State | Should -Be 'Partial'
            $s.ImportedCount | Should -Be 7
            $s.HasWarnings | Should -BeTrue
        }
    }

    It 'is Partial with nothing imported when only a TBA retry is scheduled' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; ImportedCount = 0; Skipped = $true; QualityRejected = $false }
            $s = Get-SAPushoverState -JobSuccess $true -ImportResult $r -TbaRetryScheduled $true
            $s.State | Should -Be 'Partial'
            $s.ImportedCount | Should -Be 0
        }
    }

    It 'is Partial when the arr silently skipped some files' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; Status = 'partial'; ImportedCount = 5; AbortedCount = 1; Skipped = $false; QualityRejected = $false }
            (Get-SAPushoverState -JobSuccess $true -ImportResult $r).State | Should -Be 'Partial'
        }
    }

    It 'is NothingNew when everything was already in the library' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; ImportedFiles = @(); Skipped = $true; QualityRejected = $true }
            (Get-SAPushoverState -JobSuccess $true -ImportResult $r).State | Should -Be 'NothingNew'
        }
    }

    It 'is NothingNew for a superseded TBA retry' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; Skipped = $true; QualityRejected = $true; Superseded = $true; ImportedFiles = @() }
            (Get-SAPushoverState -JobSuccess $true -ImportResult $r).State | Should -Be 'NothingNew'
        }
    }

    It 'is Partial when a subtitle language is missing' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; ImportedCount = 1; AbortedCount = 0; Skipped = $false; QualityRejected = $false }
            (Get-SAPushoverState -JobSuccess $true -ImportResult $r -MissingLanguages @('nl')).State | Should -Be 'Partial'
        }
    }

    It 'counts one import for a Medusa-style result without counts' {
        InModuleScope 'Stagearr.Core' {
            $s = Get-SAPushoverState -JobSuccess $true -ImportResult ([PSCustomObject]@{ Success = $true })
            $s.State | Should -Be 'Imported'
            $s.ImportedCount | Should -Be 1
        }
    }
}
