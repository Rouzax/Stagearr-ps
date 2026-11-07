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
    It 'reports a blank host and a missing map' {
        InModuleScope 'Stagearr.Core' {
            @(Test-SAKodiConfig -Config @{ kodi = @{ host = ''; pathMap = @() } }) | Should -HaveCount 2
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
                ScanFail    = $null
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
            if ($Method -eq 'VideoLibrary.Scan' -and $k.ScanFail) {
                return $k.ScanFail
            }
            $result = switch ($Method) {
                'XBMC.GetInfoBooleans' {
                    $busy = if ($k.BusyQueue.Count -gt 0) { $k.BusyQueue.Dequeue() } else { $false }
                    [pscustomobject]@{ 'Library.IsScanningVideo' = $busy }
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
        $r.Status | Should -Be 'Partial'
        $r.Text | Should -Match 'Show: .*time limit'
    }

    It 'does not call a scan confirmed when the request got no answer' {
        $global:FakeKodi.ScanFail = [pscustomobject]@{ Success = $false; Result = $null; Unreachable = $true; Rejected = $false; ErrorMessage = 'timeout' }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $script:movie } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Partial'
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
        $r.Status | Should -Be 'Partial'
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

    It 'skips with no calls for an unmapped path' {
        $t = [pscustomobject]@{ RootPath = 'Z:\Else\X'; Title = 'X'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; T = $t } { param($C, $T) Invoke-SAKodiUpdate -Config $C -Targets @($T) }
        $r.Status | Should -Be 'Skipped'
        $r.Text | Should -Match 'pathMap'
        $global:FakeKodi.Calls | Should -HaveCount 0
    }

    It 'skips with no calls on a config problem' {
        $bad = @{ kodi = @{ enabled = $true; host = 'h'; pathMap = @() } }
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

    It 'scans each title in a pack' {
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; A = $script:movie; B = $script:show } { param($C, $A, $B) Invoke-SAKodiUpdate -Config $C -Targets @($A, $B) }
        $r.Status | Should -Be 'Updated'
        (@($global:FakeKodi.Calls | Where-Object Method -EQ 'VideoLibrary.Scan').Params.directory) -join ',' | Should -Be 'smb://S/Data/Movies/Film (2020)/,smb://S/Data/TV/Show (2020)/'
    }

    It 'reports one title skipped and one updated as partial' {
        $t = [pscustomobject]@{ RootPath = 'Z:\Else\X'; Title = 'X'; MediaType = 'movie'; Episodes = @(); Verified = $true }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config; A = $script:movie; B = $t } { param($C, $A, $B) Invoke-SAKodiUpdate -Config $C -Targets @($A, $B) }
        $r.Status | Should -Be 'Partial'
        $r.Text | Should -Match 'until a scan runs'
    }

    It 'does nothing for no targets' {
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ C = $script:config } { param($C) Invoke-SAKodiUpdate -Config $C -Targets @() }
        $r.Status | Should -Be 'Skipped'
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

Describe 'Invoke-SAKodiStep' {
    BeforeEach {
        $script:context = @{ Config = @{ kodi = @{ enabled = $true } }; Paths = @{ QueueRoot = 'q' } }
        $script:import = [pscustomobject]@{ Success = $true; ImportedCount = 1; KodiTargets = @([pscustomobject]@{ RootPath = 'D:\M\A' }) }
        Mock -ModuleName 'Stagearr.Core' Update-SAJobProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAOutcome {}
        Mock -ModuleName 'Stagearr.Core' Write-SAVerbose {}
        Mock -ModuleName 'Stagearr.Core' Add-SAEmailException {}
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiUpdate { [pscustomobject]@{ Status = 'Updated'; Text = 'ok'; Missing = @(); Duration = 1 } }
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
