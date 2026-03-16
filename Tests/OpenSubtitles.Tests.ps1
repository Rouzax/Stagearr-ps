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

Describe 'Test-SAUploadableSubtitle' {

    Context 'Filename blocklist' {

        It 'should reject _unpack (case-insensitive)' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName '_Unpack' -LabelType 'tv'
                $result.Allowed | Should -BeFalse
                $result.Reason | Should -Match 'generic filename'
            }
        }

        It 'should reject "video"' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'video' -LabelType 'movie'
                $result.Allowed | Should -BeFalse
                $result.Reason | Should -Match 'generic filename'
            }
        }

        It 'should reject "output"' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'Output' -LabelType 'movie'
                $result.Allowed | Should -BeFalse
                $result.Reason | Should -Match 'generic filename'
            }
        }

        It 'should reject single-character names' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'a' -LabelType 'tv'
                $result.Allowed | Should -BeFalse
                $result.Reason | Should -Match 'generic filename'
            }
        }

        It 'should reject numeric-only names' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName '001' -LabelType 'tv'
                $result.Allowed | Should -BeFalse
                $result.Reason | Should -Match 'generic filename'
            }
        }
    }

    Context 'TV metadata validation' {

        It 'should reject TV subtitle without season/episode in filename' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'The Dinosaurs 2160p NF WEB-DL' -LabelType 'tv'
                $result.Allowed | Should -BeFalse
                $result.Reason | Should -Match 'missing episode info'
            }
        }

        It 'should allow TV subtitle with S01E01 pattern' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'The.Dinosaurs.S01E01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-BiOMA' -LabelType 'tv'
                $result.Allowed | Should -BeTrue
            }
        }

        It 'should allow TV subtitle with s01e01 lowercase pattern' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'show.s01e01.720p' -LabelType 'tv'
                $result.Allowed | Should -BeTrue
            }
        }

        It 'should allow TV subtitle with 1x01 pattern' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'Show.1x01.720p' -LabelType 'tv'
                $result.Allowed | Should -BeTrue
            }
        }
    }

    Context 'Movie metadata validation' {

        It 'should reject movie subtitle with single-word name and no year' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'Dinosaurs' -LabelType 'movie'
                $result.Allowed | Should -BeFalse
                $result.Reason | Should -Match 'unparseable title'
            }
        }

        It 'should allow movie subtitle with multi-word title' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'The.Dinosaurs.2024.1080p.BluRay-GROUP' -LabelType 'movie'
                $result.Allowed | Should -BeTrue
            }
        }

        It 'should allow movie subtitle with title and year' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'Gladiator.2000.1080p' -LabelType 'movie'
                $result.Allowed | Should -BeTrue
            }
        }
    }

    Context 'Passthrough label type' {

        It 'should reject passthrough content (unknown label)' {
            InModuleScope 'Stagearr.Core' {
                $result = Test-SAUploadableSubtitle -VideoBaseName 'Some.File.720p' -LabelType 'passthrough'
                $result.Allowed | Should -BeFalse
                $result.Reason | Should -Match 'unknown content type'
            }
        }
    }
}

