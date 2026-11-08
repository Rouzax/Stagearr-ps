BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SAKodiPathMap' {
    It 'accepts the plain string a one-entry TOML array unrolls to' {
        InModuleScope 'Stagearr.Core' {
            $map = @(Get-SAKodiPathMap -PathMap 'D:\Data\|smb://SERVER/Data/')
            $map | Should -HaveCount 1
            $map[0].From | Should -Be 'D:\Data\'
            $map[0].To | Should -Be 'smb://SERVER/Data/'
        }
    }

    It 'reads an array of entries' {
        InModuleScope 'Stagearr.Core' {
            @(Get-SAKodiPathMap -PathMap @('D:\A\|smb://h/A/', 'E:\B\|smb://h/B/')) | Should -HaveCount 2
        }
    }

    It 'drops malformed entries' -ForEach @(
        @{ Entry = 'nopipe' }
        @{ Entry = '|smb://h/' }
        @{ Entry = 'D:\A\|' }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Entry = $Entry } {
            param($Entry)
            @(Get-SAKodiPathMap -PathMap $Entry) | Should -HaveCount 0
        }
    }

    It 'strips quotes kept by single-quoted TOML items' {
        InModuleScope 'Stagearr.Core' {
            $map = @(Get-SAKodiPathMap -PathMap "'D:\A\|smb://h/A/'")
            $map[0].From | Should -Be 'D:\A\'
            $map[0].To | Should -Be 'smb://h/A/'
        }
    }

    It 'returns nothing for an empty map' {
        InModuleScope 'Stagearr.Core' {
            @(Get-SAKodiPathMap -PathMap $null) | Should -HaveCount 0
            @(Get-SAKodiPathMap -PathMap @()) | Should -HaveCount 0
        }
    }
}

Describe 'ConvertTo-SAKodiPath' {
    BeforeAll {
        $script:map = @([pscustomobject]@{ From = 'D:\Data\'; To = 'smb://SERVER/Data/' })
    }

    It 'splits a mapped title root into parent and leaf' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Map = $script:map } {
            param($Map)
            $r = ConvertTo-SAKodiPath -ArrPath 'D:\Data\Movies\Boiúna (2026)' -PathMap $Map
            $r.Parent | Should -Be 'smb://SERVER/Data/Movies/'
            $r.Leaf | Should -Be 'Boiúna (2026)'
        }
    }

    It 'ignores prefix case and a trailing separator on the Arr path' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Map = $script:map } {
            param($Map)
            $r = ConvertTo-SAKodiPath -ArrPath 'd:\data\TVSeries\EN\Show (2020)\' -PathMap $Map
            $r.Parent | Should -Be 'smb://SERVER/Data/TVSeries/EN/'
            $r.Leaf | Should -Be 'Show (2020)'
        }
    }

    It 'matches on a path boundary only' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Map = $script:map } {
            param($Map)
            ConvertTo-SAKodiPath -ArrPath 'D:\Data2\Movies\X (2020)' -PathMap $Map | Should -BeNullOrEmpty
        }
    }

    It 'treats a map entry without a trailing separator the same' {
        InModuleScope 'Stagearr.Core' {
            $m = @([pscustomobject]@{ From = 'D:\Data'; To = 'smb://SERVER/Data' })
            (ConvertTo-SAKodiPath -ArrPath 'D:\Data\Movies\X (2020)' -PathMap $m).Parent | Should -Be 'smb://SERVER/Data/Movies/'
            ConvertTo-SAKodiPath -ArrPath 'D:\Data2\Movies\X (2020)' -PathMap $m | Should -BeNullOrEmpty
        }
    }

    It 'returns nothing for an unmapped path' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Map = $script:map } {
            param($Map)
            ConvertTo-SAKodiPath -ArrPath 'E:\Other\X' -PathMap $Map | Should -BeNullOrEmpty
        }
    }

    It 'prefers the longest matching prefix' {
        InModuleScope 'Stagearr.Core' {
            $m = @(
                [pscustomobject]@{ From = 'D:\Data\'; To = 'smb://a/' }
                [pscustomobject]@{ From = 'D:\Data\Movies\'; To = 'smb://b/films/' }
            )
            (ConvertTo-SAKodiPath -ArrPath 'D:\Data\Movies\X (2020)' -PathMap $m).Parent | Should -Be 'smb://b/films/'
        }
    }

    It 'handles forward-slash Arr paths' {
        InModuleScope 'Stagearr.Core' {
            $m = @([pscustomobject]@{ From = '/mnt/data/'; To = 'smb://h/Data/' })
            $r = ConvertTo-SAKodiPath -ArrPath '/mnt/data/Movies/X (2020)' -PathMap $m
            $r.Parent | Should -Be 'smb://h/Data/Movies/'
            $r.Leaf | Should -Be 'X (2020)'
        }
    }

    It 'refuses the mapped root itself, which is not a title folder' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Map = $script:map } {
            param($Map)
            ConvertTo-SAKodiPath -ArrPath 'D:\Data' -PathMap $Map | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-SAKodiConfig' {
    It 'reports a blank host' {
        InModuleScope 'Stagearr.Core' {
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = ''; pathMap = @() } }) | Should -HaveCount 1
        }
    }

    It 'does not require a path map' {
        InModuleScope 'Stagearr.Core' {
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = 'htpc'; pathMap = @() } }) | Should -HaveCount 0
        }
    }

    It 'reports a path map entry it cannot read' {
        InModuleScope 'Stagearr.Core' {
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = 'htpc'; pathMap = @('nopipe') } }) | Should -HaveCount 1
        }
    }

    It 'passes a valid config' {
        InModuleScope 'Stagearr.Core' {
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = 'htpc'; pathMap = 'D:\|smb://h/' } }) | Should -HaveCount 0
        }
    }
}

Describe 'Test-SAFeatureEnabled Kodi' {
    It 'is off by default and on when enabled' {
        InModuleScope 'Stagearr.Core' {
            Test-SAFeatureEnabled -Feature 'Kodi' -Config @{} | Should -BeFalse
            Test-SAFeatureEnabled -Feature 'Kodi' -Config $script:SAConfigDefaults | Should -BeFalse
            Test-SAFeatureEnabled -Feature 'Kodi' -Config @{ kodi = @{ enabled = $true } } | Should -BeTrue
        }
    }
}

Describe 'Invoke-SAKodiRpc' {
    BeforeAll {
        $script:okResult = [pscustomobject]@{ Success = $true; StatusCode = 200; Data = [pscustomobject]@{ result = 'OK' }; ErrorMessage = $null }
    }

    It 'posts once with charset and no retries' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Ok = $script:okResult } {
            param($Ok)
            Mock Invoke-SAWebRequest { $Ok }
            $r = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 8080; ssl = $false; username = ''; password = '' } } -Method 'JSONRPC.Ping'
            $r.Success | Should -BeTrue
            $r.Result | Should -Be 'OK'
            Should -Invoke Invoke-SAWebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'http://h:8080/jsonrpc' -and $Method -eq 'POST' -and $MaxRetries -eq 1 -and
                $ContentType -eq 'application/json; charset=utf-8' -and -not $Headers.ContainsKey('Authorization')
            }
        }
    }

    It 'adds basic auth only with a username, and uses https with ssl' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Ok = $script:okResult } {
            param($Ok)
            Mock Invoke-SAWebRequest { $Ok }
            $null = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 443; ssl = $true; username = 'kodi'; password = 'pw' } } -Method 'JSONRPC.Ping'
            $expected = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('kodi:pw'))
            Should -Invoke Invoke-SAWebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://h:443/jsonrpc' -and $Headers['Authorization'] -eq $expected
            }
        }
    }

    It 'sends non-ASCII parameters as a JSON string that round-trips' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Ok = $script:okResult } {
            param($Ok)
            Mock Invoke-SAWebRequest { $Ok }
            $null = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80 } } -Method 'VideoLibrary.Scan' -Params @{ directory = 'smb://h/Boiúna (2026)/' }
            Should -Invoke Invoke-SAWebRequest -Times 1 -ParameterFilter {
                $Body -is [string] -and ($Body | ConvertFrom-Json).params.directory -eq 'smb://h/Boiúna (2026)/'
            }
        }
    }

    It 'treats a JSON-RPC error inside HTTP 200 as a failure, not an outage' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAWebRequest {
                [pscustomobject]@{ Success = $true; StatusCode = 200; Data = [pscustomobject]@{ error = [pscustomobject]@{ code = -32602; message = 'Invalid params.' } } }
            }
            $r = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80 } } -Method 'X'
            $r.Success | Should -BeFalse
            $r.Unreachable | Should -BeFalse
            $r.ErrorMessage | Should -Match 'Invalid params'
        }
    }

    It 'flags a transport failure as unreachable' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAWebRequest { [pscustomobject]@{ Success = $false; StatusCode = $null; Data = $null; ErrorMessage = 'No such host' } }
            $r = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80 } } -Method 'X'
            $r.Success | Should -BeFalse
            $r.Unreachable | Should -BeTrue
        }
    }

    It 'marks a 401 as rejected' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAWebRequest { [pscustomobject]@{ Success = $false; StatusCode = 401; Data = $null; ErrorMessage = 'HTTP 401' } }
            (Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80 } } -Method 'X').Rejected | Should -BeTrue
        }
    }

    It 'reports 401 as an authentication failure, not an outage' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAWebRequest { [pscustomobject]@{ Success = $false; StatusCode = 401; Data = $null; ErrorMessage = 'HTTP 401' } }
            $r = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80 } } -Method 'X'
            $r.Unreachable | Should -BeFalse
            $r.ErrorMessage | Should -Match 'authentication'
        }
    }

    It 'never throws' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAWebRequest { throw 'boom' }
            $r = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80 } } -Method 'X'
            $r.Success | Should -BeFalse
            $r.Unreachable | Should -BeTrue
        }
    }
}

