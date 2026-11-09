# The call-order list is global because mock bodies run in module scope.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Shared with mock bodies that run in module scope')]
param()

BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Pushover in the job pipeline' {

    BeforeEach {
        $script:ctx = @{
            Config = @{
                labels        = @{ tv = 'tv'; tvLabels = @(); movie = 'movie'; movieLabels = @() }
                importers     = @{ sonarr = @{ enabled = $false }; radarr = @{ enabled = $false } }
                notifications = @{ email = @{ enabled = $false }; pushover = @{ enabled = $true } }
            }
            Flags  = @{ NoMail = $false; NoCleanup = $true; TbaRetryScheduled = $false }
            State  = @{ StagingPath = (Join-Path $TestDrive 'staging') }
            Paths  = @{ QueueRoot = 'q' }
        }
        $script:job = @{ id = 'job1'; input = @{ downloadPath = 'C:\Downloads\Show.S01E01.1080p.WEB-DL-GRP'; downloadLabel = 'tv'; torrentHash = '' } }

        $global:PushoverOrder = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName 'Stagearr.Core' Invoke-SAPushoverNotify { $global:PushoverOrder.Add('pushover') }
        Mock -ModuleName 'Stagearr.Core' Send-SAEmail {}
        Mock -ModuleName 'Stagearr.Core' Write-SAOutcome {}
        Mock -ModuleName 'Stagearr.Core' Write-SAProgress {}
        Mock -ModuleName 'Stagearr.Core' Write-SAVerbose {}
        Mock -ModuleName 'Stagearr.Core' Write-SAPhaseHeader {}
        Mock -ModuleName 'Stagearr.Core' Update-SAJobProgress {}
        Mock -ModuleName 'Stagearr.Core' Get-SAContextDuration { [timespan]::FromSeconds(5) }
        Mock -ModuleName 'Stagearr.Core' Get-SAContextLogPath { 'job.log' }
        Mock -ModuleName 'Stagearr.Core' Save-SAFileLog { $global:PushoverOrder.Add('save') }
        Mock -ModuleName 'Stagearr.Core' Set-SAEmailLogPath {}
        Mock -ModuleName 'Stagearr.Core' Remove-SAStagingFolder {}
        Mock -ModuleName 'Stagearr.Core' Test-SALockStolen { $false }
        Mock -ModuleName 'Stagearr.Core' Test-SAFeatureEnabled { $false }
        Mock -ModuleName 'Stagearr.Core' Test-SADangerousDownload { [pscustomobject]@{ IsDangerous = $false; DangerousFiles = @() } }
        Mock -ModuleName 'Stagearr.Core' Test-SATbaRetryMode { $null }
        InModuleScope 'Stagearr.Core' { Initialize-SAEmailRenderer }
    }

    It 'notifies once for a passthrough job, with email off' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAPassthroughProcessing { [pscustomobject]@{ Success = $true; StagingPath = 'C:\Staging\x' } }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; J = $script:job } { param($X, $J) Invoke-SAPassthroughJob -Context $X -Job $J }
        $r | Should -BeTrue
        @($global:PushoverOrder) | Should -Be @('pushover', 'save') -Because 'the Pushover result line must reach the saved job log'
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAPushoverNotify -Times 1 -ParameterFilter { $JobSuccess -eq $true -and $IsPassthrough -eq $true }
        InModuleScope 'Stagearr.Core' { $script:SAEmailSummary.Label | Should -Be 'tv' }
    }

    It 'notifies a failed passthrough job as failed' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAPassthroughProcessing { [pscustomobject]@{ Success = $false; Reason = 'RarExtractionFailed' } }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; J = $script:job } { param($X, $J) Invoke-SAPassthroughJob -Context $X -Job $J }
        $r | Should -BeFalse
        @($global:PushoverOrder) | Should -Be @('pushover', 'save') -Because 'the Pushover result line must reach the saved job log'
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAPushoverNotify -Times 1 -ParameterFilter { $JobSuccess -eq $false -and $IsPassthrough -eq $true }
    }

    It 'notifies a security block as failed with the label set' {
        Mock -ModuleName 'Stagearr.Core' Test-SADangerousDownload { [pscustomobject]@{ IsDangerous = $true; DangerousFiles = @('setup.exe') } }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; J = $script:job } { param($X, $J) Invoke-SAStandardJob -Context $X -Job $J }
        $r | Should -BeFalse
        @($global:PushoverOrder) | Should -Be @('pushover', 'save') -Because 'the Pushover result line must reach the saved job log'
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAPushoverNotify -Times 1 -ParameterFilter { $JobSuccess -eq $false }
        InModuleScope 'Stagearr.Core' { $script:SAEmailSummary.Label | Should -Be 'tv' }
    }

    It 'notifies a TBA retry whose files are gone, with the summary set even when email is off' {
        Mock -ModuleName 'Stagearr.Core' Test-SATbaRetryMode { [pscustomobject]@{ Mode = 'Failed' } }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; J = $script:job } { param($X, $J) Invoke-SAStandardJob -Context $X -Job $J }
        $r | Should -BeFalse
        @($global:PushoverOrder) | Should -Be @('pushover', 'save') -Because 'the Pushover result line must reach the saved job log'
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAPushoverNotify -Times 1 -ParameterFilter { $JobSuccess -eq $false }
        InModuleScope 'Stagearr.Core' {
            $script:SAEmailSummary.Name | Should -Not -BeNullOrEmpty
            $script:SAEmailSummary.Label | Should -Be 'tv'
            $script:SAEmailSummary.FailureError | Should -Match 'TBA retry failed'
        }
    }

    It 'notifies a standard job with its import and Kodi results, and returns a plain bool' {
        Mock -ModuleName 'Stagearr.Core' Invoke-SAVideoProcessing { [pscustomobject]@{ Success = $true; ProcessedFiles = @(); TotalSize = 0 } }
        Mock -ModuleName 'Stagearr.Core' Invoke-SASubtitleProcessing { $null }
        Mock -ModuleName 'Stagearr.Core' Invoke-SAImport { [pscustomobject]@{ Success = $true; ImportedCount = 1; ImportedFiles = @(); SkippedFiles = @(); Skipped = $false; QualityRejected = $false; Message = 'Imported' } }
        Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiStep { 'Updated' }
        Mock -ModuleName 'Stagearr.Core' Invoke-SAMDBListCollect { $null }
        $r = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; J = $script:job } { param($X, $J) Invoke-SAStandardJob -Context $X -Job $J }
        @($r) | Should -HaveCount 1
        $r | Should -BeTrue
        @($global:PushoverOrder) | Should -Be @('pushover', 'save') -Because 'the Pushover result line must reach the saved job log'
        Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAPushoverNotify -Times 1 -ParameterFilter {
            $JobSuccess -eq $true -and $KodiStatus -eq 'Updated' -and $ImportResult.ImportedCount -eq 1 -and $TbaRetryScheduled -eq $false
        }
    }

    Context 'plot for Pushover' {
        BeforeEach {
            $script:ctx.Config.omdb = @{ enabled = $true; display = @{ plot = $false } }
            Mock -ModuleName 'Stagearr.Core' Invoke-SAVideoProcessing { [pscustomobject]@{ Success = $true; ProcessedFiles = @(); TotalSize = 0 } }
            Mock -ModuleName 'Stagearr.Core' Invoke-SASubtitleProcessing { $null }
            Mock -ModuleName 'Stagearr.Core' Invoke-SAImport {
                [pscustomobject]@{ Success = $true; ImportedCount = 1; ImportedFiles = @(); SkippedFiles = @(); Skipped = $false; QualityRejected = $false; Message = 'Imported'
                    ArrMetadata = @{ Plot = 'Arr overview' } }
            }
            Mock -ModuleName 'Stagearr.Core' Invoke-SAKodiStep {}
            Mock -ModuleName 'Stagearr.Core' Invoke-SAMDBListCollect { $null }
        }

        It 'uses the Radarr/Sonarr overview without OMDb, and keeps it out of the email' {
            $null = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; J = $script:job } { param($X, $J) Invoke-SAStandardJob -Context $X -Job $J }
            Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAPushoverNotify -Times 1 -ParameterFilter { $Plot -eq 'Arr overview' }
            InModuleScope 'Stagearr.Core' { $script:SAEmailSummary.OmdbData.Plot | Should -BeNullOrEmpty }
        }

        It 'prefers the OMDb plot and asks OMDb for it when Pushover shows plots' {
            Mock -ModuleName 'Stagearr.Core' Test-SAFeatureEnabled { $Feature -eq 'omdb' }
            Mock -ModuleName 'Stagearr.Core' Get-SAOmdbMetadata { @{ Plot = 'OMDb plot' } }
            $null = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; J = $script:job } { param($X, $J) Invoke-SAStandardJob -Context $X -Job $J }
            Should -Invoke -ModuleName 'Stagearr.Core' Get-SAOmdbMetadata -Times 1 -ParameterFilter { $IncludePlot -eq $true }
            Should -Invoke -ModuleName 'Stagearr.Core' Invoke-SAPushoverNotify -Times 1 -ParameterFilter { $Plot -eq 'OMDb plot' }
            InModuleScope 'Stagearr.Core' { $script:SAEmailSummary.OmdbData.Plot | Should -BeNullOrEmpty }
        }

        It 'does not ask OMDb for a plot when plot is false' {
            $script:ctx.Config.notifications.pushover.plot = $false
            Mock -ModuleName 'Stagearr.Core' Test-SAFeatureEnabled { $Feature -eq 'omdb' }
            Mock -ModuleName 'Stagearr.Core' Get-SAOmdbMetadata { @{ Plot = $null } }
            $null = InModuleScope 'Stagearr.Core' -Parameters @{ X = $script:ctx; J = $script:job } { param($X, $J) Invoke-SAStandardJob -Context $X -Job $J }
            Should -Invoke -ModuleName 'Stagearr.Core' Get-SAOmdbMetadata -Times 1 -ParameterFilter { -not $IncludePlot }
        }
    }
}
