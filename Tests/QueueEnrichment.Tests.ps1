BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SAArrQueueRecords' {

    Context 'When DownloadId is provided' {

        It 'should query the queue API with downloadId filter' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedUri = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    $script:CapturedUri = $Uri
                    return @{
                        Success = $true
                        Data    = @{
                            records = @(
                                @{
                                    seriesId  = 380
                                    episodeId = 9766
                                    downloadId = 'ABC123'
                                }
                            )
                        }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAArrQueueRecords -Config $config -DownloadId 'ABC123'

                $script:CapturedUri | Should -Match 'downloadId=ABC123'
                $result.Count | Should -Be 1
                $result[0].seriesId | Should -Be 380
            }
        }
    }

    Context 'When DownloadId is empty' {

        It 'should return empty array without calling API' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {}

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAArrQueueRecords -Config $config -DownloadId ''

                $result | Should -BeNullOrEmpty
                Should -Invoke Invoke-SAWebRequest -Times 0
            }
        }
    }

    Context 'When API call fails' {

        It 'should return empty array and not throw' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    return @{ Success = $false; ErrorMessage = 'Connection refused' }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Get-SAArrQueueRecords -Config $config -DownloadId 'ABC123'

                $result | Should -BeNullOrEmpty
            }
        }
    }
}