Describe 'Get-SAKodiTargets' {
    BeforeAll {
        $script:movieFile = {
            param($Id, $Path, $Title)
            [pscustomobject]@{ movie = [pscustomobject]@{ id = $Id; path = $Path; title = $Title } }
        }
        $script:episodeFile = {
            param($SeriesPath, $Season, $Episode, $EpisodeId)
            [pscustomobject]@{
                series   = [pscustomobject]@{ id = 1; path = $SeriesPath; title = 'Show' }
                episodes = @([pscustomobject]@{ id = $EpisodeId; seasonNumber = $Season; episodeNumber = $Episode })
            }
        }
    }

    It 'gives one target for one movie' {
        InModuleScope 'Stagearr.Core' -Parameters @{ F = (& $script:movieFile 5 'D:\M\A (2020)' 'A') } {
            param($F)
            $t = @(Get-SAKodiTargets -ImportableFiles @($F) -AppType 'Radarr' -Verification $null)
            $t | Should -HaveCount 1
            $t[0].RootPath | Should -Be 'D:\M\A (2020)'
            $t[0].Title | Should -Be 'A'
            $t[0].MediaType | Should -Be 'movie'
            $t[0].Verified | Should -BeFalse
        }
    }

    It 'gives each movie in a pack its own target, in order' {
        InModuleScope 'Stagearr.Core' -Parameters @{ A = (& $script:movieFile 5 'D:\M\A' 'A'); B = (& $script:movieFile 6 'D:\M\B' 'B') } {
            param($A, $B)
            $t = @(Get-SAKodiTargets -ImportableFiles @($A, $B) -AppType 'Radarr' -Verification $null)
            ($t.RootPath -join ',') | Should -Be 'D:\M\A,D:\M\B'
        }
    }

    It 'ignores a file with no title but keeps the others' {
        InModuleScope 'Stagearr.Core' -Parameters @{ A = (& $script:movieFile 5 'D:\M\A' 'A') } {
            param($A)
            $t = @(Get-SAKodiTargets -ImportableFiles @([pscustomobject]@{ path = 'x' }, $A) -AppType 'Radarr' -Verification $null)
            $t | Should -HaveCount 1
            $t[0].RootPath | Should -Be 'D:\M\A'
        }
    }

    It 'merges a season pack into one target with every episode' {
        InModuleScope 'Stagearr.Core' -Parameters @{ E1 = (& $script:episodeFile 'D:\T\S' 1 1 11); E2 = (& $script:episodeFile 'D:\T\S' 1 2 12) } {
            param($E1, $E2)
            $t = @(Get-SAKodiTargets -ImportableFiles @($E1, $E2) -AppType 'Sonarr' -Verification $null)
            $t | Should -HaveCount 1
            $t[0].MediaType | Should -Be 'tv'
            @($t[0].Episodes) | Should -HaveCount 2
        }
    }

    It 'merges roots that differ only in case' {
        InModuleScope 'Stagearr.Core' -Parameters @{ E1 = (& $script:episodeFile 'D:\T\S' 1 1 11); E2 = (& $script:episodeFile 'd:\t\s' 1 2 12) } {
            param($E1, $E2)
            @(Get-SAKodiTargets -ImportableFiles @($E1, $E2) -AppType 'Sonarr' -Verification $null) | Should -HaveCount 1
        }
    }

    It 'keeps two shows with the same episode number apart' {
        InModuleScope 'Stagearr.Core' -Parameters @{ E1 = (& $script:episodeFile 'D:\T\A' 1 1 11); E2 = (& $script:episodeFile 'D:\T\B' 1 1 21) } {
            param($E1, $E2)
            $t = @(Get-SAKodiTargets -ImportableFiles @($E1, $E2) -AppType 'Sonarr' -Verification $null)
            $t | Should -HaveCount 2
            @($t[0].Episodes) | Should -HaveCount 1
            @($t[1].Episodes) | Should -HaveCount 1
        }
    }

    It 'drops episodes history does not confirm and marks the target verified' {
        InModuleScope 'Stagearr.Core' -Parameters @{ E1 = (& $script:episodeFile 'D:\T\S' 1 1 11); E2 = (& $script:episodeFile 'D:\T\S' 1 2 12) } {
            param($E1, $E2)
            $v = [pscustomobject]@{ Records = @([pscustomobject]@{ episodeId = 12 }) }
            $t = @(Get-SAKodiTargets -ImportableFiles @($E1, $E2) -AppType 'Sonarr' -Verification $v)
            $t[0].Verified | Should -BeTrue
            @($t[0].Episodes) | Should -HaveCount 1
            $t[0].Episodes[0].Episode | Should -Be 2
        }
    }

    It 'drops a movie history does not confirm' {
        InModuleScope 'Stagearr.Core' -Parameters @{ A = (& $script:movieFile 5 'D:\M\A' 'A'); B = (& $script:movieFile 6 'D:\M\B' 'B') } {
            param($A, $B)
            $v = [pscustomobject]@{ Records = @([pscustomobject]@{ movieId = 6 }) }
            $t = @(Get-SAKodiTargets -ImportableFiles @($A, $B) -AppType 'Radarr' -Verification $v)
            $t | Should -HaveCount 1
            $t[0].Title | Should -Be 'B'
            $t[0].Verified | Should -BeTrue
        }
    }

    It 'keeps everything unverified when records carry no usable ids' {
        InModuleScope 'Stagearr.Core' -Parameters @{ A = (& $script:movieFile 5 'D:\M\A' 'A') } {
            param($A)
            $v = [pscustomobject]@{ Records = @([pscustomobject]@{ eventType = 'x' }) }
            $t = @(Get-SAKodiTargets -ImportableFiles @($A) -AppType 'Radarr' -Verification $v)
            $t | Should -HaveCount 1
            $t[0].Verified | Should -BeFalse
        }
    }

    It 'gives up quietly rather than failing a finished import' {
        InModuleScope 'Stagearr.Core' {
            $bad = [pscustomobject]@{ movie = [pscustomobject]@{ id = 1; path = 42; title = 'A' } }
            { Get-SAKodiTargets -ImportableFiles @($bad) -AppType 'Radarr' -Verification $null } | Should -Not -Throw
            @(Get-SAKodiTargets -ImportableFiles @($bad) -AppType 'Radarr' -Verification $null) | Should -HaveCount 0
        }
    }

    It 'returns nothing for no files' {
        InModuleScope 'Stagearr.Core' {
            @(Get-SAKodiTargets -ImportableFiles $null -AppType 'Radarr' -Verification $null) | Should -HaveCount 0
        }
    }
}

Describe 'Get-SAKodiBudgetSeconds' {
    It 'scales with items and is capped' {
        InModuleScope 'Stagearr.Core' {
            Get-SAKodiBudgetSeconds -ItemCount 1 -TitleCount 1 | Should -Be 125
            Get-SAKodiBudgetSeconds -ItemCount 20 -TitleCount 1 | Should -Be 220
            Get-SAKodiBudgetSeconds -ItemCount 5000 -TitleCount 1 | Should -Be 600
        }
    }
}

Describe 'Get-SAKodiBudgetSeconds per title' {
    It 'allows each extra title its own scan and clean' {
        InModuleScope 'Stagearr.Core' {
            Get-SAKodiBudgetSeconds -ItemCount 10 -TitleCount 10 | Should -Be 440
        }
    }
}

