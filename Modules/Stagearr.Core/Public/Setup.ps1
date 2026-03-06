#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive setup wizard for Stagearr configuration
.DESCRIPTION
    Walks through all configuration sections with prompts, supporting both
    new config creation and editing existing config.toml files.
#>

function Invoke-SASetup {
    <#
    .SYNOPSIS
        Interactive setup wizard to create or edit config.toml.
    .DESCRIPTION
        Walks through configuration sections in order, prompting for values.
        Shows current/default values in brackets — pressing Enter keeps them.
        Writes config.toml using the sample file's comment structure.
    .PARAMETER ConfigPath
        Path to config.toml (created if it doesn't exist).
    .PARAMETER SamplePath
        Path to config-sample.toml (used as template for output).
    .EXAMPLE
        Invoke-SASetup -ConfigPath "C:\Stagearr\config.toml" -SamplePath "C:\Stagearr\config-sample.toml"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$SamplePath
    )

    # Load existing config if present
    $existing = @{}
    $isUpdate = Test-Path -LiteralPath $ConfigPath
    if ($isUpdate) {
        try {
            $content = Get-Content -LiteralPath $ConfigPath -Raw
            $existing = ConvertFrom-SAToml -Content $content
        }
        catch {
            Write-Warning "Could not parse existing config, starting fresh: $_"
            $existing = @{}
            $isUpdate = $false
        }
    }

    # Start with defaults
    $config = Merge-SAConfig -UserConfig $existing -DefaultConfig $script:SAConfigDefaults

    Write-Host ""
    if ($isUpdate) {
        Write-Host "Editing existing configuration: $ConfigPath" -ForegroundColor Cyan
        Write-Host "Press Enter to keep current values shown in [brackets]." -ForegroundColor Gray
    }
    else {
        Write-Host "Creating new configuration: $ConfigPath" -ForegroundColor Cyan
        Write-Host "Press Enter to accept default values shown in [brackets]." -ForegroundColor Gray
    }

    # --- Section 1: Paths ---
    Write-Host "`n--- Paths ---" -ForegroundColor Yellow
    $config.paths.stagingRoot = Read-SASetupValue -Prompt "Staging folder path" -Current $config.paths.stagingRoot
    $config.paths.logArchive = Read-SASetupValue -Prompt "Log archive folder path" -Current $config.paths.logArchive
    $config.paths.queueRoot = Read-SASetupValue -Prompt "Job queue folder path" -Current $config.paths.queueRoot

    # --- Section 2: Tools ---
    Write-Host "`n--- Tools ---" -ForegroundColor Yellow

    # Auto-detect tool paths if not already configured
    $toolDefaults = @{
        winrar       = @{ Exe = 'Rar.exe';         Prompt = 'Path to RAR.exe';         SearchPaths = @(
            "$env:ProgramFiles\WinRAR\Rar.exe"
            "${env:ProgramFiles(x86)}\WinRAR\Rar.exe"
        )}
        mkvmerge     = @{ Exe = 'mkvmerge.exe';    Prompt = 'Path to mkvmerge.exe';    SearchPaths = @(
            "$env:ProgramFiles\MKVToolNix\mkvmerge.exe"
            "${env:ProgramFiles(x86)}\MKVToolNix\mkvmerge.exe"
        )}
        mkvextract   = @{ Exe = 'mkvextract.exe';  Prompt = 'Path to mkvextract.exe';  SearchPaths = @(
            "$env:ProgramFiles\MKVToolNix\mkvextract.exe"
            "${env:ProgramFiles(x86)}\MKVToolNix\mkvextract.exe"
        )}
        subtitleEdit = @{ Exe = 'SubtitleEdit.exe'; Prompt = 'Path to SubtitleEdit.exe (leave empty to skip)'; SearchPaths = @(
            "$env:ProgramFiles\Subtitle Edit\SubtitleEdit.exe"
            "${env:ProgramFiles(x86)}\Subtitle Edit\SubtitleEdit.exe"
        )}
    }

    foreach ($tool in @('winrar', 'mkvmerge', 'mkvextract', 'subtitleEdit')) {
        $current = $config.tools[$tool]
        if ([string]::IsNullOrWhiteSpace($current)) {
            # Try PATH first
            $found = Get-Command $toolDefaults[$tool].Exe -ErrorAction SilentlyContinue
            if ($found) {
                $current = $found.Source
            } else {
                # Check common install locations
                foreach ($candidate in $toolDefaults[$tool].SearchPaths) {
                    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                        $current = $candidate
                        break
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                Write-Host "  Auto-detected: $current" -ForegroundColor Green
            }
        }
        $allowEmpty = $tool -eq 'subtitleEdit'
        $config.tools[$tool] = Read-SASetupValue -Prompt $toolDefaults[$tool].Prompt -Current $current -AllowEmpty:$allowEmpty
    }

    # --- Section 3: Labels ---
    Write-Host "`n--- Labels ---" -ForegroundColor Yellow
    $config.labels.tv = Read-SASetupValue -Prompt "TV label" -Current $config.labels.tv
    $config.labels.movie = Read-SASetupValue -Prompt "Movie label" -Current $config.labels.movie
    $config.labels.skip = Read-SASetupValue -Prompt "Skip label (no processing)" -Current $config.labels.skip
    $config.labels.tvLabels = Read-SASetupArray -Prompt "Additional TV labels (comma-separated)" -Current $config.labels.tvLabels
    $config.labels.movieLabels = Read-SASetupArray -Prompt "Additional movie labels (comma-separated)" -Current $config.labels.movieLabels

    # --- Section 4: Processing ---
    Write-Host "`n--- Processing ---" -ForegroundColor Yellow
    $config.processing.tvImporter = Read-SASetupChoice -Prompt "TV Importer" -Choices @('Medusa', 'Sonarr') -Current $config.processing.tvImporter
    $config.processing.cleanupStaging = Read-SASetupBool -Prompt "Clean up staging folder after processing" -Current $config.processing.cleanupStaging

    # --- Section 5: Video ---
    Write-Host "`n--- Video ---" -ForegroundColor Yellow
    $config.video.mp4Remux.enabled = Read-SASetupBool -Prompt "Remux MP4/M4V files to MKV" -Current $config.video.mp4Remux.enabled

    # --- Section 6: Subtitles ---
    Write-Host "`n--- Subtitles ---" -ForegroundColor Yellow
    $config.subtitles.wantedLanguages = Read-SASetupArray -Prompt "Wanted languages (comma-separated, e.g. eng, nld)" -Current $config.subtitles.wantedLanguages
    $config.subtitles.extraction.enabled = Read-SASetupBool -Prompt "Extract subtitles from MKV" -Current $config.subtitles.extraction.enabled
    $config.subtitles.stripping.enabled = Read-SASetupBool -Prompt "Strip unwanted subtitle tracks from MKV" -Current $config.subtitles.stripping.enabled
    $config.subtitles.cleanup.enabled = Read-SASetupBool -Prompt "Clean subtitles with SubtitleEdit" -Current $config.subtitles.cleanup.enabled

    $config.subtitles.openSubtitles.enabled = Read-SASetupBool -Prompt "Download subtitles from OpenSubtitles" -Current $config.subtitles.openSubtitles.enabled
    if ($config.subtitles.openSubtitles.enabled) {
        $config.subtitles.openSubtitles.user = Read-SASetupValue -Prompt "  OpenSubtitles username" -Current $config.subtitles.openSubtitles.user
        $config.subtitles.openSubtitles.password = Read-SASetupValue -Prompt "  OpenSubtitles password" -Current $config.subtitles.openSubtitles.password
        $config.subtitles.openSubtitles.apiKey = Read-SASetupValue -Prompt "  OpenSubtitles API key" -Current $config.subtitles.openSubtitles.apiKey

        Write-Host "  Subtitle filters (include, exclude, or only):" -ForegroundColor Gray
        foreach ($filter in @('hearingImpaired', 'foreignPartsOnly', 'machineTranslated', 'aiTranslated')) {
            $config.subtitles.openSubtitles.filters[$filter] = Read-SASetupChoice `
                -Prompt "    $filter" `
                -Choices @('include', 'exclude', 'only') `
                -Current $config.subtitles.openSubtitles.filters[$filter]
        }
    }

    # --- Section 7: Importers ---
    Write-Host "`n--- Importers ---" -ForegroundColor Yellow
    foreach ($importer in @('radarr', 'sonarr', 'medusa')) {
        $displayName = $importer.Substring(0, 1).ToUpper() + $importer.Substring(1)
        $config.importers[$importer].enabled = Read-SASetupBool -Prompt "Enable $displayName" -Current $config.importers[$importer].enabled

        if ($config.importers[$importer].enabled) {
            $config.importers[$importer].host = Read-SASetupValue -Prompt "  $displayName host" -Current $config.importers[$importer].host
            $config.importers[$importer].port = [int](Read-SASetupValue -Prompt "  $displayName port" -Current $config.importers[$importer].port)
            $config.importers[$importer].apiKey = Read-SASetupValue -Prompt "  $displayName API key" -Current $config.importers[$importer].apiKey
            $config.importers[$importer].ssl = Read-SASetupBool -Prompt "  $displayName use SSL" -Current $config.importers[$importer].ssl

            if ($importer -ne 'medusa') {
                $config.importers[$importer].importMode = Read-SASetupChoice `
                    -Prompt "  $displayName import mode" `
                    -Choices @('move', 'copy') `
                    -Current $config.importers[$importer].importMode
            }
        }
    }

    # --- Section 8: Notifications ---
    Write-Host "`n--- Notifications ---" -ForegroundColor Yellow
    $config.notifications.email.enabled = Read-SASetupBool -Prompt "Enable email notifications" -Current $config.notifications.email.enabled
    if ($config.notifications.email.enabled) {
        $config.notifications.email.to = Read-SASetupValue -Prompt "  Email to" -Current $config.notifications.email.to
        $config.notifications.email.from = Read-SASetupValue -Prompt "  Email from" -Current $config.notifications.email.from
        $config.notifications.email.smtp.server = Read-SASetupValue -Prompt "  SMTP server" -Current $config.notifications.email.smtp.server
        $config.notifications.email.smtp.port = [int](Read-SASetupValue -Prompt "  SMTP port" -Current $config.notifications.email.smtp.port)
        $config.notifications.email.smtp.user = Read-SASetupValue -Prompt "  SMTP username" -Current $config.notifications.email.smtp.user
        $config.notifications.email.smtp.password = Read-SASetupValue -Prompt "  SMTP password" -Current $config.notifications.email.smtp.password
    }

    $config.omdb.enabled = Read-SASetupBool -Prompt "Enable OMDb metadata (for email enrichment)" -Current $config.omdb.enabled
    if ($config.omdb.enabled) {
        $config.omdb.apiKey = Read-SASetupValue -Prompt "  OMDb API key (get free key at omdbapi.com/apikey.aspx)" -Current $config.omdb.apiKey
    }

    # --- Review & Save ---
    Write-Host "`n--- Summary ---" -ForegroundColor Yellow
    Write-Host "Paths:         $($config.paths.stagingRoot)"
    Write-Host "Tools:         WinRAR=$([bool]$config.tools.winrar), mkvmerge=$([bool]$config.tools.mkvmerge)"
    Write-Host "TV Importer:   $($config.processing.tvImporter)"
    Write-Host "Subtitles:     languages=$($config.subtitles.wantedLanguages -join ','), OpenSubs=$($config.subtitles.openSubtitles.enabled)"
    Write-Host "Importers:     Radarr=$($config.importers.radarr.enabled), Sonarr=$($config.importers.sonarr.enabled), Medusa=$($config.importers.medusa.enabled)"
    Write-Host "Email:         $($config.notifications.email.enabled)"
    Write-Host ""

    $save = Read-SASetupBool -Prompt "Save configuration" -Current $true
    if (-not $save) {
        Write-Host "Setup cancelled." -ForegroundColor Yellow
        return
    }

    # Backup existing config
    if ($isUpdate) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = "$ConfigPath.backup-$timestamp"
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
        Write-Host "Backup created: $backupPath" -ForegroundColor Green
    }

    # Write config using sample template
    $toml = ConvertTo-SAToml -Config $config -SamplePath $SamplePath
    Set-Content -LiteralPath $ConfigPath -Value $toml -Encoding UTF8 -Force

    Write-Host "Configuration saved: $ConfigPath" -ForegroundColor Green
}

function Read-SASetupValue {
    <#
    .SYNOPSIS
        Prompts for a string value with a default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        $Current = '',

        [switch]$AllowEmpty
    )

    $displayCurrent = if ([string]::IsNullOrEmpty($Current)) { '' } else { $Current }
    $promptText = if ($displayCurrent) {
        "$Prompt [$displayCurrent]: "
    }
    else {
        "${Prompt}: "
    }

    $input = Read-Host -Prompt $promptText.TrimEnd(': ')
    if ([string]::IsNullOrWhiteSpace($input)) {
        if ([string]::IsNullOrEmpty($displayCurrent) -and -not $AllowEmpty) {
            # Re-prompt if required and empty
            Write-Host "  Value required." -ForegroundColor Red
            return Read-SASetupValue -Prompt $Prompt -Current $Current
        }
        return $Current
    }
    return $input.Trim()
}

function Read-SASetupBool {
    <#
    .SYNOPSIS
        Prompts for a yes/no value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter()]
        [bool]$Current = $true
    )

    $hint = if ($Current) { 'Y/n' } else { 'y/N' }
    $input = Read-Host -Prompt "$Prompt [$hint]"

    if ([string]::IsNullOrWhiteSpace($input)) {
        return $Current
    }

    switch ($input.Trim().ToLower()) {
        'y'   { return $true }
        'yes' { return $true }
        'n'   { return $false }
        'no'  { return $false }
        default {
            Write-Host "  Please enter y or n." -ForegroundColor Red
            return Read-SASetupBool -Prompt $Prompt -Current $Current
        }
    }
}

function Read-SASetupChoice {
    <#
    .SYNOPSIS
        Prompts for a choice from a list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string[]]$Choices,

        [Parameter()]
        [string]$Current = ''
    )

    $choiceDisplay = for ($j = 0; $j -lt $Choices.Count; $j++) {
        $marker = if ($Choices[$j] -eq $Current) { '*' } else { ' ' }
        "[$($j + 1)]$marker$($Choices[$j])"
    }
    $input = Read-Host -Prompt "$Prompt $($choiceDisplay -join '  ') [$Current]"

    if ([string]::IsNullOrWhiteSpace($input)) {
        return $Current
    }

    # Accept number or exact text
    if ($input -match '^\d+$') {
        $idx = [int]$input - 1
        if ($idx -ge 0 -and $idx -lt $Choices.Count) {
            return $Choices[$idx]
        }
    }

    $match = $Choices | Where-Object { $_ -eq $input }
    if ($match) {
        return $match
    }

    Write-Host "  Invalid choice." -ForegroundColor Red
    return Read-SASetupChoice -Prompt $Prompt -Choices $Choices -Current $Current
}

function Read-SASetupArray {
    <#
    .SYNOPSIS
        Prompts for a comma-separated list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter()]
        [string[]]$Current = @()
    )

    $displayCurrent = $Current -join ', '
    $input = Read-Host -Prompt "$Prompt [$displayCurrent]"

    if ([string]::IsNullOrWhiteSpace($input)) {
        # Use comma operator to prevent PowerShell from unrolling empty arrays to $null
        return , $Current
    }

    $items = @($input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    return , $items
}
