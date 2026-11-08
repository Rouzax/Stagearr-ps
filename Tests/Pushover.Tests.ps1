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