Describe 'Invoke-SAKodiUpdate' {
    BeforeAll {
        $script:config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = 'D:\Data\|smb://S/Data/' } }
        $script:movie = [pscustomobject]@{ RootPath = 'D:\Data\Movies\Film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $script:show = [pscustomobject]@{
            RootPath = 'D:\Data\TV\Show (2020)'; Title = 'Show'; MediaType = 'tv'; Verified = $true
            Episodes = @([pscustomobject]@{ Season = 1; Episode = 1 }, [pscustomobject]@{ Season = 1; Episode = 2 })
        }

        # Scripted Kodi. BusyQueue feeds successive idle checks, then the value stays false.
        function script:New-FakeKodi {
            $global:FakeKodi = @{
                Calls       = [System.Collections.Generic.List[object]]::new()
                BusyQueue   = [System.Collections.Generic.Queue[bool]]::new()
                Listing     = @{ 'smb://S/Data/Movies/' = @('smb://S/Data/Movies/Film (2020)/'); 'smb://S/Data/TV/' = @('smb://S/Data/TV/Show (2020)/') }
                MovieTotal  = 1
                Episodes    = @(@{ season = 1; episode = 1 }, @{ season = 1; episode = 2 })
                Unreachable = $false
                OnScan      = $null
                ListingFail = $null
                ListingType = 'directory'
                ListingFailFor = $null
                ScanFail    = $null
                Sources     = @('/media/', 'smb://S/Data/Movies/', 'smb://S/Data/TV/')
                SourcesFail = $null
            }
        }

        function global:Invoke-FakeKodi {
            param($Method, $Params)
            $k = $global:FakeKodi
            $k.Calls.Add([pscustomobject]@{ Method = $Method; Params = $Params })
            if ($k.Unreachable) {
                return [pscustomobject]@{ Success = $false; Result = $null; Unreachable = $true; ErrorMessage = 'No route' }
            }
            if ($Method -eq 'Files.GetDirectory' -and $k.ListingFail) {
                return $k.ListingFail
            }
            if ($Method -eq 'Files.GetDirectory' -and $Params.directory -eq $k.ListingFailFor) {
                return [pscustomobject]@{ Success = $false; Result = $null; Unreachable = $false; Rejected = $false; ErrorMessage = 'Kodi returned an error: Invalid params.' }
            }
            if ($Method -eq 'Files.GetSources' -and $k.SourcesFail) {
                return $k.SourcesFail
            }
            if ($Method -eq 'VideoLibrary.Scan' -and $k.ScanFail) {
                return $k.ScanFail
            }
            $result = switch ($Method) {
                'XBMC.GetInfoBooleans' {
                    $busy = if ($k.BusyQueue.Count -gt 0) { $k.BusyQueue.Dequeue() } else { $false }
                    [pscustomobject]@{ 'Library.IsScanningVideo' = $busy }
                }
                'Files.GetSources' {
                    [pscustomobject]@{ sources = @($k.Sources | ForEach-Object { [pscustomobject]@{ file = $_; label = 'x' } }) }
                }
                'Files.GetDirectory' {
                    [pscustomobject]@{ files = @($k.Listing[$Params.directory] | ForEach-Object { [pscustomobject]@{ file = $_; filetype = $k.ListingType } }) }
                }
                'VideoLibrary.Scan' {
                    if ($k.OnScan) { & $k.OnScan }
                    'OK'
                }
                'VideoLibrary.GetMovies' { [pscustomobject]@{ limits = [pscustomobject]@{ total = $k.MovieTotal } } }
                'VideoLibrary.GetEpisodes' {
                    [pscustomobject]@{ episodes = @($k.Episodes | ForEach-Object { [pscustomobject]$_ }) }
                }
            }
            return [pscustomobject]@{ Success = $true; Result = $result; Unreachable = $false; ErrorMessage = $null }
        }
    }

    BeforeEach {
        New-FakeKodi
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiRpc { Invoke-FakeKodi -Method $Method -Params $Params }
        Mock -ModuleName 'Stagearr.Core' Start-Sleep {}
        $global:FakeClock = 0
        Mock -ModuleName 'Stagearr.Core' Get-SAKodiElapsedSeconds { $global:FakeClock += 2; $global:FakeClock }
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
    }

    AfterAll {
        Remove-Variable -Name FakeKodi, FakeClock -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -Path Function:\global:Invoke-FakeKodi -ErrorAction SilentlyContinue
    }

    It 'scans the exact path Kodi listed, ending in a slash' {
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Updated'
        $scan = @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan')
        $scan | Should -HaveCount 1
        $scan[0].Params.directory | Should -Be 'smb://S/Data/Movies/Film (2020)/'
        $scan[0].Params.showdialogs | Should -BeFalse
    }

    It 'uses the spelling and slash from the listing, not the Arr path' {
        $global:FakeKodi.Listing['smb://S/Data/Movies/'] = @('smb://S/Data/Movies/FILM (2020)')
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        (@($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan'))[0].Params.directory | Should -Be 'smb://S/Data/Movies/FILM (2020)/'
    }

    It 'waits for Kodi to go idle before scanning' {
        $global:FakeKodi.BusyQueue.Enqueue($true)
        $global:FakeKodi.BusyQueue.Enqueue($true)
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $methods = @($global:FakeKodi.Calls.Method | Where-Object { $_ -in 'XBMC.GetInfoBooleans', 'VideoLibrary.Scan' })
        ($methods | Where-Object { $_ -eq 'VideoLibrary.Scan' }) | Should -HaveCount 1
        $methods[[array]::IndexOf($methods, 'VideoLibrary.Scan') - 1] | Should -Be 'XBMC.GetInfoBooleans'
        [array]::IndexOf($methods, 'VideoLibrary.Scan') | Should -BeGreaterThan 2
    }

    It 'skips without scanning when Kodi stays busy past the budget' {
        1..1000 | ForEach-Object { $global:FakeKodi.BusyQueue.Enqueue($true) }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'until a scan runs'
        $r.Text | Should -Match 'time limit'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 0
    }

    It 'starts no new scan once the budget is spent' {
        Mock -ModuleName 'Stagearr.Core' Get-SAKodiBudgetSeconds { 6 }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; A = $script:movie; B = $script:show } { param($C, $A, $B) Invoke-SAKodiUpdate -Config $C -Targets @($A, $B) }
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 1
        $r.Status | Should -Be 'Updated'
        $r.Summary | Should -Be 'Scanned and confirmed'
        $r.Text | Should -Match 'Show: .*time limit'
    }

    It 'does not call a scan confirmed when the request got no answer' {
        $global:FakeKodi.ScanFail = [pscustomobject]@{ Success = $false; Result = $null; Unreachable = $true; Rejected = $false; ErrorMessage = 'timeout' }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'did not answer the scan request'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.GetMovies') | Should -HaveCount 0
        $global:FakeKodi.ScanFail = $null
        (InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }).Status | Should -Be 'Updated'
    }

    It 'ignores a file named like the title folder' {
        $global:FakeKodi.ListingType = 'file'
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 0
    }

    It 'names every title left unscanned when Kodi drops out' {
        $global:FakeKodi.Unreachable = $true
        $c = [pscustomobject]@{ RootPath = 'D:\Data\Movies\Third (2020)'; Title = 'Third'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; A = $script:movie; B = $script:show; D = $c } { param($C, $A, $B, $D) Invoke-SAKodiUpdate -Config $C -Targets @($A, $B, $D) }
        $r.Text | Should -Match 'Film'
        $r.Text | Should -Match 'Show'
        $r.Text | Should -Match 'Third'
    }

    It 'checks the library only after an upgrade scan has gone idle' {
        # The old entry satisfies a path check before the scan has done anything.
        $global:FakeKodi.OnScan = { 1..3 | ForEach-Object { $global:FakeKodi.BusyQueue.Enqueue($true) } }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Updated'
        $methods = @($global:FakeKodi.Calls.Method)
        $afterScan = $methods[([array]::IndexOf($methods, 'VideoLibrary.Scan') + 1)..($methods.Count - 1)]
        ($afterScan -join ',') | Should -Be 'XBMC.GetInfoBooleans,XBMC.GetInfoBooleans,XBMC.GetInfoBooleans,XBMC.GetInfoBooleans,VideoLibrary.GetMovies'
    }

    It 'does not judge the library while Kodi is still busy after the scan' {
        $global:FakeKodi.OnScan = { 1..1000 | ForEach-Object { $global:FakeKodi.BusyQueue.Enqueue($true) } }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'still busy'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.GetMovies') | Should -HaveCount 0
    }

    It 'still verifies when a scan is never seen as busy' {
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Updated'
    }

    It 'reports a movie that never appears' {
        $global:FakeKodi.MovieTotal = 0
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Partial'
        $r.Missing | Should -Contain 'Film'
    }

    It 'names the episodes that never appear' {
        $global:FakeKodi.Episodes = @(@{ season = 1; episode = 1 })
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:show } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Partial'
        $r.Missing | Should -Contain 'Show S01E02'
        $r.Missing | Should -Not -Contain 'Show S01E01'
        $r.Text | Should -Match 'S01E02'
        $r.Text | Should -Not -Match 'S01E01'
    }

    It 'says when a missing item was never confirmed as imported' {
        $global:FakeKodi.MovieTotal = 0
        $t = [pscustomobject]@{ RootPath = 'D:\Data\Movies\Film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $false }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Text | Should -Match 'may not have imported'
    }

    It 'reports a rejected login as a login problem, not a path problem' {
        $global:FakeKodi.ListingFail = [pscustomobject]@{ Success = $false; Result = $null; Unreachable = $false; Rejected = $true; ErrorMessage = 'Kodi rejected the request: authentication failed' }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'authentication'
        $r.Text | Should -Not -Match 'pathMap'
    }

    It 'keeps trying after a folder listing times out, because Kodi itself answered' {
        $global:FakeKodi.ListingFail = [pscustomobject]@{ Success = $false; Result = $null; Unreachable = $true; ErrorMessage = 'timeout' }
        $r1 = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r1.Status | Should -Be 'Skipped'
        $r1.Text | Should -Match 'did not list'
        $global:FakeKodi.ListingFail = $null
        $r2 = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r2.Status | Should -Be 'Updated'
    }

    It 'accepts an item that arrives within the grace period' {
        $global:FakeKodi.MovieTotal = 0
        $global:FakeKodi.OnScan = $null
        Mock -ModuleName 'Stagearr.Core' Start-Sleep { $global:FakeKodi.MovieTotal = 1 }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Updated'
    }

    It 'skips with no scan when Kodi cannot see the folder' {
        $global:FakeKodi.Listing['smb://S/Data/Movies/'] = @('smb://S/Data/Movies/Other (2020)/')
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'until a scan runs'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 0
    }

    It 'skips and points at pathMap when no source matches' {
        $t = [pscustomobject]@{ RootPath = 'Z:\Else\X'; Title = 'X'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'pathMap'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 0
    }

    It 'maps by itself and scans with the spelling of the Kodi source' {
        $config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = @() } }
        $t = [pscustomobject]@{ RootPath = '\\server\data\movies\film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Updated'
        (@($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan'))[0].Params.directory | Should -Be 'smb://S/Data/Movies/Film (2020)/'
    }

    It 'corrects the source spelling behind a broad pathMap entry' {
        $config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = 'D:\Data\|smb://S/data/' } }
        $t = [pscustomobject]@{ RootPath = 'D:\Data\movies\Film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        (@($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan'))[0].Params.directory | Should -Be 'smb://S/Data/Movies/Film (2020)/'
    }

    It 'lets pathMap override a source that would match by itself' {
        $global:FakeKodi.Listing['smb://S/Other/'] = @('smb://S/Other/Film (2020)/')
        $config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = 'D:\Data\Movies\|smb://S/Other/' } }
        $t = [pscustomobject]@{ RootPath = 'D:\Data\Movies\Film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        (@($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan'))[0].Params.directory | Should -Be 'smb://S/Other/Film (2020)/'
    }

    It 'uses the tied source that holds the title' {
        $global:FakeKodi.Sources = @('smb://A/Movies/', 'smb://B/Movies/')
        $global:FakeKodi.Listing['smb://A/Movies/'] = @('smb://A/Movies/Other (2020)/')
        $global:FakeKodi.Listing['smb://B/Movies/'] = @('smb://B/Movies/Film (2020)/')
        $config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = @() } }
        $t = [pscustomobject]@{ RootPath = 'D:\Movies\Film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        (@($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan'))[0].Params.directory | Should -Be 'smb://B/Movies/Film (2020)/'
    }

    It 'refuses to guess when tied sources both hold the title' {
        $global:FakeKodi.Sources = @('smb://A/Movies/', 'smb://B/Movies/')
        $global:FakeKodi.Listing['smb://A/Movies/'] = @('smb://A/Movies/Film (2020)/')
        $global:FakeKodi.Listing['smb://B/Movies/'] = @('smb://B/Movies/Film (2020)/')
        $config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = @() } }
        $t = [pscustomobject]@{ RootPath = 'D:\Movies\Film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'pathMap'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 0
    }

    It 'does not fall back to a weaker source that lacks proof' {
        $global:FakeKodi.Sources = @('smb://N/4K/Movies/', 'smb://N/HD/Movies/')
        $global:FakeKodi.Listing['smb://N/4K/Movies/'] = @()
        $global:FakeKodi.Listing['smb://N/HD/Movies/'] = @('smb://N/HD/Movies/Film/')
        $config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = @() } }
        $t = [pscustomobject]@{ RootPath = 'D:\4K\Movies\Film'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 0
    }

    It 'does not trust a tie when one listing failed' {
        $global:FakeKodi.Sources = @('smb://A/Movies/', 'smb://B/Movies/')
        $global:FakeKodi.Listing['smb://B/Movies/'] = @('smb://B/Movies/Film (2020)/')
        $global:FakeKodi.ListingFailFor = 'smb://A/Movies/'
        $config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = @() } }
        $t = [pscustomobject]@{ RootPath = 'D:\Movies\Film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 0
    }

    It 'reads the sources once for a pack' {
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; A = $script:movie; B = $script:show } { param($C, $A, $B) Invoke-SAKodiUpdate -Config $C -Targets @($A, $B) }
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'Files.GetSources') | Should -HaveCount 1
    }

    It 'still uses pathMap when the sources cannot be read' {
        $global:FakeKodi.SourcesFail = [pscustomobject]@{ Success = $false; Result = $null; Unreachable = $false; Rejected = $false; ErrorMessage = 'nope' }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Updated'
    }

    It 'skips with no calls on a config problem' {
        $bad = @{ kodi = @{ enabled = $true; host = ''; pathMap = @() } }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $bad; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $global:FakeKodi.Calls | Should -HaveCount 0
    }

    It 'stops calling an unreachable Kodi for the rest of the worker run' {
        $global:FakeKodi.Unreachable = $true
        $r1 = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r1.Status | Should -Be 'Skipped'
        $r1.Text | Should -Match 'until a scan runs'
        $first = $global:FakeKodi.Calls.Count
        $r2 = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r2.Status | Should -Be 'Skipped'
        $global:FakeKodi.Calls.Count | Should -Be $first
    }

    It 'keeps the breaker across a job state reset' {
        $global:FakeKodi.Unreachable = $true
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $first = $global:FakeKodi.Calls.Count
        InModuleScope 'Stagearr.Core' { Reset-SAJobState }
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $global:FakeKodi.Calls.Count | Should -Be $first
    }

    It 'keeps calling another Kodi host after one was unreachable' {
        $global:FakeKodi.Unreachable = $true
        $null = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $global:FakeKodi.Unreachable = $false
        $other = @{ kodi = @{ enabled = $true; host = 'h2'; port = 80; pathMap = $script:config.kodi.pathMap } }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $other; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Updated'
    }

    It 'scans each title in a pack' {
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; A = $script:movie; B = $script:show } { param($C, $A, $B) Invoke-SAKodiUpdate -Config $C -Targets @($A, $B) }
        $r.Status | Should -Be 'Updated'
        (@($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan').Params.directory) -join ',' | Should -Be 'smb://S/Data/Movies/Film (2020)/,smb://S/Data/TV/Show (2020)/'
    }

    It 'keeps the success when another title is skipped' {
        $t = [pscustomobject]@{ RootPath = 'Z:\Else\X'; Title = 'X'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; A = $script:movie; B = $t } { param($C, $A, $B) Invoke-SAKodiUpdate -Config $C -Targets @($A, $B) }
        $r.Status | Should -Be 'Updated'
        $r.Summary | Should -Be 'Scanned and confirmed'
        $r.Text | Should -Match 'until a scan runs'
    }

    It 'does nothing for no targets' {
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config } { param($C) Invoke-SAKodiUpdate -Config $C -Targets @() }
        $r.Status | Should -Be 'Idle'
        $global:FakeKodi.Calls | Should -HaveCount 0
    }
}

