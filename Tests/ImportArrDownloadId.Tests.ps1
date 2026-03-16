BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Invoke-SAArrManualImportExecute per-file downloadId' {

    Context 'When DownloadId is provided' {

        It 'should include downloadId on each file in the command body' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedBody = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    if ($Method -eq 'POST') {
                        $script:CapturedBody = $Body
                        return @{
                            Success = $true
                            Data    = @{ id = 12345 }
                        }
                    }
                    # Poll response - command completed
                    return @{
                        Success = $true
                        Data    = @{ status = 'completed'; result = 'successful' }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $files = @(
                    @{
                        path       = 'C:\Test\S01E01.mkv'
                        quality    = @{ quality = @{ id = 3; name = 'WEBDL-1080p' }; revision = @{ version = 1 } }
                        series     = @{ id = 100 }
                        episodes   = @( @{ id = 200 } )
                        languages  = @( @{ id = 1; name = 'English' } )
                        seriesId   = 100
                    },
                    @{
                        path       = 'C:\Test\S01E02.mkv'
                        quality    = @{ quality = @{ id = 3; name = 'WEBDL-1080p' }; revision = @{ version = 2; isRepack = $true } }
                        series     = @{ id = 100 }
                        episodes   = @( @{ id = 201 } )
                        languages  = @( @{ id = 1; name = 'English' } )
                        seriesId   = 100
                    }
                )

                $null = Invoke-SAArrManualImportExecute -AppType 'Sonarr' -Config $config -Files $files -DownloadId 'AABB1234'

                # Parse the captured body (it's JSON-encoded by Invoke-SAWebRequest)
                $body = $script:CapturedBody
                if ($body -is [string]) {
                    $body = $body | ConvertFrom-Json
                }

                # Both files should be present
                $body.files.Count | Should -Be 2

                # Each file should have downloadId
                $body.files | ForEach-Object {
                    $_.downloadId | Should -Be 'AABB1234'
                }

                # Command body itself should NOT have downloadId (it's ignored by Sonarr)
                $body.PSObject.Properties.Name | Should -Not -Contain 'downloadId'
            }
        }
    }

    Context 'When DownloadId is not provided' {

        It 'should not include downloadId on files' {
            InModuleScope 'Stagearr.Core' {
                $script:CapturedBody = $null

                Mock Write-SAVerbose {}
                Mock Invoke-SAWebRequest {
                    if ($Method -eq 'POST') {
                        $script:CapturedBody = $Body
                        return @{
                            Success = $true
                            Data    = @{ id = 12345 }
                        }
                    }
                    return @{
                        Success = $true
                        Data    = @{ status = 'completed'; result = 'successful' }
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $files = @(
                    @{
                        path     = 'C:\Test\Movie.mkv'
                        quality  = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                        movie    = @{ id = 50 }
                        movieId  = 50
                    }
                )

                $null = Invoke-SAArrManualImportExecute -AppType 'Radarr' -Config $config -Files $files

                $body = $script:CapturedBody
                if ($body -is [string]) {
                    $body = $body | ConvertFrom-Json
                }

                $body.files[0].PSObject.Properties.Name | Should -Not -Contain 'downloadId'
            }
        }
    }
}
