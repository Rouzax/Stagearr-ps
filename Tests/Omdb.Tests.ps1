BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SAOmdbMetadata' {

    Context 'IMDB ID lookup (tier 1)' {

        It 'should use i= parameter when ImdbId is provided' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {
                    $script:CapturedUri = $Uri
                    return [PSCustomObject]@{
                        Response    = 'True'
                        Title       = 'One Piece'
                        Year        = '2023-'
                        imdbID      = 'tt11737520'
                        imdbRating  = '8.4'
                        Genre       = 'Action, Adventure, Comedy'
                        Runtime     = '55 min'
                        Plot        = 'N/A'
                        Poster      = 'N/A'
                        Type        = 'series'
                        Ratings     = @()
                    }
                }

                $config = @{ enabled = $true; apiKey = 'test-key'; poster = @{ enabled = $false }; display = @{ plot = $false } }
                $result = Get-SAOmdbMetadata -ImdbId 'tt11737520' -Type 'series' -Config $config

                $script:CapturedUri | Should -Match 'i=tt11737520'
                $script:CapturedUri | Should -Not -Match 't='
                $result | Should -Not -BeNullOrEmpty
                $result.Title | Should -Be 'One Piece'
                $result.ImdbId | Should -Be 'tt11737520'
            }
        }

        It 'should normalize IMDB ID without tt prefix' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {
                    $script:CapturedUri = $Uri
                    return [PSCustomObject]@{
                        Response   = 'True'
                        Title      = 'One Piece'
                        Year       = '2023-'
                        imdbID     = 'tt11737520'
                        imdbRating = '8.4'
                        Genre      = 'Action'
                        Poster     = 'N/A'
                        Type       = 'series'
                        Ratings    = @()
                    }
                }

                $config = @{ enabled = $true; apiKey = 'test-key'; poster = @{ enabled = $false }; display = @{ plot = $false } }
                Get-SAOmdbMetadata -ImdbId '11737520' -Type 'series' -Config $config

                $script:CapturedUri | Should -Match 'i=tt11737520'
            }
        }

        It 'should prefer ImdbId over Title when both are provided' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {
                    $script:CapturedUri = $Uri
                    return [PSCustomObject]@{
                        Response   = 'True'
                        Title      = 'One Piece'
                        Year       = '2023-'
                        imdbID     = 'tt11737520'
                        imdbRating = '8.4'
                        Genre      = 'Action'
                        Poster     = 'N/A'
                        Type       = 'series'
                        Ratings    = @()
                    }
                }

                $config = @{ enabled = $true; apiKey = 'test-key'; poster = @{ enabled = $false }; display = @{ plot = $false } }
                Get-SAOmdbMetadata -ImdbId 'tt11737520' -Title 'ONE PIECE' -Type 'series' -Config $config

                $script:CapturedUri | Should -Match 'i=tt11737520'
                $script:CapturedUri | Should -Not -Match 't='
            }
        }
    }

    Context 'Title lookup (tier 2/3)' {

        It 'should use t= parameter when only Title is provided' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {
                    $script:CapturedUri = $Uri
                    return [PSCustomObject]@{
                        Response   = 'True'
                        Title      = 'One Piece'
                        Year       = '1999-'
                        imdbID     = 'tt0388629'
                        imdbRating = '9.0'
                        Genre      = 'Animation, Action, Adventure'
                        Poster     = 'N/A'
                        Type       = 'series'
                        Ratings    = @()
                    }
                }

                $config = @{ enabled = $true; apiKey = 'test-key'; poster = @{ enabled = $false }; display = @{ plot = $false } }
                $result = Get-SAOmdbMetadata -Title 'ONE PIECE' -Type 'series' -Config $config

                $script:CapturedUri | Should -Match 't=ONE'
                $script:CapturedUri | Should -Not -Match 'i='
            }
        }

        It 'should include year parameter when provided' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {
                    $script:CapturedUri = $Uri
                    return [PSCustomObject]@{
                        Response   = 'True'
                        Title      = 'One Piece'
                        Year       = '2023-'
                        imdbID     = 'tt11737520'
                        imdbRating = '8.4'
                        Genre      = 'Action'
                        Poster     = 'N/A'
                        Type       = 'series'
                        Ratings    = @()
                    }
                }

                $config = @{ enabled = $true; apiKey = 'test-key'; poster = @{ enabled = $false }; display = @{ plot = $false } }
                Get-SAOmdbMetadata -Title 'One Piece' -Year '2023' -Type 'series' -Config $config

                $script:CapturedUri | Should -Match 'y=2023'
            }
        }
    }

    Context 'Validation' {

        It 'should return null when neither ImdbId nor Title is provided' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {}

                $config = @{ enabled = $true; apiKey = 'test-key'; poster = @{ enabled = $false }; display = @{ plot = $false } }
                $result = Get-SAOmdbMetadata -Type 'series' -Config $config

                $result | Should -BeNullOrEmpty
                Should -Invoke Invoke-SAOmdbRequest -Times 0
            }
        }

        It 'should return null when OMDb is disabled' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {}

                $config = @{ enabled = $false; apiKey = 'test-key' }
                $result = Get-SAOmdbMetadata -ImdbId 'tt11737520' -Config $config

                $result | Should -BeNullOrEmpty
                Should -Invoke Invoke-SAOmdbRequest -Times 0
            }
        }

        It 'should return null when API key is missing' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {}

                $config = @{ enabled = $true; apiKey = '' }
                $result = Get-SAOmdbMetadata -ImdbId 'tt11737520' -Config $config

                $result | Should -BeNullOrEmpty
                Should -Invoke Invoke-SAOmdbRequest -Times 0
            }
        }
    }

    Context 'Type parameter' {

        It 'should include type in URL for IMDB ID lookup' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAOmdbRequest {
                    $script:CapturedUri = $Uri
                    return [PSCustomObject]@{
                        Response = 'True'; Title = 'Test'; Year = '2024'; imdbID = 'tt1234567'
                        imdbRating = '7.0'; Genre = 'Drama'; Poster = 'N/A'; Type = 'movie'; Ratings = @()
                    }
                }

                $config = @{ enabled = $true; apiKey = 'test-key'; poster = @{ enabled = $false }; display = @{ plot = $false } }
                Get-SAOmdbMetadata -ImdbId 'tt1234567' -Type 'movie' -Config $config

                $script:CapturedUri | Should -Match 'type=movie'
            }
        }
    }
}