Describe 'Test-SAKodiStepNeeded' {
    BeforeAll {
        $script:targets = @([pscustomobject]@{ RootPath = 'D:\M\A' })
    }

    It 'runs after a good import' {
        InModuleScope 'Stagearr.Core' -Parameters @{ T = $script:targets } {
            param($T)
            Test-SAKodiStepNeeded -ImportResult ([pscustomobject]@{ Success = $true; Skipped = $false; ImportedCount = 1; KodiTargets = $T }) | Should -BeTrue
        }
    }

    It 'runs after an import reported as failed for an unknown reason, such as a timeout' {
        InModuleScope 'Stagearr.Core' -Parameters @{ T = $script:targets } {
            param($T)
            Test-SAKodiStepNeeded -ImportResult ([pscustomobject]@{ Success = $false; Skipped = $false; ErrorType = 'unknown'; KodiTargets = $T }) | Should -BeTrue
        }
    }

    It 'does not run when <Name>' -ForEach @(
        @{ Name = 'skipped'; Result = [pscustomobject]@{ Success = $true; Skipped = $true; ImportedCount = 1; UseTargets = $true } }
        @{ Name = 'quality rejected'; Result = [pscustomobject]@{ Success = $false; Skipped = $false; QualityRejected = $true; ErrorType = 'quality'; UseTargets = $true } }
        @{ Name = 'nothing was imported'; Result = [pscustomobject]@{ Success = $true; Skipped = $false; ImportedCount = 0; UseTargets = $true } }
        @{ Name = 'a failure has a known cause'; Result = [pscustomobject]@{ Success = $false; Skipped = $false; ErrorType = 'path-not-found'; UseTargets = $true } }
        @{ Name = 'Medusa imported, with no targets'; Result = [pscustomobject]@{ Success = $true; Skipped = $false; UseTargets = $false } }
    ) {
        $r = $Result
        if ($r.UseTargets) {
            $r | Add-Member -NotePropertyName KodiTargets -NotePropertyValue $script:targets -Force
        }
        InModuleScope 'Stagearr.Core' -Parameters @{ R = $r } {
            param($R)
            Test-SAKodiStepNeeded -ImportResult $R | Should -BeFalse
        }
    }

    It 'does not run without a result' {
        InModuleScope 'Stagearr.Core' {
            Test-SAKodiStepNeeded -ImportResult $null | Should -BeFalse
        }
    }
}

