#Requires -Version 5.1
Describe 'New-SAHttpResult RawContent handling' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'Stagearr.Core' 'Stagearr.Core.psm1'
        Import-Module $modulePath -Force
    }

    It 'accepts a string for RawContent' {
        $result = New-SAHttpResult -Success $true -RawContent 'hello'
        $result.RawContent | Should -Be 'hello'
    }

    It 'accepts $null for RawContent' {
        $result = New-SAHttpResult -Success $true -RawContent $null
        $result.RawContent | Should -BeNullOrEmpty
    }

    It 'accepts empty string for RawContent' {
        $result = New-SAHttpResult -Success $true -RawContent ''
        $result.RawContent | Should -Be ''
    }
}
