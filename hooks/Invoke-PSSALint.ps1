#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-commit lint hook: runs PSScriptAnalyzer on the staged PowerShell files.

.DESCRIPTION
    Mirrors the lint job in .github/workflows/ci.yml. Uses the repo settings
    file (PSScriptAnalyzerSettings.psd1) and blocks the commit only when
    Error-severity findings are present; Warnings are printed but advisory.

    Invoked by pre-commit, which passes the staged .ps1/.psm1/.psd1 files as
    arguments. Run directly with no arguments to exit cleanly.
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'

if (-not $Path -or $Path.Count -eq 0) {
    exit 0
}

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Error "PSScriptAnalyzer is not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser"
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

# Syntax-error check. PSScriptAnalyzer reports unparseable files with Severity
# 'ParseError', which the repo settings file (Severity = Error,Warning) filters
# out, so a file that does not parse would otherwise slip through. Catch it
# directly with the language parser before running the rule analysis.
$parseErrors = foreach ($file in $Path) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    foreach ($e in $errs) {
        [pscustomobject]@{ File = $file; Line = $e.Extent.StartLineNumber; Message = $e.Message }
    }
}

if ($parseErrors) {
    $parseErrors | Format-Table File, Line, Message -AutoSize | Out-String -Width 200 | Write-Host
}

# Invoke-ScriptAnalyzer -Path takes a single path, so analyze each staged file.
$results = foreach ($file in $Path) {
    Invoke-ScriptAnalyzer -Path $file -Settings $settings
}

if ($results) {
    $results | Sort-Object Severity, ScriptName, Line |
        Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize |
        Out-String -Width 200 | Write-Host
}

$errors   = @($results | Where-Object Severity -eq 'Error')
$warnings = @($results | Where-Object Severity -eq 'Warning')
$parseCount = @($parseErrors).Count
Write-Host ("PSScriptAnalyzer  ParseErrors: {0}  Errors: {1}  Warnings: {2}" -f $parseCount, $errors.Count, $warnings.Count)

# Gate on parse errors and Error severity, matching the CI lint job (plus the
# syntax check above). Warnings are advisory.
if ($parseCount -gt 0 -or $errors.Count -gt 0) {
    Write-Error "PSScriptAnalyzer found $parseCount parse error(s) and $($errors.Count) error(s). Commit blocked."
    exit 1
}

exit 0
