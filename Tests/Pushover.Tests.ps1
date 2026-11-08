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
            ($p.Errors -join ' ') | Should -Not -Match 'uAAA|uXXX|uDUP|ghost|sometimes'
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

Describe 'New-SAPushoverMessage' {

    BeforeAll {
        $script:poConfig = @{ sound = ''; failureSound = 'falling' }
        $script:newSummary = {
            param([hashtable]$Overrides = @{})
            $s = @{
                Name          = 'Lanterns S01'
                Label         = 'TV'
                ImportTarget  = 'Sonarr'
                Subtitles     = @('English', 'Dutch')
                MissingLangs  = @()
                Exceptions    = @()
                IsPassthrough = $false
                Duration      = '09:22'
                VideoCount    = 8
                VideoSize     = '28.1 GB'
                FailureError  = ''
                ReleaseInfo   = [PSCustomObject]@{ QualityDisplay = '2160p WEB-DL HBO Max' }
                OmdbData      = @{
                    Plot       = 'Two Green Lantern officers investigate.'
                    ImdbId     = 'tt26545992'
                    ImdbRating = '7.8'
                    Genre      = 'Action, Crime'
                    PosterData = @{ Bytes = [byte[]](1, 2, 3); MimeType = 'image/jpeg' }
                }
                ArrLink       = @{ Url = 'http://arr.example.lan/series/lanterns'; AppName = 'Sonarr' }
            }
            foreach ($k in $Overrides.Keys) { $s[$k] = $Overrides[$k] }
            return $s
        }
        $script:imported = [PSCustomObject]@{ State = 'Imported'; ImportedCount = 8; HasWarnings = $false }
        $script:importResult = [PSCustomObject]@{
            Success = $true
            ImportedFiles = @(1..8 | ForEach-Object { [PSCustomObject]@{ Filename = "e$_.mkv"; Season = 1; Episode = $_ } })
        }
        $script:at = [datetime]'2026-11-08T17:33:00Z'
    }

    It 'builds the full message for an all recipient' {
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:newSummary); St = $script:imported; R = $script:importResult; C = $script:poConfig; T = $script:at } {
            param($S, $St, $R, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -ImportResult $R -KodiStatus 'Updated' -FinishedAt $T -PushoverConfig $C
            $m.title | Should -Be '✅ Imported · Lanterns S01'
            $m.html | Should -Be 1
            $m.priority | Should -Be 0
            $m.message | Should -Match '<i>Two Green Lantern officers investigate\.</i>'
            $m.message | Should -Match '<b>Status:</b> Imported 8 files to Sonarr'
            $m.message | Should -Match '<b>Quality:</b> 2160p WEB-DL HBO Max'
            $m.message | Should -Match '<b>Subtitles:</b> Dutch, English'
            $m.message | Should -Match '<a href="https://www.imdb.com/title/tt26545992/">★ 7\.8</a> · Action, Crime'
            $m.message | Should -Match '<b>Kodi:</b> in library'
            $m.url | Should -Be 'http://arr.example.lan/series/lanterns'
            $m.url_title | Should -Be 'View in Sonarr'
            $m.attachment_type | Should -Be 'image/jpeg'
            $m.attachment_base64 | Should -Be ([Convert]::ToBase64String([byte[]](1, 2, 3)))
            $m.timestamp | Should -Be ([DateTimeOffset]$T).ToUnixTimeSeconds()
            $m.Contains('sound') | Should -BeFalse
        }
    }

    It 'titles an Imported message Ready to watch for a success recipient' {
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:newSummary); St = $script:imported; R = $script:importResult; C = $script:poConfig; T = $script:at } {
            param($S, $St, $R, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'success' -ImportResult $R -FinishedAt $T -PushoverConfig $C
            $m.title | Should -Be '✅ Ready to watch · Lanterns S01'
        }
    }

    It 'gives a success recipient a partly imported job without warnings or retry time' {
        $sum = & $script:newSummary @{
            MissingLangs = @('Dutch'); Subtitles = @('English')
            Exceptions = @([PSCustomObject]@{ Message = 'Sonarr rejected E05 (TBA title), retry Tue 19:00'; Type = 'Warning' })
        }
        $st = [PSCustomObject]@{ State = 'Partial'; ImportedCount = 7; HasWarnings = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $sum; St = $st; R = $script:importResult; C = $script:poConfig; T = $script:at } {
            param($S, $St, $R, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'success' -ImportResult $R -KodiStatus 'Partial' -FinishedAt $T -PushoverConfig $C
            $m.title | Should -Be '✅ Ready to watch · Lanterns S01'
            $m.message | Should -Not -Match 'TBA|retry|unavailable|Missing|Kodi'
            $m.message | Should -Match '<b>Subtitles:</b> English'

            $all = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -ImportResult $R -KodiStatus 'Partial' -FinishedAt $T -PushoverConfig $C
            $all.title | Should -Be '⚠️ Partly imported · Lanterns S01'
            $all.message | Should -Match 'retry Tue 19:00'
            $all.message | Should -Match 'unavailable: Dutch'
            $all.message | Should -Match '<b>Kodi:</b> not everything reached Kodi'
        }
    }

    It 'titles a job waiting on a TBA retry Waiting for an all recipient and sends nothing to a success recipient' {
        $st = [PSCustomObject]@{ State = 'Partial'; ImportedCount = 0; HasWarnings = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:newSummary); St = $st; C = $script:poConfig; T = $script:at } {
            param($S, $St, $C, $T)
            (New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C).title | Should -Be '⏳ Waiting · Lanterns S01'
            New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'success' -FinishedAt $T -PushoverConfig $C | Should -BeNullOrEmpty
        }
    }

    It 'sends a failure only to an all recipient, at high priority with the failure sound' {
        $sum = & $script:newSummary @{ FailureError = 'Sonarr did not answer'; Exceptions = @([PSCustomObject]@{ Message = 'Use -Rerun to retry'; Type = 'Error' }) }
        $st = [PSCustomObject]@{ State = 'Failed'; ImportedCount = 0; HasWarnings = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $sum; St = $st; C = $script:poConfig; T = $script:at } {
            param($S, $St, $C, $T)
            New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'success' -FinishedAt $T -PushoverConfig $C | Should -BeNullOrEmpty
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C
            $m.title | Should -Be '❌ Failed · Lanterns S01'
            $m.priority | Should -Be 1
            $m.sound | Should -Be 'falling'
            $m.message | Should -Match '<b>Status:</b> Sonarr did not answer'
            $m.message | Should -Match 'Use -Rerun to retry'
        }
    }

    It 'sends nothing new quietly and only to an all recipient' {
        $st = [PSCustomObject]@{ State = 'NothingNew'; ImportedCount = 0; HasWarnings = $false }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:newSummary); St = $st; C = $script:poConfig; T = $script:at } {
            param($S, $St, $C, $T)
            New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'success' -FinishedAt $T -PushoverConfig $C | Should -BeNullOrEmpty
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C
            $m.title | Should -Be 'ℹ️ Already in library · Lanterns S01'
            $m.priority | Should -Be -1
        }
    }

    It 'escapes text taken from names, plot and warnings' {
        $sum = & $script:newSummary @{ Name = 'A<B & "C"'; Exceptions = @([PSCustomObject]@{ Message = 'bad <tag>'; Type = 'Warning' }) }
        $sum.OmdbData.Plot = 'x < y & z'
        $st = [PSCustomObject]@{ State = 'Partial'; ImportedCount = 1; HasWarnings = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $sum; St = $st; C = $script:poConfig; T = $script:at } {
            param($S, $St, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C
            $m.title | Should -Be '⚠️ Partly imported · A<B & "C"'
            $m.message | Should -Match 'x &lt; y &amp; z'
            $m.message | Should -Match 'bad &lt;tag&gt;'
            $m.message | Should -Not -Match '<tag>'
        }
    }

    It 'keeps a long message under the limit, dropping the plot first and leaving tags balanced' {
        $warnings = @(1..30 | ForEach-Object { [PSCustomObject]@{ Message = "Warning number $_ with some extra words to take room"; Type = 'Warning' } })
        $sum = & $script:newSummary @{ Exceptions = $warnings }
        $sum.OmdbData.Plot = 'p' * 3000
        $st = [PSCustomObject]@{ State = 'Partial'; ImportedCount = 1; HasWarnings = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $sum; St = $st; C = $script:poConfig; T = $script:at } {
            param($S, $St, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C
            $m.message.Length | Should -BeLessOrEqual 1024
            $m.message | Should -Not -Match 'ppppp'
            $m.message | Should -Match '<b>Status:</b>'
            ([regex]::Matches($m.message, '<b>')).Count | Should -Be ([regex]::Matches($m.message, '</b>')).Count
            ([regex]::Matches($m.message, '<a ')).Count | Should -Be ([regex]::Matches($m.message, '</a>')).Count
        }
    }

    It 'leaves out a poster larger than Pushover accepts' {
        $sum = & $script:newSummary
        $sum.OmdbData.PosterData = @{ Bytes = [byte[]]::new(6MB); MimeType = 'image/jpeg' }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $sum; St = $script:imported; C = $script:poConfig; T = $script:at } {
            param($S, $St, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C
            $m.Contains('attachment_base64') | Should -BeFalse
        }
    }

    It 'leaves out the button without an Arr link and the IMDb line without OMDb data' {
        $sum = & $script:newSummary @{ ArrLink = $null; OmdbData = $null }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $sum; St = $script:imported; C = $script:poConfig; T = $script:at } {
            param($S, $St, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C
            $m.Contains('url') | Should -BeFalse
            $m.message | Should -Not -Match 'IMDb'
            $m.message | Should -Match '<b>Status:</b> Imported to Sonarr'
        }
    }

    It 'builds a short passthrough message' {
        $sum = & $script:newSummary @{ Name = 'SomeApp 2.0'; IsPassthrough = $true; OmdbData = $null; ArrLink = $null; ReleaseInfo = $null; ImportTarget = '' }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $sum; St = $script:imported; C = $script:poConfig; T = $script:at } {
            param($S, $St, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C -FolderPath 'C:\Done\Software\SomeApp 2.0'
            $m.title | Should -Be '✅ Done · SomeApp 2.0'
            $m.message | Should -Match '<b>Files:</b> 8, 28\.1 GB'
            $m.message | Should -Match '<b>Folder:</b> C:\\Done\\Software\\SomeApp 2\.0'
            $m.message | Should -Match '<b>Took:</b> 09:22'
            $m.message | Should -Not -Match 'IMDb|Quality|Subtitles'
        }
    }
}

Describe 'Pushover config sync' {
    It 'round-trips recipients and routes through the TOML writer' {
        $sample = Join-Path $PSScriptRoot '..' 'config-sample.toml'
        InModuleScope 'Stagearr.Core' -Parameters @{ Sample = $sample } {
            param($Sample)
            $text = "[notifications.pushover]`nenabled = true`nrecipients = [`"me|uAAA|all`", `"partner|uBBB|success`"]`nroutes = [`"tv,movie|me,partner`", `"*|me`"]`n"
            $first = ConvertFrom-SAToml -Content $text
            $second = ConvertFrom-SAToml -Content (ConvertTo-SAToml -Config $first -SamplePath $Sample)
            $p = ConvertFrom-SAPushoverConfig -Config $second.notifications.pushover
            $p.Recipients.Keys | Should -Be @('me', 'partner')
            $p.Routes | Should -HaveCount 2
            $p.Errors | Should -BeNullOrEmpty
        }
    }
}

