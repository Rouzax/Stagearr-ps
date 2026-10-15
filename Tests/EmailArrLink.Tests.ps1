#Requires -Version 7.0
BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'Stagearr.Core' 'Stagearr.Core.psm1'
    Import-Module $modulePath -Force
}

Describe 'Get-SAArrWebUrl' {
    It 'builds a Radarr movie URL from linkUrl' {
        InModuleScope Stagearr.Core {
            $config = @{ host = 'localhost'; port = 7878; ssl = $false; urlRoot = ''; linkUrl = 'https://radarr.example.com' }
            Get-SAArrWebUrl -Config $config -AppType 'Radarr' -TitleSlug 'the-matrix-603' |
                Should -Be 'https://radarr.example.com/movie/the-matrix-603'
        }
    }

    It 'builds a Sonarr series URL and trims a trailing slash from linkUrl' {
        InModuleScope Stagearr.Core {
            $config = @{ host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; linkUrl = 'https://example.com/sonarr/' }
            Get-SAArrWebUrl -Config $config -AppType 'Sonarr' -TitleSlug 'the-expanse' |
                Should -Be 'https://example.com/sonarr/series/the-expanse'
        }
    }

    It 'falls back to the API address with urlRoot when linkUrl is empty' {
        InModuleScope Stagearr.Core {
            Mock Resolve-SAHostToIPv4 { [PSCustomObject]@{ ResolvedHost = '192.0.2.10'; WasResolved = $true } }
            $config = @{ host = 'radarr.lan'; port = 7878; ssl = $true; urlRoot = '/radarr/'; linkUrl = '' }
            Get-SAArrWebUrl -Config $config -AppType 'Radarr' -TitleSlug 'dune-438631' |
                Should -Be 'https://radarr.lan:7878/radarr/movie/dune-438631'
        }
    }

    It 'falls back to the API address when linkUrl is absent' {
        InModuleScope Stagearr.Core {
            Mock Resolve-SAHostToIPv4 { [PSCustomObject]@{ ResolvedHost = '127.0.0.1'; WasResolved = $true } }
            $config = @{ host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
            Get-SAArrWebUrl -Config $config -AppType 'Sonarr' -TitleSlug 'severance' |
                Should -Be 'http://localhost:8989/series/severance'
        }
    }

    It 'URL-encodes the slug' {
        InModuleScope Stagearr.Core {
            $config = @{ linkUrl = 'https://radarr.example.com' }
            Get-SAArrWebUrl -Config $config -AppType 'Radarr' -TitleSlug 'a b/c' |
                Should -Be 'https://radarr.example.com/movie/a%20b%2Fc'
        }
    }

    It 'returns null when the slug is missing' {
        InModuleScope Stagearr.Core {
            $config = @{ linkUrl = 'https://radarr.example.com' }
            Get-SAArrWebUrl -Config $config -AppType 'Radarr' -TitleSlug '' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-SAArrMetadata TitleSlug' {
    It 'extracts titleSlug from a Radarr movie' {
        InModuleScope Stagearr.Core {
            $scan = [PSCustomObject]@{ movie = [PSCustomObject]@{ title = 'The Matrix'; year = 1999; titleSlug = 'the-matrix-603' } }
            (ConvertTo-SAArrMetadata -ScanResult $scan -AppType 'Radarr').TitleSlug | Should -Be 'the-matrix-603'
        }
    }

    It 'extracts titleSlug from a Sonarr series' {
        InModuleScope Stagearr.Core {
            $scan = [PSCustomObject]@{ series = [PSCustomObject]@{ title = 'The Expanse'; year = 2015; titleSlug = 'the-expanse' } }
            (ConvertTo-SAArrMetadata -ScanResult $scan -AppType 'Sonarr').TitleSlug | Should -Be 'the-expanse'
        }
    }
}

Describe 'Email title section *arr link' {
    It 'renders the link in the poster layout' {
        InModuleScope Stagearr.Core {
            $summary = @{
                Name     = 'The Matrix'
                OmdbData = @{ Genre = 'Action'; ImdbId = 'tt0133093' }
                ArrLink  = @{ Url = 'https://radarr.example.com/movie/the-matrix-603'; AppName = 'Radarr' }
            }
            $html = Get-SAEmailTitleSection -Summary $summary
            $html | Should -Match 'href="https://radarr\.example\.com/movie/the-matrix-603"'
            $html | Should -Match 'View in Radarr'
            $html | Should -Match 'View on IMDb'
        }
    }

    It 'renders the link in the centered layout' {
        InModuleScope Stagearr.Core {
            $summary = @{
                Name    = 'The Expanse S01E01'
                ArrLink = @{ Url = 'https://sonarr.example.com/series/the-expanse'; AppName = 'Sonarr' }
            }
            $html = Get-SAEmailTitleSection -Summary $summary
            $html | Should -Match 'href="https://sonarr\.example\.com/series/the-expanse"'
            $html | Should -Match 'View in Sonarr'
        }
    }

    It 'HTML-escapes the URL' {
        InModuleScope Stagearr.Core {
            $summary = @{
                Name    = 'X'
                ArrLink = @{ Url = 'https://x.example.com/movie/a"b'; AppName = 'Radarr' }
            }
            Get-SAEmailTitleSection -Summary $summary | Should -Not -Match 'a"b'
        }
    }

    It 'omits the link when ArrLink is not set' {
        InModuleScope Stagearr.Core {
            $html = Get-SAEmailTitleSection -Summary @{ Name = 'X'; OmdbData = @{ Genre = 'Drama' } }
            $html | Should -Not -Match 'View in'
            $html = Get-SAEmailTitleSection -Summary @{ Name = 'X' }
            $html | Should -Not -Match 'View in'
        }
    }
}
