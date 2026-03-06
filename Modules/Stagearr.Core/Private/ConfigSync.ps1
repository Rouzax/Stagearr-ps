#Requires -Version 5.1
<#
.SYNOPSIS
    Configuration synchronization for Stagearr
.DESCRIPTION
    Compares user config.toml against config-sample.toml and reports
    missing or extra settings. Report-only — users manually add settings
    from config-sample.toml.
#>

function Compare-SAConfigSchema {
    <#
    .SYNOPSIS
        Compares user config against sample to find missing and extra settings.
    .DESCRIPTION
        Recursively walks both config structures and identifies:
        - Missing keys: Present in sample but not in user config
        - Extra keys: Present in user but not in sample (deprecated/typos)
    .PARAMETER UserConfig
        User's current configuration (hashtable).
    .PARAMETER SampleConfig
        Sample/reference configuration (hashtable).
    .PARAMETER Path
        Current path in the config tree (for recursion).
    .OUTPUTS
        PSCustomObject with MissingKeys and ExtraKeys arrays.
    .EXAMPLE
        $comparison = Compare-SAConfigSchema -UserConfig $user -SampleConfig $sample
        $comparison.MissingKeys  # Keys in sample but not in user
        $comparison.ExtraKeys    # Keys in user but not in sample (deprecated)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $UserConfig,

        [Parameter(Mandatory)]
        $SampleConfig,

        [Parameter()]
        [string]$Path = ''
    )

    $missing = [System.Collections.Generic.List[PSCustomObject]]::new()
    $extra = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Convert PSCustomObject to hashtable if needed
    if ($SampleConfig -is [PSCustomObject]) {
        $sampleHash = @{}
        foreach ($prop in $SampleConfig.PSObject.Properties) {
            $sampleHash[$prop.Name] = $prop.Value
        }
        $SampleConfig = $sampleHash
    }

    if ($UserConfig -is [PSCustomObject]) {
        $userHash = @{}
        foreach ($prop in $UserConfig.PSObject.Properties) {
            $userHash[$prop.Name] = $prop.Value
        }
        $UserConfig = $userHash
    }

    if ($null -eq $UserConfig) {
        $UserConfig = @{}
    }

    # Find missing keys (in sample but not in user)
    foreach ($key in $SampleConfig.Keys) {
        $currentPath = if ($Path) { "$Path.$key" } else { $key }
        $sampleValue = $SampleConfig[$key]

        if (-not $UserConfig.Contains($key)) {
            $missing.Add([PSCustomObject]@{
                Path         = $currentPath
                DefaultValue = $sampleValue
                Type         = 'Missing'
            })
        }
        elseif ($sampleValue -is [hashtable] -or $sampleValue -is [PSCustomObject]) {
            # Recurse into nested objects
            $nested = Compare-SAConfigSchema `
                -UserConfig $UserConfig[$key] `
                -SampleConfig $sampleValue `
                -Path $currentPath

            foreach ($item in $nested.MissingKeys) {
                $missing.Add($item)
            }
            foreach ($item in $nested.ExtraKeys) {
                $extra.Add($item)
            }
        }
    }

    # Find extra keys (in user but not in sample - deprecated/typos)
    foreach ($key in $UserConfig.Keys) {
        $currentPath = if ($Path) { "$Path.$key" } else { $key }

        if (-not $SampleConfig.Contains($key)) {
            $extra.Add([PSCustomObject]@{
                Path      = $currentPath
                UserValue = $UserConfig[$key]
                Type      = 'Extra'
            })
        }
    }

    return [PSCustomObject]@{
        MissingKeys = $missing.ToArray()
        ExtraKeys   = $extra.ToArray()
    }
}

function Sync-SAConfig {
    <#
    .SYNOPSIS
        Reports differences between user config and sample config.
    .DESCRIPTION
        Compares config.toml against config-sample.toml and reports
        missing and extra settings. Users should manually add missing
        settings from config-sample.toml.
    .PARAMETER ConfigPath
        Path to user's config.toml file.
    .PARAMETER SamplePath
        Path to config-sample.toml file. If not specified, looks for it
        in the same directory as ConfigPath.
    .OUTPUTS
        PSCustomObject with sync results.
    .EXAMPLE
        Sync-SAConfig -ConfigPath "C:\Stagearr\config.toml"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter()]
        [string]$SamplePath
    )

    # Resolve paths
    $ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)

    if (-not $SamplePath) {
        $configDir = Split-Path -Parent $ConfigPath
        $SamplePath = Join-Path $configDir 'config-sample.toml'
    }

    # Validate files exist
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }
    if (-not (Test-Path -LiteralPath $SamplePath)) {
        throw "Sample config not found: $SamplePath"
    }

    # Load configs
    try {
        $userContent = Get-Content -LiteralPath $ConfigPath -Raw
        $userConfig = ConvertFrom-SAToml -Content $userContent
    }
    catch {
        throw "Failed to parse config.toml: $_"
    }

    try {
        $sampleContent = Get-Content -LiteralPath $SamplePath -Raw
        $sampleConfig = ConvertFrom-SAToml -Content $sampleContent
    }
    catch {
        throw "Failed to parse config-sample.toml: $_"
    }

    # Find missing and extra settings
    $comparison = Compare-SAConfigSchema -UserConfig $userConfig -SampleConfig $sampleConfig

    $result = [PSCustomObject]@{
        ConfigPath      = $ConfigPath
        SamplePath      = $SamplePath
        MissingCount    = $comparison.MissingKeys.Count
        MissingSettings = $comparison.MissingKeys
        ExtraCount      = $comparison.ExtraKeys.Count
        ExtraSettings   = $comparison.ExtraKeys
        Message         = ''
    }

    $hasChanges = ($result.MissingCount -gt 0) -or ($result.ExtraCount -gt 0)

    if (-not $hasChanges) {
        $result.Message = 'Configuration is up to date - no changes needed.'
        return $result
    }

    # Report missing settings
    if ($result.MissingCount -gt 0) {
        Write-Host "`n[Config Sync] Found $($result.MissingCount) available setting(s) not in your config:" -ForegroundColor Yellow
        foreach ($item in $comparison.MissingKeys) {
            $valuePreview = if ($item.DefaultValue -is [hashtable] -or $item.DefaultValue -is [PSCustomObject]) {
                '{...}'
            }
            elseif ($item.DefaultValue -is [array]) {
                "[$(($item.DefaultValue | Select-Object -First 2) -join ', ')...]"
            }
            else {
                "$($item.DefaultValue)"
            }
            Write-Host "  + $($item.Path) = $valuePreview" -ForegroundColor Cyan
        }
    }

    # Report extra/deprecated settings
    if ($result.ExtraCount -gt 0) {
        Write-Host "`n[Config Sync] Found $($result.ExtraCount) unknown setting(s) in your config:" -ForegroundColor Yellow
        foreach ($item in $comparison.ExtraKeys) {
            $valuePreview = if ($item.UserValue -is [hashtable] -or $item.UserValue -is [PSCustomObject]) {
                '{...}'
            }
            elseif ($item.UserValue -is [array]) {
                "[$(($item.UserValue | Select-Object -First 2) -join ', ')...]"
            }
            else {
                "$($item.UserValue)"
            }
            Write-Host "  - $($item.Path) = $valuePreview" -ForegroundColor DarkGray
        }
    }

    $result.Message = "See config-sample.toml for available settings and documentation."
    Write-Host "`n$($result.Message)" -ForegroundColor Gray

    return $result
}