Describe 'Get-SAKodiPathCandidates' {
    BeforeAll {
        $script:sources = @('/media/', 'smb://SERVER/Data/Kids/TV/', 'smb://SERVER/Data/Festivals/Video/', 'smb://SERVER/Data/Sport/Video/',
            'smb://SERVER/Data/Movies/', 'smb://SERVER/Data/TVSeries/EN/', 'smb://SERVER/Data/TVSeries/NL/', 'smb://SERVER/Data/Kids/Movies/')
    }

    It 'matches <Path> to <Parent>' -ForEach @(
        @{ Path = '\\server\data\movies\Abigail (2024)'; Parent = 'smb://SERVER/Data/Movies/' }
        @{ Path = '\\server\data\kids\movies\Cars (2006)'; Parent = 'smb://SERVER/Data/Kids/Movies/' }
        @{ Path = '\\server\Data\TVSeries\EN\Reacher (2022)'; Parent = 'smb://SERVER/Data/TVSeries/EN/' }
        @{ Path = '\\server\Data\TVSeries\NL\Show (2019)'; Parent = 'smb://SERVER/Data/TVSeries/NL/' }
        @{ Path = 'D:\Data\Movies\Film (2020)'; Parent = 'smb://SERVER/Data/Movies/' }
        @{ Path = '/mnt/nas/data/kids/movies/Cars (2006)'; Parent = 'smb://SERVER/Data/Kids/Movies/' }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ P = $Path; E = $Parent; S = $script:sources } {
            param($P, $E, $S)
            $c = @(Get-SAKodiPathCandidates -ArrPath $P -Sources $S)
            $c[0].Parent | Should -Be $E
        }
    }

    It 'keeps the title folder as the leaf' {
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $script:sources } {
            param($S)
            (@(Get-SAKodiPathCandidates -ArrPath 'D:\Movies\Film (2020)\' -Sources $S))[0].Leaf | Should -Be 'Film (2020)'
        }
    }

    It 'follows folders below a source' {
        InModuleScope 'Stagearr.Core' {
            (@(Get-SAKodiPathCandidates -ArrPath 'D:\TV\EN\Show (2020)' -Sources @('smb://S/TV/')))[0].Parent | Should -Be 'smb://S/TV/EN/'
        }
    }

    It 'gives tied sources the same score' {
        InModuleScope 'Stagearr.Core' {
            $c = @(Get-SAKodiPathCandidates -ArrPath 'D:\Movies\X' -Sources @('smb://A/Movies/', 'smb://B/Movies/'))
            $c | Should -HaveCount 2
            $c[0].Score | Should -Be $c[1].Score
        }
    }

    It 'returns nothing when no folder name overlaps' {
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $script:sources } {
            param($S)
            @(Get-SAKodiPathCandidates -ArrPath 'Z:\Else\X' -Sources $S) | Should -HaveCount 0
        }
    }

    It 'matches a Windows-style Kodi source and keeps its separators' {
        InModuleScope 'Stagearr.Core' {
            (@(Get-SAKodiPathCandidates -ArrPath '\\\\nas\\media\\movies\\Film (2020)' -Sources @('D:\Media\Movies\')))[0].Parent | Should -Be 'D:\Media\Movies\'
            (@(Get-SAKodiPathCandidates -ArrPath 'E:\TV\EN\Show' -Sources @('D:\TV\')))[0].Parent | Should -Be 'D:\TV\EN\'
        }
    }

    It 'lists one candidate for sources that differ only in case' {
        InModuleScope 'Stagearr.Core' {
            @(Get-SAKodiPathCandidates -ArrPath 'D:\Movies\X' -Sources @('smb://A/Movies/', 'smb://a/movies/')) | Should -HaveCount 1
        }
    }

    It 'ignores multipath sources' {
        InModuleScope 'Stagearr.Core' {
            @(Get-SAKodiPathCandidates -ArrPath 'D:\Movies\X' -Sources @('multipath://smb%3a%2f%2fS%2fMovies%2f/')) | Should -HaveCount 0
        }
    }

    It 'needs a parent folder to compare' {
        InModuleScope 'Stagearr.Core' {
            @(Get-SAKodiPathCandidates -ArrPath 'Movies' -Sources @('smb://S/Movies/')) | Should -HaveCount 0
        }
    }
}

Describe 'Kodi pending list helpers' {
    BeforeAll {
        $script:now = [datetime]::new(2026, 11, 7, 12, 0, 0, [DateTimeKind]::Utc)
    }

    It 'merges episodes for one folder and keeps the oldest date' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Now = $script:now } {
            param($Now)
            $old = [pscustomobject]@{ RootPath = 'D:\T\S'; Title = 'S'; MediaType = 'tv'; Verified = $true; AddedAt = '2026-11-01T00:00:00.0000000Z'; Episodes = @([pscustomobject]@{ Season = 1; Episode = 1 }) }
            $new = [pscustomobject]@{ RootPath = 'd:\t\s'; Title = 'S'; MediaType = 'tv'; Verified = $true; Episodes = @([pscustomobject]@{ Season = 1; Episode = 1 }, [pscustomobject]@{ Season = 1; Episode = 2 }) }
            $m = @(Merge-SAKodiPending -Existing @($old) -Add @($new) -Now $Now)
            $m | Should -HaveCount 1
            @($m[0].Episodes) | Should -HaveCount 2
            $m[0].AddedAt | Should -Be '2026-11-01T00:00:00.0000000Z'
        }
    }

    It 'stamps new entries with the time' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Now = $script:now } {
            param($Now)
            $new = [pscustomobject]@{ RootPath = 'D:\M\A'; Title = 'A'; MediaType = 'movie'; Verified = $true; Episodes = @() }
            (@(Merge-SAKodiPending -Existing @() -Add @($new) -Now $Now))[0].AddedAt | Should -Match '^2026-11-07T12:00'
        }
    }

    It 'splits expired entries at 7 days' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Now = $script:now } {
            param($Now)
            $young = [pscustomobject]@{ RootPath = 'a'; AddedAt = '2026-11-01T00:00:00.0000000Z' }
            $aged = [pscustomobject]@{ RootPath = 'b'; AddedAt = '2026-10-30T00:00:00.0000000Z' }
            $r = Split-SAKodiPending -Entries @($young, $aged) -Now $Now
            (@($r.Keep).RootPath) | Should -Be 'a'
            (@($r.Expired).RootPath) | Should -Be 'b'
        }
    }

    It 'round-trips through the file, with a single entry and with none' {
        $root = (Join-Path $TestDrive 'q1')
        $null = New-Item -ItemType Directory -Path $root
        InModuleScope 'Stagearr.Core' -Parameters @{ Root = $root } {
            param($Root)
            $e = [pscustomobject]@{ RootPath = 'D:\M\Boiúna'; Title = 'B'; MediaType = 'tv'; Verified = $true; AddedAt = '2026-11-01T00:00:00.0000000Z'; Episodes = @([pscustomobject]@{ Season = 1; Episode = 2 }) }
            Save-SAKodiPending -QueueRoot $Root -Entries @($e) | Should -BeTrue
            $r = @(Read-SAKodiPending -QueueRoot $Root)
            $r | Should -HaveCount 1
            $r[0].RootPath | Should -Be 'D:\M\Boiúna'
            $r[0].Episodes[0].Episode | Should -Be 2
            Save-SAKodiPending -QueueRoot $Root -Entries @() | Should -BeTrue
            Test-Path (Join-Path $Root 'kodi-pending.json') | Should -BeFalse
        }
    }

    It 'throws on a corrupted file rather than reading it as empty' {
        $root = (Join-Path $TestDrive 'q2')
        $null = New-Item -ItemType Directory -Path $root
        Set-Content -Path (Join-Path $root 'kodi-pending.json') -Value '{not json'
        InModuleScope 'Stagearr.Core' -Parameters @{ Root = $root } {
            param($Root)
            { Read-SAKodiPending -QueueRoot $Root } | Should -Throw
        }
    }

    It 'ignores entries it cannot use' {
        $root = (Join-Path $TestDrive 'q3')
        $null = New-Item -ItemType Directory -Path $root
        Set-Content -Path (Join-Path $root 'kodi-pending.json') -Value '[{"RootPath":42,"Title":"x"},{"RootPath":"D:\\M\\A","Title":"A"}]'
        InModuleScope 'Stagearr.Core' -Parameters @{ Root = $root } {
            param($Root)
            @(Read-SAKodiPending -QueueRoot $Root) | Should -HaveCount 1
        }
    }

    It 'restamps an unreadable date so the entry can still expire' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Now = $script:now } {
            param($Now)
            $e = [pscustomobject]@{ RootPath = 'a'; Title = 'A'; AddedAt = 'not a date'; Episodes = @() }
            (@(Merge-SAKodiPending -Existing @($e) -Add @() -Now $Now))[0].AddedAt | Should -Match '^2026-11-07T12:00'
        }
    }
}

