BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Remove-SAArrQueueItem' {
    It 'calls DELETE with correct URL and parameters' {
        InModuleScope 'Stagearr.Core' {
            Mock Get-SAImporterBaseUrl {
                return @{ Url = 'http://localhost:8989'; HostHeader = $null }
            }

            Mock Invoke-SAWebRequest {
                return [PSCustomObject]@{
                    Success      = $true
                    Data         = $null
                    ErrorMessage = $null
                }
            }

            $config = @{
                host   = 'localhost'
                port   = 8989
                apiKey = 'testkey123'
                ssl    = $false
                urlRoot = ''
            }

            $result = Remove-SAArrQueueItem -Config $config -QueueId 12345 -Reason 'Duplicate download'

            $result.Success | Should -BeTrue

            Should -Invoke Invoke-SAWebRequest -Times 1 -ParameterFilter {
                $Uri -like '*/api/v3/queue/12345*' -and
                $Uri -like '*removeFromClient=true*' -and
                $Uri -like '*blocklist=true*' -and
                $Uri -like '*skipRedownload=true*' -and
                $Method -eq 'DELETE'
            }
        }
    }

    It 'returns failure when API call fails' {
        InModuleScope 'Stagearr.Core' {
            Mock Get-SAImporterBaseUrl {
                return @{ Url = 'http://localhost:8989'; HostHeader = $null }
            }

            Mock Invoke-SAWebRequest {
                return [PSCustomObject]@{
                    Success      = $false
                    Data         = $null
                    ErrorMessage = 'Connection refused'
                }
            }

            $config = @{
                host   = 'localhost'
                port   = 8989
                apiKey = 'testkey123'
                ssl    = $false
                urlRoot = ''
            }

            $result = Remove-SAArrQueueItem -Config $config -QueueId 12345 -Reason 'Duplicate download'

            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Be 'Connection refused'
        }
    }
}