Describe 'Send-SAPushoverMessage' {

    It 'posts a form body with token, user and fields' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAWebRequest { [pscustomobject]@{ Success = $true; StatusCode = 200; Data = @{ status = 1 }; RawContent = '{"status":1}' } }
        $r = InModuleScope 'Stagearr.Core' {
            Send-SAPushoverMessage -AppToken 'aTOKEN' -UserKey 'uKEY' -Fields @{ title = 'T & T'; message = '<b>x</b>'; html = 1 } -TimeoutSeconds 7
        }
        $r.Success | Should -BeTrue
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAWebRequest -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $ContentType -eq 'application/x-www-form-urlencoded' -and $TimeoutSeconds -eq 7 -and $MaxRetries -eq 1 -and
            $Body -match '(^|&)token=aTOKEN(&|$)' -and $Body -match '(^|&)user=uKEY(&|$)' -and
            $Body -match 'title=T%20%26%20T' -and $Body -match 'message=%3Cb%3Ex%3C%2Fb%3E' -and $Body -match 'html=1'
        }
    }

    It 'returns the Pushover error text without the token or key' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAWebRequest { [pscustomobject]@{ Success = $false; StatusCode = 400; ErrorMessage = 'HTTP 400'; RawContent = '{"user":"uKEY","errors":["user identifier is not a valid user, group, or subscribed user key"],"status":0}' } }
        $r = InModuleScope 'Stagearr.Core' {
            Send-SAPushoverMessage -AppToken 'aTOKEN' -UserKey 'uKEY' -Fields @{ message = 'x' } -TimeoutSeconds 5
        }
        $r.Success | Should -BeFalse
        $r.StatusCode | Should -Be 400
        $r.Error | Should -Match 'not a valid user'
        $r.Error | Should -Not -Match 'uKEY|aTOKEN'
    }

    It 'returns a failure instead of throwing' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAWebRequest { throw 'network down for aTOKEN' }
        $r = InModuleScope 'Stagearr.Core' {
            Send-SAPushoverMessage -AppToken 'aTOKEN' -UserKey 'uKEY' -Fields @{ message = 'x' } -TimeoutSeconds 5
        }
        $r.Success | Should -BeFalse
        $r.Error | Should -Not -Match 'aTOKEN'
    }
}