Describe 'Invoke-SAKodiUpdate retries' {
    BeforeAll {
        $script:config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = @() } }
        $script:movie = [pscustomobject]@{ RootPath = 'D:\Data\Movies\Film (2020)'; Title = 'Film'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $script:other = [pscustomobject]@{ RootPath = 'D:\Data\Movies\Next (2021)'; Title = 'Next'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        function script:Invoke-Update {
            param($Targets, $Root)
            InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $Targets; Q = $Root } { param($C, $T, $Q) Invoke-SAKodiUpdate -Config $C -Targets $T -QueueRoot $Q }
        }
        function script:Get-PendingRoots {
            param($Root)
            InModuleScope 'Stagearr.Core' -Parameters @{ Q = $Root } { param($Q) @(Read-SAKodiPending -QueueRoot $Q).RootPath }
        }
    }

    BeforeEach {
        New-FakeKodi
        $global:FakeKodi.Listing['smb://S/Data/Movies/'] = @('smb://S/Data/Movies/Film (2020)/', 'smb://S/Data/Movies/Next (2021)/')
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiRpc { Invoke-FakeKodi -Method $Method -Params $Params }
        Mock -ModuleName 'Stagearr.Core' Start-Sleep {}
        $global:FakeClock = 0
        Mock -ModuleName 'Stagearr.Core' Get-SAKodiElapsedSeconds { $global:FakeClock += 2; $global:FakeClock }
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
        $script:root = Join-Path $TestDrive ([guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $script:root
    }

    AfterAll {
        Remove-Variable -Name FakeKodi, FakeClock -Scope Global -ErrorAction SilentlyContinue
    }

    It 'queues a title when Kodi is unreachable and says it will retry' {
        $global:FakeKodi.Unreachable = $true
        $r = Invoke-Update -Targets @($script:movie) -Root $script:root
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'retry on the next import'
        $r.Text | Should -Not -Match 'until a scan runs'
        Get-PendingRoots -Root $script:root | Should -Be $script:movie.RootPath
    }

    It 'queues a title while the breaker is set, without calling Kodi' {
        $global:FakeKodi.Unreachable = $true
        $null = Invoke-Update -Targets @($script:movie) -Root $script:root
        $calls = $global:FakeKodi.Calls.Count
        $null = Invoke-Update -Targets @($script:other) -Root $script:root
        $global:FakeKodi.Calls.Count | Should -Be $calls
        @(Get-PendingRoots -Root $script:root) | Should -HaveCount 2
    }

    It 'queues a scan that could not be confirmed' {
        $global:FakeKodi.OnScan = { 1..1000 | ForEach-Object { $global:FakeKodi.BusyQueue.Enqueue($true) } }
        $null = Invoke-Update -Targets @($script:movie) -Root $script:root
        Get-PendingRoots -Root $script:root | Should -Be $script:movie.RootPath
    }

    It 'catches up on the next job, its own title first, and empties the list' {
        $global:FakeKodi.Unreachable = $true
        $null = Invoke-Update -Targets @($script:movie) -Root $script:root
        $global:FakeKodi.Unreachable = $false
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
        $global:FakeKodi.Calls.Clear()
        $r = Invoke-Update -Targets @($script:other) -Root $script:root
        $r.Status | Should -Be 'Updated'
        $r.Text | Should -Match 'Caught up on Film'
        (@($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan').Params.directory) -join ',' | Should -Be 'smb://S/Data/Movies/Next (2021)/,smb://S/Data/Movies/Film (2020)/'
        Test-Path (Join-Path $script:root 'kodi-pending.json') | Should -BeFalse
    }

    It 'catches up on a job with no title of its own' {
        $global:FakeKodi.Unreachable = $true
        $null = Invoke-Update -Targets @($script:movie) -Root $script:root
        $global:FakeKodi.Unreachable = $false
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
        $r = Invoke-Update -Targets @() -Root $script:root
        $r.Status | Should -Be 'Updated'
        $r.Text | Should -Match 'Caught up on Film'
    }

    It 'stays quiet when a job with no title of its own cannot clear the list' {
        $global:FakeKodi.Unreachable = $true
        $null = Invoke-Update -Targets @($script:movie) -Root $script:root
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
        $r = Invoke-Update -Targets @() -Root $script:root
        $r.Status | Should -Be 'Idle'
        Get-PendingRoots -Root $script:root | Should -Be $script:movie.RootPath
    }

    It 'leaves retries for later once the job time is spent' {
        $global:FakeKodi.Unreachable = $true
        $null = Invoke-Update -Targets @($script:movie) -Root $script:root
        $global:FakeKodi.Unreachable = $false
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
        Mock -ModuleName 'Stagearr.Core' Get-SAKodiBudgetSeconds { 4 }
        $global:FakeKodi.Calls.Clear()
        $r = Invoke-Update -Targets @($script:other) -Root $script:root
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan').Params.directory | Should -Not -Contain 'smb://S/Data/Movies/Film (2020)/'
        Get-PendingRoots -Root $script:root | Should -Be $script:movie.RootPath
    }

    It 'does not queue a title Kodi refused' {
        $global:FakeKodi.MovieTotal = 0
        $r = Invoke-Update -Targets @($script:movie) -Root $script:root
        $r.Status | Should -Be 'Partial'
        $r.Text | Should -Not -Match 'retry'
        $r.Summary | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:root 'kodi-pending.json') | Should -BeFalse
    }

    It 'does not queue a mapping problem' {
        $t = [pscustomobject]@{ RootPath = 'Z:\Else\X'; Title = 'X'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = Invoke-Update -Targets @($t) -Root $script:root
        $r.Text | Should -Match 'until a scan runs'
        Test-Path (Join-Path $script:root 'kodi-pending.json') | Should -BeFalse
    }

    It 'drops a queued title whose folder is gone, and names it' {
        $global:FakeKodi.Unreachable = $true
        $null = Invoke-Update -Targets @($script:movie) -Root $script:root
        $global:FakeKodi.Unreachable = $false
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
        $global:FakeKodi.Listing['smb://S/Data/Movies/'] = @('smb://S/Data/Movies/Next (2021)/')
        $r = Invoke-Update -Targets @($script:other) -Root $script:root
        $r.Text | Should -Match 'Film'
        Test-Path (Join-Path $script:root 'kodi-pending.json') | Should -BeFalse
    }

    It 'gives an expired entry a last try, then names it' {
        $aged = [pscustomobject]@{ RootPath = $script:movie.RootPath; Title = 'Film'; MediaType = 'movie'; Verified = $true; Episodes = @(); AddedAt = (Get-Date).ToUniversalTime().AddDays(-8).ToString('o') }
        InModuleScope 'Stagearr.Core' -Parameters @{ Q = $script:root; E = $aged } { param($Q, $E) $null = Save-SAKodiPending -QueueRoot $Q -Entries @($E) }
        $global:FakeKodi.ListingFailFor = 'smb://S/Data/Movies/'
        $r = Invoke-Update -Targets @() -Root $script:root
        $r.Text | Should -Match 'Film'
        $r.Text | Should -Match 'until a scan runs'
        Test-Path (Join-Path $script:root 'kodi-pending.json') | Should -BeFalse
    }

    It 'catches up on an expired entry if its last try works' {
        $aged = [pscustomobject]@{ RootPath = $script:movie.RootPath; Title = 'Film'; MediaType = 'movie'; Verified = $true; Episodes = @(); AddedAt = (Get-Date).ToUniversalTime().AddDays(-8).ToString('o') }
        InModuleScope 'Stagearr.Core' -Parameters @{ Q = $script:root; E = $aged } { param($Q, $E) $null = Save-SAKodiPending -QueueRoot $Q -Entries @($E) }
        $r = Invoke-Update -Targets @() -Root $script:root
        $r.Text | Should -Match 'Caught up on Film'
    }

    It 'keeps every entry when a folder listing fails, as in a share outage' {
        $global:FakeKodi.Unreachable = $true
        $null = Invoke-Update -Targets @($script:movie, $script:other) -Root $script:root
        $global:FakeKodi.Unreachable = $false
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
        $global:FakeKodi.ListingFailFor = 'smb://S/Data/Movies/'
        $r = Invoke-Update -Targets @() -Root $script:root
        @(Get-PendingRoots -Root $script:root) | Should -HaveCount 2
        $r.Text | Should -Not -Match 'pathMap'
    }

    It 'retries its own title when a folder listing fails' {
        $global:FakeKodi.ListingFailFor = 'smb://S/Data/Movies/'
        $r = Invoke-Update -Targets @($script:movie) -Root $script:root
        $r.Text | Should -Match 'retry on the next import'
        Get-PendingRoots -Root $script:root | Should -Be $script:movie.RootPath
    }

    It 'keeps every entry when the sources cannot be read' {
        $global:FakeKodi.SourcesFail = [pscustomobject]@{ Success = $false; Result = $null; Unreachable = $false; Rejected = $false; ErrorMessage = 'nope' }
        $r = Invoke-Update -Targets @($script:movie) -Root $script:root
        $r.Text | Should -Match 'retry on the next import'
        $r.Text | Should -Not -Match 'pathMap'
        Get-PendingRoots -Root $script:root | Should -Be $script:movie.RootPath
    }

    It 'treats an empty source list as a passing problem' {
        $global:FakeKodi.Sources = @()
        $r = Invoke-Update -Targets @($script:movie) -Root $script:root
        $r.Text | Should -Match 'retry on the next import'
        Get-PendingRoots -Root $script:root | Should -Be $script:movie.RootPath
    }

    It 'keeps a title that failed before an unexpected error in the next one' {
        $script:calls = 0
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiTargetUpdate {
            $global:FakeKodi.Calls.Add('x')
            if ($global:FakeKodi.Calls.Count -eq 2) { throw 'boom' }
            [pscustomobject]@{ Status = 'Skipped'; Reason = 'busy'; Retry = $true; Missing = @() }
        }
        $global:FakeKodi.Calls.Clear()
        $r = Invoke-Update -Targets @($script:movie, $script:other) -Root $script:root
        $r.Text | Should -Match 'Film'
        $r.Text | Should -Match 'Next'
        @(Get-PendingRoots -Root $script:root) | Should -HaveCount 2
    }

    It 'sets an unreadable list aside instead of overwriting it' {
        $file = Join-Path $script:root 'kodi-pending.json'
        Set-Content -Path $file -Value '{not json'
        $global:FakeKodi.Unreachable = $true
        $r = Invoke-Update -Targets @($script:movie) -Root $script:root
        Test-Path (Join-Path $script:root 'kodi-pending.bad.json') | Should -BeTrue
        $r.Text | Should -Match 'kodi-pending.bad.json'
        Get-PendingRoots -Root $script:root | Should -Be $script:movie.RootPath
    }

    It 'does not scan a title twice when it is also on the list' {
        $tv = [pscustomobject]@{ RootPath = 'D:\Data\TV\Show (2020)'; Title = 'Show'; MediaType = 'tv'; Verified = $true; Episodes = @([pscustomobject]@{ Season = 1; Episode = 2 }) }
        $old = [pscustomobject]@{ RootPath = 'd:\data\tv\show (2020)'; Title = 'Show'; MediaType = 'tv'; Verified = $true; Episodes = @([pscustomobject]@{ Season = 1; Episode = 1 }); AddedAt = (Get-Date).ToUniversalTime().AddDays(-8).ToString('o') }
        InModuleScope 'Stagearr.Core' -Parameters @{ Q = $script:root; E = $old } { param($Q, $E) $null = Save-SAKodiPending -QueueRoot $Q -Entries @($E) }
        $global:FakeKodi.Episodes = @(@{ season = 1; episode = 2 })
        $r = Invoke-Update -Targets @($tv) -Root $script:root
        @($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan') | Should -HaveCount 1
        $r.Text | Should -Not -Match 'after 7 days'
        $r.Text | Should -Not -Match 'Caught up'
        $r.Missing | Should -Contain 'Show S01E01'
    }

    It 'moves a failed entry behind the ones not yet tried' {
        $a = [pscustomobject]@{ RootPath = 'D:\Data\Movies\A'; Title = 'A'; MediaType = 'movie'; Verified = $true; Episodes = @(); AddedAt = (Get-Date).ToUniversalTime().ToString('o') }
        $b = [pscustomobject]@{ RootPath = 'D:\Data\Movies\B'; Title = 'B'; MediaType = 'movie'; Verified = $true; Episodes = @(); AddedAt = (Get-Date).ToUniversalTime().ToString('o') }
        InModuleScope 'Stagearr.Core' -Parameters @{ Q = $script:root; A = $a; B = $b } { param($Q, $A, $B) $null = Save-SAKodiPending -QueueRoot $Q -Entries @($A, $B) }
        $global:FakeKodi.Listing['smb://S/Data/Movies/'] = @('smb://S/Data/Movies/A/', 'smb://S/Data/Movies/B/')
        $global:FakeKodi.OnScan = { 1..1000 | ForEach-Object { $global:FakeKodi.BusyQueue.Enqueue($true) } }
        $null = Invoke-Update -Targets @() -Root $script:root
        (Get-PendingRoots -Root $script:root)[0] | Should -Be $b.RootPath
    }

    It 'reports a gone folder without telling you to scan' {
        $global:FakeKodi.Unreachable = $true
        $null = Invoke-Update -Targets @($script:movie) -Root $script:root
        $global:FakeKodi.Unreachable = $false
        InModuleScope 'Stagearr.Core' { Reset-SAKodiBreaker }
        $global:FakeKodi.Listing['smb://S/Data/Movies/'] = @('smb://S/Data/Movies/Next (2021)/')
        $r = Invoke-Update -Targets @() -Root $script:root
        $r.Text | Should -Match 'no longer exists'
        $r.Text | Should -Not -Match 'until a scan runs'
    }

    It 'retries an unconfirmed import whose folder is not there yet' {
        $t = [pscustomobject]@{ RootPath = 'D:\Data\Movies\Later (2022)'; Title = 'Later'; MediaType = 'movie'; Episodes = @(); Verified = $false }
        $r = Invoke-Update -Targets @($t) -Root $script:root
        $r.Text | Should -Match 'retry on the next import'
    }
}

Describe 'Invoke-SAKodiStep' {
    BeforeEach {
        $script:context = @{ Config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = @() } }; Paths = @{ QueueRoot = 'q' } }
        $script:import = [pscustomobject]@{ Success = $true; ImportedCount = 1; KodiTargets = @([pscustomobject]@{ RootPath = 'D:\M\A' }) }
        Mock -ModuleName 'Stagearr.Core' Update-SAJobProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAOutcome {}
        Mock -ModuleName 'Stagearr.Core' Write-SAVerbose {}
        Mock -ModuleName 'Stagearr.Core' Add-SAEmailException {}
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { [pscustomobject]@{ Status = 'Updated'; Text = 'ok'; Missing = @(); Duration = 1 } }
    }

    It 'clears the pending list on a job with nothing of its own' {
        $root = Join-Path $TestDrive 'step1'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'kodi' 'h_80')
        Set-Content -Path (Join-Path $root 'kodi' 'h_80' 'kodi-pending.json') -Value '[{"RootPath":"D:\\M\\A","Title":"A","MediaType":"movie","Verified":true,"Episodes":[],"AddedAt":"2026-11-07T00:00:00.0000000Z"}]'
        $script:context.Paths.QueueRoot = $root
        $none = [pscustomobject]@{ Success = $true; Skipped = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $none } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -Times 1
    }

    It 'skips Kodi when there is nothing to do at all' {
        $root = Join-Path $TestDrive 'step2'
        $null = New-Item -ItemType Directory -Path $root
        $script:context.Paths.QueueRoot = $root
        $none = [pscustomobject]@{ Success = $true; Skipped = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $none } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -Times 0
    }

    It 'keeps a green result and adds other news as a note' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { [pscustomobject]@{ Status = 'Updated'; Text = 'ok; B: busy'; Summary = 'ok'; Notes = 'B: busy'; Missing = @(); Duration = 1 } }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Success' -and $Text -eq 'ok' }
        Should -Invoke -ModuleName 'Stagearr.Core' Add-SAEmailException -Times 1 -ParameterFilter { $Type -eq 'Info' -and $Message -match 'B: busy' }
    }

    It 'writes nothing to the job when the update has nothing to report' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { [pscustomobject]@{ Status = 'Idle'; Text = ''; Missing = @(); Duration = 0 } }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 0
        Should -Invoke -ModuleName 'Stagearr.Core' Add-SAEmailException -Times 0
    }

    It 'does nothing when the feature is off' {
        $script:context.Config.kodi.enabled = $false
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -Times 0
    }

    It 'reports success into the email' {
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Success' -and $Label -eq 'Kodi' -and $EmailInclude }
    }

    It 'warns on a partial result' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { [pscustomobject]@{ Status = 'Partial'; Text = 'Show S01E02'; Missing = @(); Duration = 1 } }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        Should -Invoke -ModuleName 'Stagearr.Core' Add-SAEmailException -Times 1 -ParameterFilter { $Type -eq 'Warning' -and $Message -match 'S01E02' }
    }

    It 'keeps a skip out of the warning level' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { [pscustomobject]@{ Status = 'Skipped'; Text = 'asleep'; Missing = @(); Duration = 0 } }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Skip' }
        Should -Invoke -ModuleName 'Stagearr.Core' Add-SAEmailException -Times 1 -ParameterFilter { $Type -eq 'Info' }
    }

    It 'never lets a failure reach the job' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { throw 'boom' }
        { InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I } } | Should -Not -Throw
        Should -Invoke -ModuleName 'Stagearr.Core' Add-SAEmailException -Times 1 -ParameterFilter { $Type -eq 'Info' }
    }

    It 'survives a failure in its own gates' {
        Mock -ModuleName 'Stagearr.Core' Test-SAKodiStepNeeded { throw 'boom' }
        { InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I } } | Should -Not -Throw
    }
}

