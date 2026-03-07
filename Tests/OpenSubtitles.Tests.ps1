BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Resolve-SAOpenSubtitlesImdbId' {

    Context 'Type filtering in API query for TV episodes' {

        It 'should include type=episode, season_number, and episode_number in the query' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Get-SAOpenSubtitlesToken { return 'fake-token' }
                Mock Test-SAFeatureEnabled { return $false }
                Mock Invoke-SAWebRequest {
                    $script:CapturedUri = $Uri
                    return @{
                        Success = $true
                        Data    = @{
                            data = @(
                                @{
                                    attributes = @{
                                        feature_details = @{
                                            imdb_id      = 1234567
                                            feature_type = 'Episode'
                                        }
                                    }
                                }
                            )
                        }
                    }
                }

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                apiKey = 'test-key'
                            }
                        }
                    }
                    State  = @{
                        ReleaseInfo = @{
                            Type    = 'episode'
                            Title   = 'Some Show'
                            Season  = '2'
                            Episode = '5'
                        }
                    }
                    Job    = @{
                        input = @{
                            downloadLabel = 'TV'
                        }
                    }
                }

                $null = Resolve-SAOpenSubtitlesImdbId -Context $context -MovieHash 'abc123' -VideoFileName 'Some.Show.S02E05.720p.mkv'

                $script:CapturedUri | Should -Match 'type=episode'
                $script:CapturedUri | Should -Match 'season_number=2'
                $script:CapturedUri | Should -Match 'episode_number=5'
            }
        }
    }

    Context 'Type filtering in API query for movies' {

        It 'should include type=movie and year in the query' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Get-SAOpenSubtitlesToken { return 'fake-token' }
                Mock Test-SAFeatureEnabled { return $false }
                Mock Invoke-SAWebRequest {
                    $script:CapturedUri = $Uri
                    return @{
                        Success = $true
                        Data    = @{
                            data = @(
                                @{
                                    attributes = @{
                                        feature_details = @{
                                            imdb_id      = 7654321
                                            feature_type = 'Movie'
                                        }
                                    }
                                }
                            )
                        }
                    }
                }

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                apiKey = 'test-key'
                            }
                        }
                    }
                    State  = @{
                        ReleaseInfo = @{
                            Type  = 'movie'
                            Title = 'Some Movie'
                            Year  = '2024'
                        }
                    }
                    Job    = @{
                        input = @{
                            downloadLabel = 'Movie'
                        }
                    }
                }

                $null = Resolve-SAOpenSubtitlesImdbId -Context $context -MovieHash 'def456' -VideoFileName 'Some.Movie.2024.1080p.mkv'

                $script:CapturedUri | Should -Match 'type=movie'
                $script:CapturedUri | Should -Match 'year=2024'
            }
        }
    }

    Context 'Post-validation rejects mismatched feature_type for TV content' {

        It 'should return empty string when API returns Movie but content is episode' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAOpenSubtitlesToken { return 'fake-token' }
                Mock Test-SAFeatureEnabled { return $false }
                Mock Invoke-SAWebRequest {
                    return @{
                        Success = $true
                        Data    = @{
                            data = @(
                                @{
                                    attributes = @{
                                        feature_details = @{
                                            imdb_id      = 9999999
                                            feature_type = 'Movie'
                                        }
                                    }
                                }
                            )
                        }
                    }
                }

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                apiKey = 'test-key'
                            }
                        }
                    }
                    State  = @{
                        ReleaseInfo = @{
                            Type    = 'episode'
                            Title   = 'Some Show'
                            Season  = '1'
                            Episode = '3'
                        }
                    }
                    Job    = @{
                        input = @{
                            downloadLabel = 'TV'
                        }
                    }
                }

                $result = Resolve-SAOpenSubtitlesImdbId -Context $context -MovieHash 'hash1' -VideoFileName 'Some.Show.S01E03.mkv'

                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Post-validation rejects mismatched feature_type for movie content' {

        It 'should return empty string when API returns Episode but content is movie' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAOpenSubtitlesToken { return 'fake-token' }
                Mock Test-SAFeatureEnabled { return $false }
                Mock Invoke-SAWebRequest {
                    return @{
                        Success = $true
                        Data    = @{
                            data = @(
                                @{
                                    attributes = @{
                                        feature_details = @{
                                            imdb_id      = 8888888
                                            feature_type = 'Episode'
                                        }
                                    }
                                }
                            )
                        }
                    }
                }

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                apiKey = 'test-key'
                            }
                        }
                    }
                    State  = @{
                        ReleaseInfo = @{
                            Type  = 'movie'
                            Title = 'Some Movie'
                            Year  = '2024'
                        }
                    }
                    Job    = @{
                        input = @{
                            downloadLabel = 'Movie'
                        }
                    }
                }

                $result = Resolve-SAOpenSubtitlesImdbId -Context $context -MovieHash 'hash2' -VideoFileName 'Some.Movie.2024.mkv'

                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Post-validation accepts matching feature_type' {

        It 'should return the IMDB ID when feature_type matches for episodes' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAOpenSubtitlesToken { return 'fake-token' }
                Mock Test-SAFeatureEnabled { return $false }
                Mock Invoke-SAWebRequest {
                    return @{
                        Success = $true
                        Data    = @{
                            data = @(
                                @{
                                    attributes = @{
                                        feature_details = @{
                                            imdb_id      = 1111111
                                            feature_type = 'Episode'
                                        }
                                    }
                                }
                            )
                        }
                    }
                }

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                apiKey = 'test-key'
                            }
                        }
                    }
                    State  = @{
                        ReleaseInfo = @{
                            Type    = 'episode'
                            Title   = 'Some Show'
                            Season  = '1'
                            Episode = '1'
                        }
                    }
                    Job    = @{
                        input = @{
                            downloadLabel = 'TV'
                        }
                    }
                }

                $result = Resolve-SAOpenSubtitlesImdbId -Context $context -MovieHash 'hash3' -VideoFileName 'Some.Show.S01E01.mkv'

                $result | Should -Be '1111111'
            }
        }

        It 'should return the IMDB ID when feature_type matches for movies' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Get-SAOpenSubtitlesToken { return 'fake-token' }
                Mock Test-SAFeatureEnabled { return $false }
                Mock Invoke-SAWebRequest {
                    return @{
                        Success = $true
                        Data    = @{
                            data = @(
                                @{
                                    attributes = @{
                                        feature_details = @{
                                            imdb_id      = 2222222
                                            feature_type = 'Movie'
                                        }
                                    }
                                }
                            )
                        }
                    }
                }

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                apiKey = 'test-key'
                            }
                        }
                    }
                    State  = @{
                        ReleaseInfo = @{
                            Type  = 'movie'
                            Title = 'Some Movie'
                            Year  = '2024'
                        }
                    }
                    Job    = @{
                        input = @{
                            downloadLabel = 'Movie'
                        }
                    }
                }

                $result = Resolve-SAOpenSubtitlesImdbId -Context $context -MovieHash 'hash4' -VideoFileName 'Some.Movie.2024.mkv'

                $result | Should -Be '2222222'
            }
        }
    }
}
