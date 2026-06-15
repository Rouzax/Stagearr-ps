BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'New-SAMDBListPayload' {

    Context 'Movies' {
        It 'builds a movie payload including all available IDs' {
            InModuleScope 'Stagearr.Core' {
                $p = New-SAMDBListPayload -MediaType 'movie' -Ids @{ tmdb = '678512'; imdb = 'tt7599146' }
                $p.movies | Should -HaveCount 1
                $p.movies[0].ids.tmdb | Should -Be 678512
                $p.movies[0].ids.tmdb | Should -BeOfType [int]
                $p.movies[0].ids.imdb | Should -Be 'tt7599146'
                $p.Keys | Should -Not -Contain 'shows'
            }
        }

        It 'returns $null when no usable ID is present' {
            InModuleScope 'Stagearr.Core' {
                (New-SAMDBListPayload -MediaType 'movie' -Ids @{}) | Should -BeNullOrEmpty
                (New-SAMDBListPayload -MediaType 'movie' -Ids @{ tmdb = ''; imdb = $null }) | Should -BeNullOrEmpty
            }
        }
    }

    Context 'TV' {
        It 'builds a nested shows/seasons/episodes payload' {
            InModuleScope 'Stagearr.Core' {
                $eps = @(
                    [pscustomobject]@{ Season = 1; Episode = 9 }
                )
                $p = New-SAMDBListPayload -MediaType 'tv' -Ids @{ tvdb = '454109'; tmdb = '270476'; imdb = 'tt33332385' } -Episodes $eps
                $p.shows | Should -HaveCount 1
                $p.shows[0].ids.tvdb | Should -Be 454109
                $p.shows[0].seasons | Should -HaveCount 1
                $p.shows[0].seasons[0].number | Should -Be 1
                $p.shows[0].seasons[0].episodes[0].number | Should -Be 9
            }
        }

        It 'groups episodes by season and de-duplicates' {
            InModuleScope 'Stagearr.Core' {
                $eps = @(
                    [pscustomobject]@{ Season = 1; Episode = 2 }
                    [pscustomobject]@{ Season = 1; Episode = 1 }
                    [pscustomobject]@{ Season = 1; Episode = 1 }
                    [pscustomobject]@{ Season = 2; Episode = 5 }
                )
                $p = New-SAMDBListPayload -MediaType 'tv' -Ids @{ tvdb = '1' } -Episodes $eps
                $p.shows[0].seasons | Should -HaveCount 2
                $s1 = $p.shows[0].seasons | Where-Object { $_.number -eq 1 }
                @($s1.episodes).Count | Should -Be 2
                @($s1.episodes.number | Sort-Object) | Should -Be @(1, 2)
            }
        }

        It 'returns $null when there are no episodes' {
            InModuleScope 'Stagearr.Core' {
                (New-SAMDBListPayload -MediaType 'tv' -Ids @{ tvdb = '1' } -Episodes @()) | Should -BeNullOrEmpty
                (New-SAMDBListPayload -MediaType 'tv' -Ids @{ tvdb = '1' } -Episodes $null) | Should -BeNullOrEmpty
            }
        }

        It 'returns $null when there is no usable ID even with episodes' {
            InModuleScope 'Stagearr.Core' {
                $eps = @([pscustomobject]@{ Season = 1; Episode = 1 })
                (New-SAMDBListPayload -MediaType 'tv' -Ids @{} -Episodes $eps) | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Invoke-SAMDBListCollect' {

    Context 'Successful collection sync' {
        It 'posts to /sync/collection with the API key and sums updated counts' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null
                $script:CapturedBody = $null
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    $script:CapturedUri = $Uri
                    $script:CapturedBody = $Body
                    return [PSCustomObject]@{
                        Success = $true
                        Data    = [PSCustomObject]@{ updated = [PSCustomObject]@{ movies = 0; shows = 0; seasons = 0; episodes = 5 } }
                    }
                }

                $config = @{ enabled = $true; apiKey = 'test-key'; timeoutSeconds = 10 }
                $meta = @{ TmdbId = '270476'; TvdbId = '454109'; ImdbId = 'tt33332385' }
                $eps = @([pscustomobject]@{ Season = 1; Episode = 1 }, [pscustomobject]@{ Season = 1; Episode = 2 })

                $r = Invoke-SAMDBListCollect -Config $config -ArrMetadata $meta -MediaType 'tv' -ImportedEpisodes $eps

                $r.Success | Should -BeTrue
                $r.Skipped | Should -BeFalse
                $r.Updated | Should -Be 5
                $script:CapturedUri | Should -Match '/sync/collection\?apikey=test-key'
                $script:CapturedBody.shows[0].ids.tvdb | Should -Be 454109
            }
        }
    }

    Context 'Skip cases (quiet, no HTTP call)' {
        It 'skips when disabled' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest { throw 'should not be called' }
                $r = Invoke-SAMDBListCollect -Config @{ enabled = $false; apiKey = 'k' } -ArrMetadata @{ TmdbId = '1' } -MediaType 'movie'
                $r.Skipped | Should -BeTrue
                $r.Success | Should -BeFalse
                Should -Invoke Invoke-SAWebRequest -Times 0
            }
        }

        It 'skips when no API key' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest { throw 'should not be called' }
                $r = Invoke-SAMDBListCollect -Config @{ enabled = $true; apiKey = '' } -ArrMetadata @{ TmdbId = '1' } -MediaType 'movie'
                $r.Skipped | Should -BeTrue
                Should -Invoke Invoke-SAWebRequest -Times 0
            }
        }

        It 'skips when no usable ID' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest { throw 'should not be called' }
                $r = Invoke-SAMDBListCollect -Config @{ enabled = $true; apiKey = 'k' } -ArrMetadata @{ TmdbId = ''; TvdbId = ''; ImdbId = '' } -MediaType 'movie'
                $r.Skipped | Should -BeTrue
                Should -Invoke Invoke-SAWebRequest -Times 0
            }
        }

        It 'skips a TV item with no imported episodes' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest { throw 'should not be called' }
                $r = Invoke-SAMDBListCollect -Config @{ enabled = $true; apiKey = 'k' } -ArrMetadata @{ TvdbId = '1' } -MediaType 'tv' -ImportedEpisodes @()
                $r.Skipped | Should -BeTrue
                Should -Invoke Invoke-SAWebRequest -Times 0
            }
        }
    }

    Context 'Failure handling (non-fatal)' {
        It 'returns a non-skip failure when the API call fails' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    return [PSCustomObject]@{ Success = $false; ErrorMessage = '401 Unauthorized' }
                }
                $r = Invoke-SAMDBListCollect -Config @{ enabled = $true; apiKey = 'bad' } -ArrMetadata @{ TmdbId = '1' } -MediaType 'movie'
                $r.Success | Should -BeFalse
                $r.Skipped | Should -BeFalse
                $r.ErrorMessage | Should -Match '401'
            }
        }

        It 'does not throw when the HTTP helper throws' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest { throw 'boom' }
                { $script:res = Invoke-SAMDBListCollect -Config @{ enabled = $true; apiKey = 'k' } -ArrMetadata @{ TmdbId = '1' } -MediaType 'movie' } | Should -Not -Throw
                $script:res.Success | Should -BeFalse
                $script:res.Skipped | Should -BeFalse
                $script:res.ErrorMessage | Should -Match 'boom'
            }
        }
    }
}

