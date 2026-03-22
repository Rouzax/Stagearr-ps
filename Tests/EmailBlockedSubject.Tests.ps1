#Requires -Version 5.1
Describe 'Email subject with Blocked result' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'Stagearr.Core' 'Stagearr.Core.psm1'
        Import-Module $modulePath -Force
    }

    It 'generates Blocked prefix for Blocked result' {
        $placeholders = Build-SASubjectPlaceholders -Name 'Show S01E01' -Label 'TV' -Result 'Blocked'
        $placeholders.result | Should -Be 'Blocked: '
    }

    It 'produces correct subject with Blocked result' {
        $placeholders = Build-SASubjectPlaceholders -Name 'Show S01E01' -Label 'TV' -Result 'Blocked'
        $subject = Format-SAEmailSubject -Template 'none' -Placeholders $placeholders
        $subject | Should -Be 'Blocked: TV: Show S01E01'
    }
}
