BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SAImportResultText TBA retry' {

    It 'returns Pending retry when TbaRetryScheduled is true' {
        InModuleScope 'Stagearr.Core' {
            $importResult = [PSCustomObject]@{
                Success            = $true
                Skipped            = $true
                ErrorType          = 'tba'
                TbaRetryScheduled  = $true
                QualityRejected    = $false
            }
            $text = Get-SAImportResultText -ImportResult $importResult
            $text | Should -Be 'Pending retry'
        }
    }

    It 'returns normal text for TBA skip without retry scheduled' {
        InModuleScope 'Stagearr.Core' {
            $importResult = [PSCustomObject]@{
                Success            = $true
                Skipped            = $true
                ErrorType          = 'tba'
                Message            = '1 file skipped (Episode title TBA)'
                QualityRejected    = $false
            }
            $text = Get-SAImportResultText -ImportResult $importResult
            $text | Should -Be 'Skipped (exists)'
        }
    }
}

Describe 'TBA retry email exceptions' {

    It 'adds info-level exceptions for retry scheduled' {
        InModuleScope 'Stagearr.Core' {
            $capturedMessages = [System.Collections.Generic.List[string]]::new()
            $capturedTypes = [System.Collections.Generic.List[string]]::new()
            Mock Add-SAEmailException {
                $capturedMessages.Add($Message)
                $capturedTypes.Add($Type)
            }

            $importResult = [PSCustomObject]@{
                Success            = $true
                Skipped            = $true
                ErrorType          = 'tba'
                TbaRetryScheduled  = $true
                QualityRejected    = $false
                Message            = '1 file skipped (Episode title TBA)'
            }

            $retryAfter = [datetime]::new(2026, 6, 5, 14, 30, 0)

            Add-SATbaRetryEmailExceptions -ImportResult $importResult -RetryAfter $retryAfter -ImportTarget 'Sonarr' -IsTbaRetry $false

            $capturedMessages.Count | Should -Be 2
            $capturedMessages[0] | Should -BeLike '*TBA*metadata refresh*'
            $capturedMessages[1] | Should -BeLike '*retry scheduled*2026*'
            $capturedTypes[0] | Should -Be 'Info'
            $capturedTypes[1] | Should -Be 'Info'
        }
    }

    It 'adds info-level exception for successful retry' {
        InModuleScope 'Stagearr.Core' {
            $capturedMessages = [System.Collections.Generic.List[string]]::new()
            $capturedTypes = [System.Collections.Generic.List[string]]::new()
            Mock Add-SAEmailException {
                $capturedMessages.Add($Message)
                $capturedTypes.Add($Type)
            }

            $importResult = [PSCustomObject]@{
                Success = $true
                Skipped = $false
            }

            Add-SATbaRetryEmailExceptions -ImportResult $importResult -RetryAfter $null -ImportTarget 'Sonarr' -IsTbaRetry $true

            $capturedMessages.Count | Should -Be 1
            $capturedMessages[0] | Should -BeLike '*automatically retried*TBA*'
            $capturedTypes[0] | Should -Be 'Info'
        }
    }

    It 'adds warning-level exception for failed retry' {
        InModuleScope 'Stagearr.Core' {
            $capturedMessages = [System.Collections.Generic.List[string]]::new()
            $capturedTypes = [System.Collections.Generic.List[string]]::new()
            Mock Add-SAEmailException {
                $capturedMessages.Add($Message)
                $capturedTypes.Add($Type)
            }

            $importResult = [PSCustomObject]@{
                Success = $true
                Skipped = $true
                ErrorType = 'tba'
                Message = '1 file skipped (Episode title TBA)'
            }

            Add-SATbaRetryEmailExceptions -ImportResult $importResult -RetryAfter $null -ImportTarget 'Sonarr' -IsTbaRetry $true

            $capturedMessages.Count | Should -Be 2
            $capturedMessages[0] | Should -BeLike '*TBA retry failed*'
            $capturedTypes[0] | Should -Be 'Warning'
            $capturedMessages[1] | Should -BeLike '*-Rerun*'
            $capturedTypes[1] | Should -Be 'Warning'
        }
    }
}