Describe 'Invoke-SAPushoverNotify' {

    BeforeEach {
        $script:ctx = @{
            Config = @{
                labels = @{ tv = 'tv'; tvLabels = @(); movie = 'movie'; movieLabels = @() }
                notifications = @{ pushover = @{
                    enabled = $true; appToken = 'aTOKEN'; timeoutSeconds = 5; sound = ''; failureSound = 'falling'
                    recipients = @('me|uME|all', 'partner|uPARTNER|success')
                    routes = @('tv|me,partner')
                } }
            }
            Flags = @{ NoMail = $false }
            State = @{ StagingPath = 'C:\Done\TV\Show' }
        }
        $script:sentTo = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName 'Stagearr.Core' Write-SAOutcome {}
        Mock -ModuleName 'Stagearr.Core' Write-SAVerbose {}
        Mock -ModuleName 'Stagearr.Core' Add-SAEmailException {}
        Mock -ModuleName 'Stagearr.Core' Send-SAPushoverMessage { [pscustomobject]@{ Success = $true; StatusCode = 200; Error = '' } }
        InModuleScope 'Stagearr.Core' {
            $script:SAEmailSummary = @{
                Name = 'Show S01'; Label = 'tv'; ImportTarget = 'Sonarr'; Subtitles = @('English'); MissingLangs = @()
                Exceptions = @(); IsPassthrough = $false; Duration = '01:00'; VideoCount = 1; VideoSize = '1 GB'
                FailureError = ''; ReleaseInfo = $null; OmdbData = $null; ArrLink = $null
            }
        }
        $script:ok = [pscustomobject]@{ Success = $true; ImportedCount = 1 }
    }

    It 'sends one message per recipient on a successful import' {
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; I = $script:ok } { param($X, $I) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 1 -ParameterFilter { $UserKey -eq 'uME' -and $AppToken -eq 'aTOKEN' -and $Fields.html -eq 1 }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 1 -ParameterFilter { $UserKey -eq 'uPARTNER' -and $Fields.title -like '*Ready to watch*' }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Success' -and $Label -eq 'Pushover' -and $Text -eq 'Sent to me, partner' }
    }

    It 'sends a failed job only to the all recipient' {
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx } { param($X) Invoke-SAPushoverNotify -Context $X -JobSuccess $false -ImportResult $null }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 1 -ParameterFilter { $UserKey -eq 'uME' }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 0 -ParameterFilter { $UserKey -eq 'uPARTNER' }
    }

    It 'still sends to the next recipient after one is rejected, and reports it without keys' {
        Mock -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -ParameterFilter { $UserKey -eq 'uME' } { [pscustomobject]@{ Success = $false; StatusCode = 400; Error = 'user key is invalid' } }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; I = $script:ok } { param($X, $I) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 1 -ParameterFilter { $UserKey -eq 'uPARTNER' }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Skip' -and $Text -match 'me' -and $Text -match 'user key is invalid' -and $Text -notmatch 'uME|aTOKEN' }
        Should -Invoke -ModuleName 'Stagearr.Core' Add-SAEmailException -Times 0
    }

    It 'never throws when sending throws' {
        Mock -ModuleName 'Stagearr.Core' Send-SAPushoverMessage { throw 'boom' }
        { InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; I = $script:ok } { param($X, $I) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult $I } } | Should -Not -Throw
    }

    It 'sends nothing with NoMail set' {
        $script:ctx.Flags.NoMail = $true
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; I = $script:ok } { param($X, $I) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 0
    }

    It 'sends nothing when disabled' {
        $script:ctx.Config.notifications.pushover.enabled = $false
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; I = $script:ok } { param($X, $I) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 0
    }

    It 'sends nothing for a label without a route' {
        InModuleScope 'Stagearr.Core' { $script:SAEmailSummary.Label = 'software' }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; I = $script:ok } { param($X, $I) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 0
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 0
    }

    It 'reports config errors in the job log without keys' {
        $script:ctx.Config.notifications.pushover.recipients = @('me|uME|all', 'x|uX|sometimes')
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; I = $script:ok } { param($X, $I) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult $I }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 1 -ParameterFilter { $UserKey -eq 'uME' }
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Skip' -and $Text -match "recipient 'x' does not end in all or success" -and $Text -notmatch 'uX|sometimes' }
    }

    It 'stops starting sends once the time budget is used up' {
        InModuleScope 'Stagearr.Core' { $script:SAConstants.PushoverTotalBudgetSeconds = 0 }
        try {
            InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; I = $script:ok } { param($X, $I) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult $I }
        } finally {
            InModuleScope 'Stagearr.Core' { $script:SAConstants.PushoverTotalBudgetSeconds = 30 }
        }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 0
        Should -Invoke -ModuleName 'Stagearr.Core' Write-SAOutcome -Times 1 -ParameterFilter { $Level -eq 'Skip' -and $Text -match 'time' }
    }

    It 'passes the staging folder for a passthrough job' {
        InModuleScope 'Stagearr.Core' { $script:SAEmailSummary.Label = 'tv'; $script:SAEmailSummary.IsPassthrough = $true }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx } { param($X) Invoke-SAPushoverNotify -Context $X -JobSuccess $true -IsPassthrough $true }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -ParameterFilter { $Fields.message -match 'C:\\Done\\TV\\Show' }
    }
}

