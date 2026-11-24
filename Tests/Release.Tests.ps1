BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
    $script:repoRoot = Resolve-Path "$PSScriptRoot/.."
    $script:workflow = Get-Content -Raw (Join-Path $script:repoRoot '.github/workflows/release.yml')
}

# Self-update prunes every UpdateManagedEntries name that a new release lacks,
# so the ZIP payload and that list must name the same top-level entries.
Describe 'Release ZIP payload' {
    BeforeAll {
        $copyLine = [regex]::Match($script:workflow, 'cp -r (?<names>[^"\r\n]+) "\$stage/"')
        $script:stagedNames = @($copyLine.Groups['names'].Value.Trim() -split '\s+')
        if ($script:workflow -match 'mkdir -p "\$stage/Assets"') { $script:stagedNames += 'Assets' }
        $script:managed = InModuleScope 'Stagearr.Core' { $script:SAConstants.UpdateManagedEntries }
    }

    It 'stages exactly the entries self-update manages' {
        $script:stagedNames.Count | Should -BeGreaterThan 1
        ($script:stagedNames | Sort-Object) | Should -Be ($script:managed | Sort-Object)
    }

    It 'copies icon files that exist in the repo' {
        $iconLine = [regex]::Match($script:workflow, 'cp (?<files>docs/assets/brand/[^"\r\n]+) "\$stage/Assets/"')
        $iconLine.Success | Should -BeTrue
        foreach ($file in ($iconLine.Groups['files'].Value.Trim() -split '\s+')) {
            Join-Path $script:repoRoot $file | Should -Exist
        }
    }
}
