BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'GuessIt API array field normalization' {

    Context 'Get-SAGuessItInfo normalizes array fields' {

        It 'should return scalar Source when API returns source as array' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    return @{
                        Success = $true
                        Data    = @{
                            type              = 'episode'
                            title             = 'The Boys'
                            year              = $null
                            season            = 5
                            episode           = 5
                            language          = $null
                            source            = @('Web', 'Ultra HD Blu-ray')
                            screen_size       = '2160p'
                            streaming_service = 'Amazon Prime'
                            release_group     = 'FLUX'
                            other             = @('HDR10')
                        }
                    }
                }

                $result = Get-SAGuessItInfo -FileName 'The.Boys.S05E05.2160p.AMZN.WEB-DL.mkv' -ApiKey 'test-key'

                $result.Source | Should -BeOfType [string]
                $result.Source | Should -Be 'Web'
            }
        }

        It 'should return scalar StreamingService when API returns streaming_service as array' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    return @{
                        Success = $true
                        Data    = @{
                            type              = 'episode'
                            title             = 'The Boys'
                            year              = $null
                            season            = 5
                            episode           = 5
                            language          = $null
                            source            = 'Web'
                            screen_size       = '2160p'
                            streaming_service = @('Showtime', 'Amazon Prime')
                            release_group     = 'FLUX'
                            other             = @('HDR10')
                        }
                    }
                }

                $result = Get-SAGuessItInfo -FileName 'The.Boys.S05E05.2160p.AMZN.WEB-DL.mkv' -ApiKey 'test-key'

                $result.StreamingService | Should -BeOfType [string]
                $result.StreamingService | Should -Be 'Showtime'
            }
        }
    }
}