Describe 'Test-SAPushoverConfig' {
    It 'sends a test message to every recipient and reports each result' {
        Mock -ModuleName 'Stagearr.Core' Send-SAPushoverMessage { [pscustomobject]@{ Success = ($UserKey -eq 'uME'); StatusCode = 200; Error = $(if ($UserKey -eq 'uME') { '' } else { 'bad key' }) } }
        $r = @(Test-SAPushoverConfig -Config @{ enabled = $true; appToken = 'aTOKEN'; timeoutSeconds = 5; recipients = @('me|uME|all', 'partner|uP|success'); routes = @() })
        $r | Should -HaveCount 2
        ($r | Where-Object Name -eq 'me').Success | Should -BeTrue
        ($r | Where-Object Name -eq 'partner').Error | Should -Be 'bad key'
    }
}


Describe 'Review fixes: config' {

    It 'never echoes a notify value or route name, which could be a pasted key' {
        InModuleScope 'Stagearr.Core' {
            $p = ConvertFrom-SAPushoverConfig -Config @{
                recipients = @('alice|all|uKEYKEYKEYKEYKEYKEYKEYKEYKEYKE')
                routes     = @('tv|uKEYKEYKEYKEYKEYKEYKEYKEYKEYKE')
            }
            ($p.Errors -join ' ') | Should -Not -Match 'uKEY'
            $p.Errors | Should -HaveCount 2
        }
    }

    It 'rejects a recipient name that looks like a Pushover key' {
        InModuleScope 'Stagearr.Core' {
            $p = ConvertFrom-SAPushoverConfig -Config @{ recipients = @('uKEYKEYKEYKEYKEYKEYKEYKEYKEYKE|alice|all') }
            $p.Recipients.Count | Should -Be 0
            ($p.Errors -join ' ') | Should -Not -Match 'uKEY'
            $p.Errors | Should -HaveCount 1
        }
    }

    It 'sends once to a recipient named in different case by two routes' {
        InModuleScope 'Stagearr.Core' {
            $cfg = @{ labels = @{ tv = 'tv'; tvLabels = @('series'); movie = 'movie'; movieLabels = @() } }
            $p = ConvertFrom-SAPushoverConfig -Config @{ recipients = @('Alice|uA|all'); routes = @('tv|Alice', 'Series|alice') }
            @(Get-SAPushoverRecipients -Parsed $p -Label 'series' -Config $cfg) | Should -HaveCount 1
        }
    }
}

