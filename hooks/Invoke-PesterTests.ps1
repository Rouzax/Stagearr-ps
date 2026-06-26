#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-push test hook: runs the full Pester suite.

.DESCRIPTION
    Mirrors the test job in .github/workflows/ci.yml. Runs every spec under
    Tests/ and fails the push on any failing test. Requires Pester 5+.
#>

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Pester | Where-Object Version -ge ([version]'5.0'))) {
    Write-Error "Pester 5+ is not installed. Run: Install-Module Pester -Scope CurrentUser"
    exit 1
}

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

$repoRoot = Split-Path -Parent $PSScriptRoot

$config = New-PesterConfiguration
$config.Run.Path = (Join-Path $repoRoot 'Tests')
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'

Invoke-Pester -Configuration $config