Describe 'Kodi config sync' {
    It 'round-trips a <Name> pathMap through the TOML writer' -ForEach @(
        @{ Name = 'one-entry'; Line = 'pathMap = ["D:\\Data\\|smb://H/Data/"]'; Count = 1 }
        @{ Name = 'two-entry'; Line = 'pathMap = ["D:\\A\\|smb://H/A/", "E:\\B\\|smb://H/B/"]'; Count = 2 }
    ) {
        $sample = Join-Path $PSScriptRoot '..' 'config-sample.toml'
        InModuleScope 'Stagearr.Core' -Parameters @{ Line = $Line; Count = $Count; Sample = $sample } {
            param($Line, $Count, $Sample)
            $first = ConvertFrom-SAToml -Content "[kodi]`nhost = `"h`"`n$Line`n"
            $written = ConvertTo-SAToml -Config $first -SamplePath $Sample
            $second = ConvertFrom-SAToml -Content $written
            @(Get-SAKodiPathMap -PathMap $second.kodi.pathMap) | Should -HaveCount $Count
            @(Get-SAKodiPathMap -PathMap $second.kodi.pathMap)[0].To | Should -Match '^smb://H/'
            @(Get-SAKodiPathMap -PathMap $second.kodi.pathMap)[0].From | Should -Match '^[A-Z]:\\[A-Za-z]+\\$'
        }
    }

    It 'masks every value under kodi, including a mistyped key' {
        InModuleScope 'Stagearr.Core' {
            Format-SAConfigValuePreview -Path 'kodi.pasword' -Value 'hunter2' | Should -Be '***'
            Format-SAConfigValuePreview -Path 'importers.radarr.apiKey' -Value 'abc' | Should -Be '***'
        }
    }

    It 'still previews ordinary values' {
        InModuleScope 'Stagearr.Core' {
            Format-SAConfigValuePreview -Path 'paths.oldKey' -Value 'x' | Should -Be 'x'
            Format-SAConfigValuePreview -Path 'a.b' -Value @{ c = 1 } | Should -Be '{...}'
            Format-SAConfigValuePreview -Path 'a.b' -Value @(1, 2, 3) | Should -Be '[1, 2...]'
            Format-SAConfigValuePreview -Path 'a.b' -Value @(1, 2, 3) -Full | Should -Be '[1, 2, 3]'
        }
    }
}

Describe 'Read-SASetupArray with pathMap entries' {
    It 'keeps every entry when the prompt is left empty' {
        InModuleScope 'Stagearr.Core' {
            Mock Read-Host { '' }
            $r = Read-SASetupArray -Prompt 'x' -Current @('a|b', 'c|d')
            @($r) | Should -HaveCount 2
        }
    }
}

Describe 'Get-SAKodiHosts' {
    It 'reads a single host with the shared port' {
        InModuleScope 'Stagearr.Core' {
            $r = @(Get-SAKodiHosts -Config @{ kodi = @{ host = ' htpc '; port = 8080 } })
            $r | Should -HaveCount 1
            $r[0].Name | Should -Be 'htpc'
            $r[0].Port | Should -Be 8080
            $r[0].Label | Should -Be 'htpc'
            $r[0].Key | Should -Be 'htpc_8080'
        }
    }

    It 'reads a list and lets an entry carry its own port' {
        InModuleScope 'Stagearr.Core' {
            $r = @(Get-SAKodiHosts -Config @{ kodi = @{ host = @('box1', 'Box2:8080'); port = 80 } })
            $r | Should -HaveCount 2
            $r[1].Name | Should -Be 'Box2'
            $r[1].Port | Should -Be 8080
            $r[1].Label | Should -Be 'Box2:8080'
            $r[1].Key | Should -Be 'box2_8080'
        }
    }

    It 'lists the same host and port once' {
        InModuleScope 'Stagearr.Core' {
            @(Get-SAKodiHosts -Config @{ kodi = @{ host = @('box', 'BOX:80', ''); port = 80 } }) | Should -HaveCount 1
        }
    }

    It 'brackets an IPv6 address so it can go in a URL' {
        InModuleScope 'Stagearr.Core' {
            $r = @(Get-SAKodiHosts -Config @{ kodi = @{ host = @('fd00::5', '[fd00::6]:8080'); port = 80 } })
            $r[0].Name | Should -Be '[fd00::5]'
            $r[0].Port | Should -Be 80
            $r[1].Name | Should -Be '[fd00::6]'
            $r[1].Port | Should -Be 8080
            $r[1].Key | Should -Match '^[a-z0-9._-]+$'
        }
    }

    It 'skips entries it cannot use' {
        InModuleScope 'Stagearr.Core' {
            @(Get-SAKodiHosts -Config @{ kodi = @{ host = @('http://box', 'box:port', 'box:70000', 'two words'); port = 80 } }) | Should -HaveCount 0
        }
    }
}

Describe 'Test-SAKodiConfig with several hosts' {
    It 'accepts a list of hosts' {
        InModuleScope 'Stagearr.Core' {
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = @('box1', 'box2:8080'); port = 80; pathMap = @() } }) | Should -HaveCount 0
        }
    }

    It 'reports an entry it cannot use, by name' {
        InModuleScope 'Stagearr.Core' {
            $r = @(Test-SAKodiConfig -Config @{ kodi = @{ host = @('box1', 'http://box2'); port = 80; pathMap = @() } })
            $r | Should -HaveCount 1
            $r[0] | Should -Match 'http://box2'
        }
    }

    It 'reports an empty list' {
        InModuleScope 'Stagearr.Core' {
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = @(); port = 80; pathMap = @() } }) | Should -HaveCount 1
        }
    }
}

Describe 'Save-SAKodiPending folder' {
    It 'creates the folder of a new host' {
        $root = Join-Path $TestDrive 'kodi' 'new_80'
        InModuleScope 'Stagearr.Core' -Parameters @{ Root = $root } {
            param($Root)
            $e = [pscustomobject]@{ RootPath = 'D:\M\A'; Title = 'A'; MediaType = 'movie'; Verified = $true; Episodes = @(); AddedAt = '2026-11-07T00:00:00.0000000Z' }
            Save-SAKodiPending -QueueRoot $Root -Entries @($e) | Should -BeTrue
            @(Read-SAKodiPending -QueueRoot $Root) | Should -HaveCount 1
        }
    }
}

Describe 'Join-SAKodiResults' {
    BeforeAll {
        function script:New-KodiResult($Status, $Summary, $Notes, $Missing = @(), $Duration = 1) {
            [pscustomobject]@{
                Status = $Status; Summary = $Summary; Notes = $Notes; Missing = @($Missing); Duration = $Duration
                Text = (@($Summary, $Notes) | Where-Object { $_ }) -join '; '
            }
        }
    }

    It 'returns a single host result unchanged' {
        $one = New-KodiResult 'Updated' 'Scanned and confirmed' $null
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ O = $one } { param($O) Join-SAKodiResults -Results @([pscustomobject]@{ Label = 'box'; Result = $O }) }
        $r.Text | Should -Be 'Scanned and confirmed'
        $r.Status | Should -Be 'Updated'
    }

    It 'names each host and adds up the time' {
        $a = New-KodiResult 'Updated' 'Scanned and confirmed' $null @() 30
        $b = New-KodiResult 'Skipped' $null 'Film: Kodi is unreachable' @() 10
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ A = $a; B = $b } {
            param($A, $B)
            Join-SAKodiResults -Results @([pscustomobject]@{ Label = 'box1'; Result = $A }, [pscustomobject]@{ Label = 'box2'; Result = $B })
        }
        $r.Status | Should -Be 'Updated'
        $r.Summary | Should -Be 'box1: Scanned and confirmed'
        $r.Notes | Should -Be 'box2: Film: Kodi is unreachable'
        $r.Text | Should -Be 'box1: Scanned and confirmed; box2: Film: Kodi is unreachable'
        $r.Duration | Should -Be 40
    }

    It 'warns when any host refused a title' {
        $a = New-KodiResult 'Updated' 'Scanned and confirmed' $null
        $b = New-KodiResult 'Partial' $null 'Show: not found' @('Show S01E02')
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ A = $a; B = $b } {
            param($A, $B)
            Join-SAKodiResults -Results @([pscustomobject]@{ Label = 'box1'; Result = $A }, [pscustomobject]@{ Label = 'box2'; Result = $B })
        }
        $r.Status | Should -Be 'Partial'
        @($r.Missing) | Should -Be @('Show S01E02')
    }

    It 'leaves out hosts with nothing to report' {
        $a = New-KodiResult 'Idle' $null $null @() 0
        $b = New-KodiResult 'Skipped' $null 'Film: Kodi is unreachable'
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ A = $a; B = $b } {
            param($A, $B)
            Join-SAKodiResults -Results @([pscustomobject]@{ Label = 'box1'; Result = $A }, [pscustomobject]@{ Label = 'box2'; Result = $B })
        }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Be 'box2: Film: Kodi is unreachable'
    }

    It 'is idle when every host is' {
        $a = New-KodiResult 'Idle' $null $null @() 0
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ A = $a } {
            param($A)
            Join-SAKodiResults -Results @([pscustomobject]@{ Label = 'box1'; Result = $A }, [pscustomobject]@{ Label = 'box2'; Result = $A })
        }
        $r.Status | Should -Be 'Idle'
    }
}

Describe 'Invoke-SAKodiStep with several hosts' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root
        $script:context = @{ Config = @{ kodi = @{ enabled = $true; host = @('box1', 'box2:8080'); port = 80; pathMap = @() } }; Paths = @{ QueueRoot = $script:root } }
        $script:import = [pscustomobject]@{ Success = $true; ImportedCount = 1; KodiTargets = @([pscustomobject]@{ RootPath = 'D:\M\A' }) }
        Mock -ModuleName 'Stagearr.Core' Update-SAJobProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAOutcome {}
        Mock -ModuleName 'Stagearr.Core' Write-SAVerbose {}
        Mock -ModuleName 'Stagearr.Core' Add-SAEmailException {}
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { [pscustomobject]@{ Status = 'Updated'; Text = 'ok'; Summary = 'ok'; Notes = $null; Missing = @(); Duration = 1 } }
    }

    It 'updates every host, each with its own retry folder' {
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -Times 2
        $q1 = Join-Path $script:root 'kodi' 'box1_80'
        $q2 = Join-Path $script:root 'kodi' 'box2_8080'
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -Times 1 -ParameterFilter { $Config.kodi.host -eq 'box1' -and $Config.kodi.port -eq 80 -and $QueueRoot -eq $q1 }
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -Times 1 -ParameterFilter { $Config.kodi.host -eq 'box2' -and $Config.kodi.port -eq 8080 -and $QueueRoot -eq $q2 }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Success' -and $Text -eq 'box1: ok; box2:8080: ok' }
    }

    It 'leaves the shared config untouched' {
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        $script:context.Config.kodi.host | Should -Be @('box1', 'box2:8080')
        $script:context.Config.kodi.port | Should -Be 80
    }

    It 'runs for a host that has titles waiting, with nothing of its own' {
        $q2 = Join-Path $script:root 'kodi' 'box2_8080'
        $null = New-Item -ItemType Directory -Path $q2
        Set-Content -Path (Join-Path $q2 'kodi-pending.json') -Value '[{"RootPath":"D:\\M\\A","Title":"A","MediaType":"movie","Verified":true,"Episodes":[],"AddedAt":"2026-11-07T00:00:00.0000000Z"}]'
        $none = [pscustomobject]@{ Success = $true; Skipped = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $none } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -Times 1 -ParameterFilter { $QueueRoot -eq $q2 }
    }

    It 'reports a host list problem once, without touching any retry list' {
        $script:context.Config.kodi.host = @('box1', 'http://box2')
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -Times 1 -ParameterFilter { [string]::IsNullOrEmpty($QueueRoot) }
    }
}

Describe 'Kodi host list config sync' {
    It 'round-trips a host list through the TOML writer' {
        $sample = Join-Path $PSScriptRoot '..' 'config-sample.toml'
        InModuleScope 'Stagearr.Core' -Parameters @{ Sample = $sample } {
            param($Sample)
            $first = ConvertFrom-SAToml -Content "[kodi]`nhost = [`"box1`", `"box2:8080`"]`n"
            $second = ConvertFrom-SAToml -Content (ConvertTo-SAToml -Config $first -SamplePath $Sample)
            @(Get-SAKodiHosts -Config @{ kodi = @{ host = $second.kodi.host; port = 80 } }).Label | Should -Be @('box1', 'box2:8080')
        }
    }
}

Describe 'Kodi request timeouts' {
    BeforeAll {
        $script:ok = [pscustomobject]@{ Success = $true; StatusCode = 200; Data = [pscustomobject]@{ result = 'OK' }; ErrorMessage = $null }
    }

    It 'gives an ordinary call 3 seconds by default' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Ok = $script:ok } {
            param($Ok)
            Mock Invoke-SAWebRequest { $Ok }
            $null = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80 } } -Method 'JSONRPC.Ping'
            Should -Invoke Invoke-SAWebRequest -Times 1 -ParameterFilter { $TimeoutSeconds -eq 3 }
        }
    }

    It 'uses kodi.timeoutSeconds when set' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Ok = $script:ok } {
            param($Ok)
            Mock Invoke-SAWebRequest { $Ok }
            $null = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80; timeoutSeconds = 7 } } -Method 'JSONRPC.Ping'
            Should -Invoke Invoke-SAWebRequest -Times 1 -ParameterFilter { $TimeoutSeconds -eq 7 }
        }
    }

    It 'lets a caller ask for longer' {
        InModuleScope 'Stagearr.Core' -Parameters @{ Ok = $script:ok } {
            param($Ok)
            Mock Invoke-SAWebRequest { $Ok }
            $null = Invoke-SAKodiRpc -Config @{ kodi = @{ host = 'h'; port = 80; timeoutSeconds = 2 } } -Method 'X' -TimeoutSeconds 30
            Should -Invoke Invoke-SAWebRequest -Times 1 -ParameterFilter { $TimeoutSeconds -eq 30 }
        }
    }

    It 'gives a folder listing the longer limit, since it waits on the share' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAKodiRpc { [pscustomobject]@{ Success = $true; Result = [pscustomobject]@{ files = @() }; Unreachable = $false; Rejected = $false; ErrorMessage = $null } }
            $null = Resolve-SAKodiDirectory -Config @{ kodi = @{ host = 'h'; port = 80; timeoutSeconds = 2 } } -Parent 'smb://S/Movies/' -Leaf 'Film (2020)'
            Should -Invoke Invoke-SAKodiRpc -Times 1 -ParameterFilter { $Method -eq 'Files.GetDirectory' -and $TimeoutSeconds -eq 30 }
        }
    }

    It 'reports a timeout that is not a whole number of at least 1' -ForEach @(
        @{ Value = 0 }, @{ Value = -1 }, @{ Value = 'abc' }, @{ Value = 2.5 }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ V = $Value } {
            param($V)
            $r = @(Test-SAKodiConfig -Config @{ kodi = @{ host = 'h'; port = 80; pathMap = @(); timeoutSeconds = $V } })
            $r | Should -HaveCount 1
            $r[0] | Should -Match 'timeoutSeconds'
        }
    }

    It 'accepts a missing or valid timeout' {
        InModuleScope 'Stagearr.Core' {
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = 'h'; port = 80; pathMap = @() } }) | Should -HaveCount 0
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = 'h'; port = 80; pathMap = @(); timeoutSeconds = 5 } }) | Should -HaveCount 0
        }
    }
}