Describe 'Review fixes: state and message' {

    BeforeAll {
        $script:cfg2 = @{ sound = ''; failureSound = 'falling' }
        $script:sum2 = {
            param([hashtable]$O = @{})
            $s = @{ Name = 'Show S01'; ImportTarget = 'Sonarr'; Subtitles = @(); MissingLangs = @(); Exceptions = @()
                IsPassthrough = $false; FailureError = ''; ReleaseInfo = $null; OmdbData = $null; ArrLink = $null; ImportResult = '' }
            foreach ($k in $O.Keys) { $s[$k] = $O[$k] }
            $s
        }
        $script:t2 = [datetime]'2026-11-08T12:00:00Z'
    }

    It 'classifies an all-rejected job that is not about quality as NotImported' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; Skipped = $true; QualityRejected = $false; ImportedFiles = @(); Message = 'Unknown Series' }
            (Get-SAPushoverState -JobSuccess $true -ImportResult $r).State | Should -Be 'NotImported'
        }
    }

    It 'keeps NothingNew for a quality rejection' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; Skipped = $true; QualityRejected = $true; ImportedFiles = @() }
            (Get-SAPushoverState -JobSuccess $true -ImportResult $r).State | Should -Be 'NothingNew'
        }
    }

    It 'is Partial when a file next to the imports was rejected for another reason' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; ImportedCount = 7; AbortedCount = 0; Skipped = $false; QualityRejected = $false
                SkippedFiles = @([PSCustomObject]@{ Season = 1; Episode = 9; Reason = 'Unknown episode' }) }
            $s = Get-SAPushoverState -JobSuccess $true -ImportResult $r
            $s.State | Should -Be 'Partial'
            $s.AlreadyInLibrary | Should -Be 0
        }
    }

    It 'stays Imported and counts files already in the library' {
        InModuleScope 'Stagearr.Core' {
            $r = [PSCustomObject]@{ Success = $true; ImportedCount = 7; AbortedCount = 0; Skipped = $false; QualityRejected = $false
                SkippedFiles = @([PSCustomObject]@{ Season = 1; Episode = 8; Reason = 'Quality exists' }) }
            $s = Get-SAPushoverState -JobSuccess $true -ImportResult $r
            $s.State | Should -Be 'Imported'
            $s.AlreadyInLibrary | Should -Be 1
        }
    }

    It 'tells an all recipient what was not imported, and nothing to a success recipient' {
        $st = [PSCustomObject]@{ State = 'NotImported'; ImportedCount = 0; HasWarnings = $true; AlreadyInLibrary = 0 }
        $r = [PSCustomObject]@{ Success = $true; Skipped = $true; Message = 'Unknown Series' }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:sum2); St = $st; R = $r; C = $script:cfg2; T = $script:t2 } {
            param($S, $St, $R, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -ImportResult $R -FinishedAt $T -PushoverConfig $C
            $m.title | Should -Be '⚠️ Not imported · Show S01'
            $m.priority | Should -Be 0
            $m.message | Should -Match '<b>Status:</b> Unknown Series'
            New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'success' -ImportResult $R -FinishedAt $T -PushoverConfig $C | Should -BeNullOrEmpty
        }
    }

    It 'adds an already-in-library line to an imported message' {
        $st = [PSCustomObject]@{ State = 'Imported'; ImportedCount = 7; HasWarnings = $false; AlreadyInLibrary = 1 }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:sum2); St = $st; C = $script:cfg2; T = $script:t2 } {
            param($S, $St, $C, $T)
            (New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'success' -FinishedAt $T -PushoverConfig $C).message | Should -Match '<b>Already in library:</b> 1 file'
        }
    }

    It 'shows the imported count when the episode list is not known' {
        $st = [PSCustomObject]@{ State = 'Imported'; ImportedCount = 7; HasWarnings = $false; AlreadyInLibrary = 0 }
        $r = [PSCustomObject]@{ Success = $true; ImportedCount = 7; ImportedFiles = @() }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:sum2); St = $st; R = $r; C = $script:cfg2; T = $script:t2 } {
            param($S, $St, $R, $C, $T)
            (New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -ImportResult $R -FinishedAt $T -PushoverConfig $C).message | Should -Match '<b>Status:</b> Imported 7 files to Sonarr'
        }
    }

    It 'shortens a very long failure reason instead of sending an empty message' {
        $st = [PSCustomObject]@{ State = 'Failed'; ImportedCount = 0; HasWarnings = $true; AlreadyInLibrary = 0 }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:sum2 @{ FailureError = ('x & y ' * 300) }); St = $st; C = $script:cfg2; T = $script:t2 } {
            param($S, $St, $C, $T)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C
            $m.message.Length | Should -BeLessOrEqual 1024
            $m.message | Should -Match '^<b>Status:</b> x &amp; y'
            $m.message | Should -Not -Match '&a$|&am$|&amp$'
        }
    }

    It 'points to the job log for warnings left out' {
        $w = @(1..40 | ForEach-Object { [PSCustomObject]@{ Message = "Warning $_ with words to fill the message up"; Type = 'Warning' } })
        $st = [PSCustomObject]@{ State = 'Partial'; ImportedCount = 1; HasWarnings = $true; AlreadyInLibrary = 0 }
        InModuleScope 'Stagearr.Core' -Parameters @{ S = (& $script:sum2 @{ Exceptions = $w }); St = $st; C = $script:cfg2; T = $script:t2 } {
            param($S, $St, $C, $T)
            (New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt $T -PushoverConfig $C).message | Should -Match '<i>\+\d+ more in the job log</i>$'
        }
    }
}