Describe 'Test-SAFeatureEnabled - MDBList' {
    It 'is opt-in (disabled by default / when section missing)' {
        Test-SAFeatureEnabled -Feature 'MDBList' -Config @{} | Should -BeFalse
        Test-SAFeatureEnabled -Feature 'MDBList' -Config @{ mdblist = @{ enabled = $false } } | Should -BeFalse
    }
    It 'is enabled only when explicitly enabled' {
        Test-SAFeatureEnabled -Feature 'MDBList' -Config @{ mdblist = @{ enabled = $true } } | Should -BeTrue
    }
}

Describe 'Get-SAImportedEpisodeList' {
    It 'returns distinct season/episode pairs from importable files' {
        InModuleScope 'Stagearr.Core' {
            $files = @(
                [pscustomobject]@{ episodes = @([pscustomobject]@{ id = 10; seasonNumber = 1; episodeNumber = 1 }) }
                [pscustomobject]@{ episodes = @([pscustomobject]@{ id = 11; seasonNumber = 1; episodeNumber = 2 }) }
            )
            $r = Get-SAImportedEpisodeList -ImportableFiles $files -Verification $null
            @($r).Count | Should -Be 2
            @($r.Episode | Sort-Object) | Should -Be @(1, 2)
        }
    }

    It 'filters to episodes confirmed by verification history (partial import)' {
        InModuleScope 'Stagearr.Core' {
            $files = @(
                [pscustomobject]@{ episodes = @([pscustomobject]@{ id = 10; seasonNumber = 1; episodeNumber = 1 }) }
                [pscustomobject]@{ episodes = @([pscustomobject]@{ id = 11; seasonNumber = 1; episodeNumber = 2 }) }
                [pscustomobject]@{ episodes = @([pscustomobject]@{ id = 12; seasonNumber = 1; episodeNumber = 3 }) }
            )
            $verification = [pscustomobject]@{ Records = @(
                    [pscustomobject]@{ episodeId = 10 },
                    [pscustomobject]@{ episodeId = 12 }
                ) }
            $r = Get-SAImportedEpisodeList -ImportableFiles $files -Verification $verification
            @($r).Count | Should -Be 2
            @($r.Episode | Sort-Object) | Should -Be @(1, 3)
        }
    }
}