function Test-SAConfigSync {
    <#
    .SYNOPSIS
        Quick check if config needs synchronization.
    .DESCRIPTION
        Returns $true if the config has missing or extra settings.
        Use at startup to warn users about outdated configs.
    .PARAMETER ConfigPath
        Path to user's config.toml.
    .PARAMETER SamplePath
        Path to config-sample.toml.
    .OUTPUTS
        PSCustomObject with NeedsSync boolean and counts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter()]
        [string]$SamplePath
    )

    if (-not $SamplePath) {
        $configDir = Split-Path -Parent $ConfigPath
        $SamplePath = Join-Path $configDir 'config-sample.toml'
    }

    # If sample doesn't exist, can't check
    if (-not (Test-Path -LiteralPath $SamplePath)) {
        return [PSCustomObject]@{
            NeedsSync    = $false
            MissingCount = 0
            ExtraCount   = 0
            Message      = 'Sample config not found - skipping sync check'
        }
    }

    try {
        $userConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-SAToml
        $sampleConfig = Get-Content -LiteralPath $SamplePath -Raw | ConvertFrom-SAToml

        $comparison = Compare-SAConfigSchema -UserConfig $userConfig -SampleConfig $sampleConfig

        $needsSync = ($comparison.MissingKeys.Count -gt 0) -or ($comparison.ExtraKeys.Count -gt 0)

        return [PSCustomObject]@{
            NeedsSync    = $needsSync
            MissingCount = $comparison.MissingKeys.Count
            MissingPaths = $comparison.MissingKeys.Path
            ExtraCount   = $comparison.ExtraKeys.Count
            ExtraPaths   = $comparison.ExtraKeys.Path
            Message      = if ($needsSync) {
                $parts = @()
                if ($comparison.MissingKeys.Count -gt 0) { $parts += "$($comparison.MissingKeys.Count) missing" }
                if ($comparison.ExtraKeys.Count -gt 0) { $parts += "$($comparison.ExtraKeys.Count) deprecated" }
                "Config has $($parts -join ' and ') setting(s). Run: .\Stagearr.ps1 -SyncConfig"
            } else {
                'Config is up to date'
            }
        }
    }
    catch {
        return [PSCustomObject]@{
            NeedsSync    = $false
            MissingCount = 0
            ExtraCount   = 0
            Message      = "Error checking config: $_"
        }
    }
}