Describe 'Review fixes: sending' {

    It 'shows the Pushover reason for a real 4xx response' {
        Mock -ModuleName 'Stagearr.Core' Invoke-WebRequest {
            $er = [System.Management.Automation.ErrorRecord]::new(
                [System.Net.Http.HttpRequestException]::new('Response status code does not indicate success: 400 (Bad Request).'),
                'WebCmdletWebResponseException', 'InvalidOperation', $null)
            $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"token":"invalid","errors":["application token is invalid"],"status":0}')
            throw $er
        }
        $r = InModuleScope 'Stagearr.Core' { Send-SAPushoverMessage -AppToken 'aTOKEN' -UserKey 'uKEY' -Fields @{ message = 'x' } -TimeoutSeconds 5 }
        $r.Success | Should -BeFalse
        $r.StatusCode | Should -Be 400
        $r.Error | Should -Be 'application token is invalid'
    }

    It 'reports an empty token per recipient instead of throwing' {
        Mock -ModuleName 'Stagearr.Core' Send-SAPushoverMessage { throw 'should not be called' }
        $r = @(Test-SAPushoverConfig -Config @{ appToken = ''; recipients = @('me|uME|all'); routes = @() })
        $r | Should -HaveCount 1
        $r[0].Success | Should -BeFalse
        $r[0].Error | Should -Match 'appToken'
    }

    It 'never lets one send run past the time budget' {
        Mock -ModuleName 'Stagearr.Core' Write-SAOutcome {}
        Mock -ModuleName 'Stagearr.Core' Write-SAVerbose {}
        Mock -ModuleName 'Stagearr.Core' Send-SAPushoverMessage { [pscustomobject]@{ Success = $true; StatusCode = 200; Error = '' } }
        $ctx = @{
            Config = @{ labels = @{ tv = 'tv'; tvLabels = @(); movie = 'movie'; movieLabels = @() }
                notifications = @{ pushover = @{ enabled = $true; appToken = 'aT'; timeoutSeconds = 10; recipients = @('me|uME|all'); routes = @('tv|me') } } }
            Flags = @{ NoMail = $false }; State = @{}
        }
        InModuleScope 'Stagearr.Core' -Parameters @{ X = $ctx } {
            param($X)
            $script:SAEmailSummary = @{ Name = 'S'; Label = 'tv'; ImportTarget = 'Sonarr'; Subtitles = @(); MissingLangs = @(); Exceptions = @(); IsPassthrough = $false; ReleaseInfo = $null; OmdbData = $null; ArrLink = $null }
            $script:SAConstants.PushoverTotalBudgetSeconds = 4
            try {
                Invoke-SAPushoverNotify -Context $X -JobSuccess $true -ImportResult ([pscustomobject]@{ Success = $true; ImportedCount = 1 })
            } finally { $script:SAConstants.PushoverTotalBudgetSeconds = 30 }
        }
        Should -Invoke -ModuleName 'Stagearr.Core' Send-SAPushoverMessage -Times 1 -ParameterFilter { $TimeoutSeconds -le 4 }
    }
}


