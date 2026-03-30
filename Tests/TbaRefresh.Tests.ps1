BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Invoke-SAArrSeriesRefresh' {

    Context 'successful refresh' {
        It 'sends RefreshSeries command and returns success' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Invoke-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success   = $true
                        CommandId = 12345
                        Status    = 'queued'
                        Message   = $null
                    }
                }

                Mock Wait-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success  = $true
                        Message  = 'Completed'
                        Duration = 10
                        Status   = 'completed'
                        Result   = 'successful'
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrSeriesRefresh -Config $config -SeriesId 100

                $result.Success | Should -BeTrue

                # Verify RefreshSeries command was sent with correct body
                Should -Invoke Invoke-SAImporterCommand -Times 1 -ParameterFilter {
                    $Body.name -eq 'RefreshSeries' -and $Body.seriesId -eq 100
                }

                # Verify polling used the TBA timeout
                Should -Invoke Wait-SAImporterCommand -Times 1 -ParameterFilter {
                    $CommandId -eq 12345 -and $TimeoutMinutes -eq $script:SAConstants.TbaRefreshTimeoutMinutes
                }
            }
        }
    }

    Context 'command send failure' {
        It 'returns failure without polling' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Invoke-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success   = $false
                        CommandId = $null
                        Status    = $null
                        Message   = 'API error'
                    }
                }

                Mock Wait-SAImporterCommand {}

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrSeriesRefresh -Config $config -SeriesId 100

                $result.Success | Should -BeFalse
                Should -Invoke Wait-SAImporterCommand -Times 0
            }
        }
    }
}