Describe 'Invoke-SAKodiStep result' {
    BeforeEach {
        $script:context = @{ Config = @{ kodi = @{ enabled = $true; host = 'h'; port = 80; pathMap = @() } }; Paths = @{ QueueRoot = 'q' } }
        $script:import = [pscustomobject]@{ Success = $true; ImportedCount = 1; KodiTargets = @([pscustomobject]@{ RootPath = 'D:\M\A' }) }
        Mock -ModuleName 'Stagearr.Core' Update-SAJobProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAOutcome {}
        Mock -ModuleName 'Stagearr.Core' Write-SAVerbose {}
        Mock -ModuleName 'Stagearr.Core' Add-SAEmailException {}
    }

    It 'returns <Expected> for an update with status <Status>' -ForEach @(
        @{ Status = 'Updated'; Expected = 'Updated' }
        @{ Status = 'Partial'; Expected = 'Partial' }
        @{ Status = 'Skipped'; Expected = 'Skipped' }
    ) {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate -MockWith ([scriptblock]::Create("[pscustomobject]@{ Status = '$Status'; Text = 'x'; Missing = @(); Duration = 1 }"))
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        $r | Should -Be $Expected
    }

    It 'returns nothing when the feature is off' {
        $script:context.Config.kodi.enabled = $false
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        $r | Should -BeNullOrEmpty
    }

    It 'returns Skipped when the update throws' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { throw 'boom' }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:context; I = $script:import } { param($X, $I) Invoke-SAKodiStep -Context $X -JobId '1' -ImportResult $I }
        $r | Should -Be 'Skipped'
    }
}