Describe 'Start-SAOpenSubtitlesUpload guard integration' {

    Context 'Diagnostic mode' {

        It 'should not call XML-RPC login in diagnostic mode' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Get-SAPluralForm { return 'subtitle' }
                Mock Get-SALabelType { return 'tv' }
                Mock Connect-SAOpenSubtitlesXmlRpc {}
                Mock Resolve-SAOpenSubtitlesImdbId { return '' }
                Mock Test-SAUploadableSubtitle { return [PSCustomObject]@{ Allowed = $true; Reason = '' } }
                Mock Test-SAOpenSubtitlesSubtitleExists { return $false }

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                uploadDiagnosticMode = $true
                            }
                        }
                    }
                    State = @{
                        ProcessingLabel = 'TV'
                    }
                }

                $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) (New-Guid)
                New-Item -ItemType Directory -Path $tmpDir | Out-Null
                $srtPath = Join-Path $tmpDir 'Show.S01E01.en.srt'
                Set-Content -Path $srtPath -Value 'test'

                try {
                    $result = Start-SAOpenSubtitlesUpload -Context $context -SubtitlePaths @($srtPath) `
                        -VideoHashMap @{ 'Show.S01E01' = 'abc123' } `
                        -VideoSizeMap @{ 'Show.S01E01' = [long]1000 }

                    Should -Invoke Connect-SAOpenSubtitlesXmlRpc -Times 0
                    $result.UploadedCount | Should -Be 1
                } finally {
                    Remove-Item $tmpDir -Recurse -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'Blocked filenames' {

        It 'should skip upload and warn for _unpack subtitle' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Get-SAPluralForm { return 'subtitle' }
                Mock Get-SALabelType { return 'tv' }
                Mock Connect-SAOpenSubtitlesXmlRpc { return 'token' }
                Mock Resolve-SAOpenSubtitlesImdbId { return '' }

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                uploadDiagnosticMode = $false
                            }
                        }
                    }
                    State = @{
                        ProcessingLabel = 'TV'
                    }
                }

                $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) (New-Guid)
                New-Item -ItemType Directory -Path $tmpDir | Out-Null
                $srtPath = Join-Path $tmpDir '_unpack.en.srt'
                Set-Content -Path $srtPath -Value 'test'

                try {
                    $result = Start-SAOpenSubtitlesUpload -Context $context -SubtitlePaths @($srtPath) `
                        -VideoHashMap @{ '_unpack' = 'abc123' } `
                        -VideoSizeMap @{ '_unpack' = [long]1000 }

                    $result.UploadedCount | Should -Be 0
                    $result.FailedCount | Should -Be 1
                    Should -Invoke Write-SAOutcome -ParameterFilter { $Level -eq 'Warning' -and $Text -match 'generic filename' }
                } finally {
                    Remove-Item $tmpDir -Recurse -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'Upload exclude list' {

        It 'should skip upload when IMDB ID matches uploadExclude' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Get-SAPluralForm { return 'subtitle' }
                Mock Get-SALabelType { return 'tv' }
                Mock Connect-SAOpenSubtitlesXmlRpc {}
                Mock Resolve-SAOpenSubtitlesImdbId { return '' }
                Mock Test-SAUploadableSubtitle { return [PSCustomObject]@{ Allowed = $true; Reason = '' } }
                Mock Test-SAOpenSubtitlesSubtitleExists { return $false }
                Mock Start-Sleep {}

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                uploadDiagnosticMode = $true
                                uploadExclude = @('tt2140481')
                            }
                        }
                    }
                    State = @{
                        ProcessingLabel = 'TV'
                        OmdbData = @{
                            ImdbId = 'tt2140481'
                            Title = 'Last Week Tonight with John Oliver'
                        }
                    }
                }

                $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) (New-Guid)
                New-Item -ItemType Directory -Path $tmpDir | Out-Null
                $srtPath = Join-Path $tmpDir 'Show.S01E01.en.srt'
                Set-Content -Path $srtPath -Value 'test'

                try {
                    $result = Start-SAOpenSubtitlesUpload -Context $context -SubtitlePaths @($srtPath) `
                        -VideoHashMap @{ 'Show.S01E01' = 'abc123' } `
                        -VideoSizeMap @{ 'Show.S01E01' = [long]1000 }

                    $result.UploadedCount | Should -Be 0
                    $result.DuplicateCount | Should -Be 0
                    $result.FailedCount | Should -Be 0
                    Should -Invoke Test-SAOpenSubtitlesSubtitleExists -Times 0
                } finally {
                    Remove-Item $tmpDir -Recurse -ErrorAction SilentlyContinue
                }
            }
        }

        It 'should skip upload when title matches uploadExclude (case-insensitive)' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Get-SAPluralForm { return 'subtitle' }
                Mock Get-SALabelType { return 'tv' }
                Mock Connect-SAOpenSubtitlesXmlRpc {}
                Mock Resolve-SAOpenSubtitlesImdbId { return '' }
                Mock Test-SAUploadableSubtitle { return [PSCustomObject]@{ Allowed = $true; Reason = '' } }
                Mock Test-SAOpenSubtitlesSubtitleExists { return $false }
                Mock Start-Sleep {}

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                uploadDiagnosticMode = $true
                                uploadExclude = @('last week tonight with john oliver')
                            }
                        }
                    }
                    State = @{
                        ProcessingLabel = 'TV'
                        OmdbData = @{
                            ImdbId = 'tt2140481'
                            Title = 'Last Week Tonight with John Oliver'
                        }
                    }
                }

                $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) (New-Guid)
                New-Item -ItemType Directory -Path $tmpDir | Out-Null
                $srtPath = Join-Path $tmpDir 'Show.S01E01.en.srt'
                Set-Content -Path $srtPath -Value 'test'

                try {
                    $result = Start-SAOpenSubtitlesUpload -Context $context -SubtitlePaths @($srtPath) `
                        -VideoHashMap @{ 'Show.S01E01' = 'abc123' } `
                        -VideoSizeMap @{ 'Show.S01E01' = [long]1000 }

                    $result.UploadedCount | Should -Be 0
                    Should -Invoke Test-SAOpenSubtitlesSubtitleExists -Times 0
                } finally {
                    Remove-Item $tmpDir -Recurse -ErrorAction SilentlyContinue
                }
            }
        }

        It 'should proceed with upload when no exclude match' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Get-SAPluralForm { return 'subtitle' }
                Mock Get-SALabelType { return 'tv' }
                Mock Connect-SAOpenSubtitlesXmlRpc {}
                Mock Resolve-SAOpenSubtitlesImdbId { return '' }
                Mock Test-SAUploadableSubtitle { return [PSCustomObject]@{ Allowed = $true; Reason = '' } }
                Mock Test-SAOpenSubtitlesSubtitleExists { return $false }
                Mock Start-Sleep {}

                $context = @{
                    Config = @{
                        subtitles = @{
                            openSubtitles = @{
                                uploadDiagnosticMode = $true
                                uploadExclude = @('tt9999999', 'Some Other Show')
                            }
                        }
                    }
                    State = @{
                        ProcessingLabel = 'TV'
                        OmdbData = @{
                            ImdbId = 'tt2140481'
                            Title = 'Last Week Tonight with John Oliver'
                        }
                    }
                }

                $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) (New-Guid)
                New-Item -ItemType Directory -Path $tmpDir | Out-Null
                $srtPath = Join-Path $tmpDir 'Show.S01E01.en.srt'
                Set-Content -Path $srtPath -Value 'test'

                try {
                    $result = Start-SAOpenSubtitlesUpload -Context $context -SubtitlePaths @($srtPath) `
                        -VideoHashMap @{ 'Show.S01E01' = 'abc123' } `
                        -VideoSizeMap @{ 'Show.S01E01' = [long]1000 }

                    # Should proceed. Diagnostic mode counts as uploaded.
                    $result.UploadedCount | Should -Be 1
                } finally {
                    Remove-Item $tmpDir -Recurse -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