Describe 'Pushover poster setting' {
    BeforeAll {
        $script:posterSummary = @{ Name = 'Show S01'; ImportTarget = 'Sonarr'; Subtitles = @(); MissingLangs = @(); Exceptions = @()
            IsPassthrough = $false; FailureError = ''; ReleaseInfo = $null; ArrLink = $null
            OmdbData = @{ PosterData = @{ Bytes = [byte[]](1, 2, 3); MimeType = 'image/jpeg' } } }
        $script:posterState = [PSCustomObject]@{ State = 'Imported'; ImportedCount = 1; HasWarnings = $false; AlreadyInLibrary = 0 }
    }

    It 'leaves the poster out when poster is false' {
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $script:posterSummary; St = $script:posterState } {
            param($S, $St)
            $m = New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt (Get-Date) -PushoverConfig @{ poster = $false }
            $m.Contains('attachment_base64') | Should -BeFalse
        }
    }

    It 'attaches the poster when poster is true or not set' {
        InModuleScope 'Stagearr.Core' -Parameters @{ S = $script:posterSummary; St = $script:posterState } {
            param($S, $St)
            (New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt (Get-Date) -PushoverConfig @{ poster = $true }).Contains('attachment_base64') | Should -BeTrue
            (New-SAPushoverMessage -Summary $S -StateInfo $St -Audience 'all' -FinishedAt (Get-Date) -PushoverConfig @{}).Contains('attachment_base64') | Should -BeTrue
        }
    }

    It 'has poster on by default' {
        InModuleScope 'Stagearr.Core' { $script:SAConfigDefaults.notifications.pushover.poster | Should -BeTrue }
    }
}