function Get-SAConfigSyncReport {
    <#
    .SYNOPSIS
        Generates a detailed report of config differences.
    .DESCRIPTION
        Creates a formatted report showing all missing and extra settings
        with their values. Useful for manual review.
    .PARAMETER ConfigPath
        Path to user's config.toml.
    .PARAMETER SamplePath
        Path to config-sample.toml.
    .OUTPUTS
        Formatted string report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter()]
        [string]$SamplePath
    )

    if (-not $SamplePath) {
        $configDir = Split-Path -Parent $ConfigPath
        $SamplePath = Join-Path $configDir 'config-sample.toml'
    }

    $userConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-SAToml
    $sampleConfig = Get-Content -LiteralPath $SamplePath -Raw | ConvertFrom-SAToml

    $comparison = Compare-SAConfigSchema -UserConfig $userConfig -SampleConfig $sampleConfig

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("Stagearr Configuration Sync Report")
    [void]$sb.AppendLine("=" * 50)
    [void]$sb.AppendLine("Config:  $ConfigPath")
    [void]$sb.AppendLine("Sample:  $SamplePath")
    [void]$sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine()

    $hasChanges = ($comparison.MissingKeys.Count -gt 0) -or ($comparison.ExtraKeys.Count -gt 0)

    if (-not $hasChanges) {
        [void]$sb.AppendLine("Configuration is fully synchronized - no changes needed.")
    }
    else {
        if ($comparison.MissingKeys.Count -gt 0) {
            [void]$sb.AppendLine("Found $($comparison.MissingKeys.Count) available setting(s) not in your config:")
            [void]$sb.AppendLine()

            $grouped = $comparison.MissingKeys | Group-Object { ($_.Path -split '\.')[0] }

            foreach ($group in $grouped) {
                [void]$sb.AppendLine("[$($group.Name)]")
                foreach ($item in $group.Group) {
                    $indent = "  "
                    [void]$sb.AppendLine("$indent+ $($item.Path)")

                    $defaultStr = if ($item.DefaultValue -is [hashtable] -or $item.DefaultValue -is [PSCustomObject]) {
                        '{...}'
                    }
                    elseif ($item.DefaultValue -is [array]) {
                        "[$($item.DefaultValue -join ', ')]"
                    }
                    else {
                        "$($item.DefaultValue)"
                    }
                    [void]$sb.AppendLine("$indent  Default: $defaultStr")
                    [void]$sb.AppendLine()
                }
            }
        }

        if ($comparison.ExtraKeys.Count -gt 0) {
            [void]$sb.AppendLine("Found $($comparison.ExtraKeys.Count) unknown setting(s) in your config:")
            [void]$sb.AppendLine()

            $grouped = $comparison.ExtraKeys | Group-Object { ($_.Path -split '\.')[0] }

            foreach ($group in $grouped) {
                [void]$sb.AppendLine("[$($group.Name)]")
                foreach ($item in $group.Group) {
                    $indent = "  "
                    [void]$sb.AppendLine("$indent- $($item.Path)")

                    $valueStr = if ($item.UserValue -is [hashtable] -or $item.UserValue -is [PSCustomObject]) {
                        '{...}'
                    }
                    elseif ($item.UserValue -is [array]) {
                        "[$($item.UserValue -join ', ')]"
                    }
                    else {
                        "$($item.UserValue)"
                    }
                    [void]$sb.AppendLine("$indent  Current: $valueStr")
                    [void]$sb.AppendLine()
                }
            }
        }

        [void]$sb.AppendLine("-" * 50)
        [void]$sb.AppendLine("See config-sample.toml for available settings and documentation.")
    }

    return $sb.ToString()
}
