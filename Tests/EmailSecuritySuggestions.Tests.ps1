#Requires -Version 5.1
Describe 'Get-SAEmailTroubleshootingSuggestions for Security phase' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'Stagearr.Core' 'Stagearr.Core.psm1'
        Import-Module $modulePath -Force
    }

    It 'returns security-specific suggestions for Security phase' {
        $summary = @{
            FailurePhase = 'Security'
            FailureError = 'Dangerous files detected (probable malware): show.exe'
            ImportTarget = 'Sonarr'
        }
        $suggestions = Get-SAEmailTroubleshootingSuggestions -Summary $summary
        $suggestions.Count | Should -BeGreaterOrEqual 2
        $suggestions[0] | Should -BeLike '*malware*'
    }
}
