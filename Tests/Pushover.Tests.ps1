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
