#Requires -Version 5.1
<#
.SYNOPSIS
    Configuration loader and validator for Stagearr
.DESCRIPTION
    Loads, validates, and provides access to Stagearr configuration.
    Supports schema validation and provides sensible defaults.
#>

# Default configuration values
$script:SAConfigDefaults = @{
    paths = @{
        stagingRoot  = ''
        logArchive   = ''
        queueRoot    = ''
    }
    labels = @{
        tv          = 'TV'
        movie       = 'Movie'
        skip        = 'NoProcess'
        tvLabels    = @()
        movieLabels = @()
    }
    processing = @{
        tvImporter       = 'Medusa'
        cleanupStaging   = $true
        staleLockMinutes = 15
    }
    tools = @{
        winrar       = ''
        mkvmerge     = ''
        mkvextract   = ''
        subtitleEdit = ''
    }
    video = @{
        mp4Remux = @{
            enabled = $true
        }
    }
    subtitles = @{
        wantedLanguages       = @('eng')
        namePatternsToRemove  = @('Forced')
        extraction = @{
            enabled              = $true
            duplicateLanguageMode = 'all'
        }
        stripping = @{
            enabled = $true
        }
        cleanup = @{
            enabled = $true
        }
        openSubtitles = @{
            enabled       = $false
            user          = ''
            password      = ''
            apiKey        = ''
            uploadCleaned = $false
            uploadDiagnosticMode = $false
            filters  = @{
                hearingImpaired   = 'exclude'
                foreignPartsOnly  = 'exclude'
                machineTranslated = 'exclude'
                aiTranslated      = 'include'
            }
        }
    }
    importers = @{
        radarr = @{
            enabled        = $false
            host           = 'localhost'
            port           = 7878
            apiKey         = ''
            ssl            = $false
            urlRoot        = ''
            timeoutMinutes = 15
            remotePath     = ''
            importMode     = 'move'
        }
        sonarr = @{
            enabled        = $false
            host           = 'localhost'
            port           = 8989
            apiKey         = ''
            ssl            = $false
            urlRoot        = ''
            timeoutMinutes = 15
            remotePath     = ''
            importMode     = 'move'
        }
        medusa = @{
            enabled        = $false
            host           = 'localhost'
            port           = 8081
            apiKey         = ''
            ssl            = $false
            urlRoot        = ''
            timeoutMinutes = 15
            remotePath     = ''
        }
    }
    notifications = @{
        email = @{
            enabled         = $false
            to              = ''
            from            = ''
            fromName        = 'Stagearr'
            subjectStyle    = 'detailed'
            subjectTemplate = ''
            smtp = @{
                server   = ''
                port     = 465
                user     = ''
                password = ''
            }
            metadata = @{
                source = 'auto'
                poster = @{
                    size = 'w185'
                }
            }
        }
    }
    omdb = @{
        enabled        = $false
        apiKey         = ''
        timeoutSeconds = 5
        poster = @{
            enabled = $true
        }
        display = @{
            plot          = $false
            plotMaxLength = 150
        }
    }
    logging = @{
        dateFormat    = 'yyyy.MM.dd_HH.mm.ss'
        consoleColors = $true
    }
}

function Read-SAConfig {
    <#
    .SYNOPSIS
        Loads configuration from a TOML file.
    .DESCRIPTION
        Loads and validates user configuration from config.toml.
        Missing settings are filled from defaults via Merge-SAConfig.
    .PARAMETER Path
        Path to the config.toml file.
    .PARAMETER Validate
        Validate configuration after loading (default: true).
    .EXAMPLE
        $config = Read-SAConfig -Path "C:\Stagearr\config.toml"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [bool]$Validate = $true
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $config = ConvertFrom-SAToml -Content $content
    } catch {
        throw "Failed to parse configuration file: $_"
    }

    # Merge with defaults (fills in any missing settings)
    $merged = Merge-SAConfig -UserConfig $config -DefaultConfig $script:SAConfigDefaults

    # Validate if requested
    if ($Validate) {
        Test-SAConfig -Config $merged | Out-Null
    }

    return $merged
}

function Merge-SAConfig {
    <#
    .SYNOPSIS
        Recursively merges user config with defaults.
    .PARAMETER UserConfig
        User-provided configuration (PSCustomObject or hashtable).
    .PARAMETER DefaultConfig
        Default configuration hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $UserConfig,
        
        [Parameter(Mandatory = $true)]
        $DefaultConfig
    )
    
    if ($null -eq $UserConfig) {
        return $DefaultConfig
    }
    
    # Convert PSCustomObject to hashtable for easier merging
    if ($UserConfig -is [PSCustomObject]) {
        $userHash = @{}
        foreach ($prop in $UserConfig.PSObject.Properties) {
            $userHash[$prop.Name] = $prop.Value
        }
        $UserConfig = $userHash
    }
    
    $result = @{}
    
    # Start with defaults
    foreach ($key in $DefaultConfig.Keys) {
        $defaultValue = $DefaultConfig[$key]
        
        if ($UserConfig.ContainsKey($key)) {
            $userValue = $UserConfig[$key]
            
            # Recursive merge for nested hashtables/objects
            if ($defaultValue -is [hashtable] -and ($userValue -is [hashtable] -or $userValue -is [PSCustomObject])) {
                $result[$key] = Merge-SAConfig -UserConfig $userValue -DefaultConfig $defaultValue
            } else {
                # User value overrides default
                $result[$key] = $userValue
            }
        } else {
            # Use default
            $result[$key] = $defaultValue
        }
    }
    
    # Include any extra user keys not in defaults
    foreach ($key in $UserConfig.Keys) {
        if (-not $result.ContainsKey($key)) {
            $result[$key] = $UserConfig[$key]
        }
    }
    
    return $result
}

function Test-SAConfigValid {
    <#
    .SYNOPSIS
        Validates configuration and returns list of errors.
    .PARAMETER Config
        Configuration hashtable to validate.
    .OUTPUTS
        Array of error messages (empty if valid).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $errors = [System.Collections.Generic.List[string]]::new()
    
    # Required paths
    if ([string]::IsNullOrWhiteSpace($Config.paths.stagingRoot)) {
        $errors.Add("paths.stagingRoot is required")
    }
    if ([string]::IsNullOrWhiteSpace($Config.paths.logArchive)) {
        $errors.Add("paths.logArchive is required")
    }
    if ([string]::IsNullOrWhiteSpace($Config.paths.queueRoot)) {
        $errors.Add("paths.queueRoot is required")
    }
    
    # TV importer must be valid
    if ($Config.processing.tvImporter -notin @('Medusa', 'Sonarr')) {
        $errors.Add("processing.tvImporter must be 'Medusa' or 'Sonarr'")
    }
    
    # Tool paths (only validate if non-empty)
    $toolPaths = @{
        'tools.winrar'       = $Config.tools.winrar
        'tools.mkvmerge'     = $Config.tools.mkvmerge
        'tools.mkvextract'   = $Config.tools.mkvextract
        'tools.subtitleEdit' = $Config.tools.subtitleEdit
    }
    
    foreach ($tool in $toolPaths.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace($tool.Value)) {
            if (-not (Test-Path -LiteralPath $tool.Value -PathType Leaf)) {
                $errors.Add("$($tool.Key) path not found: $($tool.Value)")
            }
        }
    }
    
    # Validate wanted languages
    if ($Config.subtitles.wantedLanguages) {
        foreach ($lang in $Config.subtitles.wantedLanguages) {
            if (-not (Test-SALanguageCode -Code $lang)) {
                $errors.Add("Unknown language code in subtitles.wantedLanguages: $lang")
            }
        }
    }
    
    # OpenSubtitles validation
    if ($Config.subtitles.openSubtitles.enabled) {
        if ([string]::IsNullOrWhiteSpace($Config.subtitles.openSubtitles.user)) {
            $errors.Add("subtitles.openSubtitles.user is required when enabled")
        }
        if ([string]::IsNullOrWhiteSpace($Config.subtitles.openSubtitles.password)) {
            $errors.Add("subtitles.openSubtitles.password is required when enabled")
        }
        if ([string]::IsNullOrWhiteSpace($Config.subtitles.openSubtitles.apiKey)) {
            $errors.Add("subtitles.openSubtitles.apiKey is required when enabled")
        }
        
        $validFilters = @('include', 'exclude', 'only')
        foreach ($filterName in @('hearingImpaired', 'foreignPartsOnly', 'machineTranslated', 'aiTranslated')) {
            $value = $Config.subtitles.openSubtitles.filters[$filterName]
            if ($value -and $value -notin $validFilters) {
                $errors.Add("subtitles.openSubtitles.filters.$filterName must be: include, exclude, or only")
            }
        }
    }
    
    # Importer validation
    foreach ($importer in @('radarr', 'sonarr', 'medusa')) {
        $cfg = $Config.importers[$importer]
        if ($cfg.enabled) {
            if ([string]::IsNullOrWhiteSpace($cfg.apiKey)) {
                $errors.Add("importers.$importer.apiKey is required when enabled")
            }
            if ($cfg.port -le 0 -or $cfg.port -gt 65535) {
                $errors.Add("importers.$importer.port must be a valid port number")
            }
        }
    }
    
    # ImportMode validation for Radarr/Sonarr
    $validImportModes = @('move', 'copy')
    foreach ($importer in @('radarr', 'sonarr')) {
        $cfg = $Config.importers[$importer]
        if ($cfg -and $cfg.importMode) {
            if ($cfg.importMode -notin $validImportModes) {
                $errors.Add("importers.$importer.importMode must be: move or copy")
            }
        }
    }
    
    # Metadata source validation
    $validMetadataSources = @('auto', 'omdb', 'none')
    if ($Config.notifications.email.metadata -and $Config.notifications.email.metadata.source) {
        if ($Config.notifications.email.metadata.source -notin $validMetadataSources) {
            $errors.Add("notifications.email.metadata.source must be: auto, omdb, or none")
        }
    }
    
    # Email validation
    if ($Config.notifications.email.enabled) {
        if ([string]::IsNullOrWhiteSpace($Config.notifications.email.to)) {
            $errors.Add("notifications.email.to is required when enabled")
        }
        if ([string]::IsNullOrWhiteSpace($Config.notifications.email.from)) {
            $errors.Add("notifications.email.from is required when enabled")
        }
        if ([string]::IsNullOrWhiteSpace($Config.notifications.email.smtp.server)) {
            $errors.Add("notifications.email.smtp.server is required when enabled")
        }
    }
    
    # OMDb validation (optional section - only validate when enabled)
    if ($Config.omdb -and $Config.omdb.enabled) {
        if ([string]::IsNullOrWhiteSpace($Config.omdb.apiKey)) {
            $errors.Add("omdb.apiKey is required when enabled (get free key at https://www.omdbapi.com/apikey.aspx)")
        }
    }
    
    return $errors.ToArray()
}

function Test-SAConfig {
    <#
    .SYNOPSIS
        Validates configuration and throws on any errors.
    .DESCRIPTION
        Catches configuration errors at startup instead of mid-job.
        Validates required tool paths exist and are accessible.
        Tool requirements are conditional on feature enablement.
    .PARAMETER Config
        Configuration hashtable to validate.
    .OUTPUTS
        $true if valid.
    .EXAMPLE
        Test-SAConfig -Config $config
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $errors = [System.Collections.Generic.List[string]]::new()
    
    # Friendly names for error messages
    $toolNames = @{
        winrar       = 'WinRAR (rar.exe)'
        mkvmerge     = 'MKVToolNix mkvmerge'
        mkvextract   = 'MKVToolNix mkvextract'
        subtitleEdit = 'Subtitle Edit'
    }
    
    $pathNames = @{
        stagingRoot = 'Staging folder'
        queueRoot   = 'Queue folder'
        logArchive  = 'Log archive folder'
    }
    
    # Build required tools list based on enabled features
    # WinRAR is always required - RAR extraction is core functionality
    $requiredTools = [System.Collections.Generic.List[string]]::new()
    $requiredTools.Add('winrar')
    
    # mkvextract required for subtitle extraction
    if (Test-SAFeatureEnabled -Config $Config -Feature 'SubtitleExtraction') {
        $requiredTools.Add('mkvextract')
    }
    
    # mkvmerge required for subtitle stripping OR MP4 remuxing
    if ((Test-SAFeatureEnabled -Config $Config -Feature 'SubtitleStripping') -or
        (Test-SAFeatureEnabled -Config $Config -Feature 'Mp4Remux')) {
        if (-not $requiredTools.Contains('mkvmerge')) {
            $requiredTools.Add('mkvmerge')
        }
    }
    
    # Validate required tools
    foreach ($tool in $requiredTools) {
        $path = $Config.tools[$tool]
        $friendly = $toolNames[$tool]
        if ([string]::IsNullOrWhiteSpace($path)) {
            $errors.Add("$friendly not configured - add tools.$tool to config.toml")
        }
        elseif (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $errors.Add("$friendly not found at: $path")
        }
    }
    
    # Conditionally required tools - only validate if feature is enabled AND path is configured
    # SubtitleEdit: required when SubtitleCleanup is enabled
    if (Test-SAFeatureEnabled -Config $Config -Feature 'SubtitleCleanup') {
        $path = $Config.tools.subtitleEdit
        $friendly = $toolNames['subtitleEdit']
        if ([string]::IsNullOrWhiteSpace($path)) {
            $errors.Add("$friendly not configured - add tools.subtitleEdit to config.toml (required when subtitles.cleanup.enabled = true)")
        }
        elseif (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $errors.Add("$friendly not found at: $path")
        }
    }
    else {
        # Feature disabled - only validate path if configured (don't require it)
        $path = $Config.tools.subtitleEdit
        $friendly = $toolNames['subtitleEdit']
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $errors.Add("$friendly not found at: $path")
        }
    }
    
    # Required directories - paths must be configured (not necessarily exist yet)
    $requiredPaths = @('stagingRoot', 'queueRoot', 'logArchive')
    foreach ($pathName in $requiredPaths) {
        $path = $Config.paths[$pathName]
        $friendly = $pathNames[$pathName]
        if ([string]::IsNullOrWhiteSpace($path)) {
            $errors.Add("$friendly not configured - add paths.$pathName to config.toml")
        }
    }
    
    # Include standard validation errors (but skip tool path errors we already reported)
    $standardErrors = Test-SAConfigValid -Config $Config
    foreach ($err in $standardErrors) {
        # Skip tool path errors - we already reported them with friendlier messages
        if ($err -match '^tools\.(winrar|mkvmerge|mkvextract|subtitleEdit)\b') {
            continue
        }
        if (-not $errors.Contains($err)) {
            $errors.Add($err)
        }
    }
    
    if ($errors.Count -gt 0) {
        $errorList = $errors -join "`n  - "
        throw "Configuration invalid - fix these issues:`n  - $errorList"
    }
    
    return $true
}

function Test-SAFeatureEnabled {
    <#
    .SYNOPSIS
        Checks if a processing feature is enabled in config.
    .DESCRIPTION
        Centralized check for feature enablement. Returns $true if:
        - Feature path exists and enabled = $true
        - Feature path doesn't exist (defaults to enabled for backward compat)
        
        Note: OpenSubtitles uses opt-in logic (defaults to $false when not configured)
        while other features use opt-out logic (default to $true).
    .PARAMETER Config
        Configuration hashtable to check.
    .PARAMETER Feature
        Feature name to check enablement for.
    .OUTPUTS
        [bool] True if feature is enabled.
    .EXAMPLE
        Test-SAFeatureEnabled -Config $config -Feature 'SubtitleExtraction'
        # Returns $true unless explicitly disabled
    .EXAMPLE
        Test-SAFeatureEnabled -Config $config -Feature 'OpenSubtitles'
        # Returns $true only if explicitly enabled with credentials
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        
        [Parameter(Mandatory)]
        [ValidateSet('SubtitleExtraction', 'SubtitleStripping', 'SubtitleCleanup', 
                     'OpenSubtitles', 'Mp4Remux', 'omdb')]
        [string]$Feature
    )
    
    switch ($Feature) {
        'SubtitleExtraction' {
            # Opt-out: enabled unless explicitly disabled
            # Check if path exists and has enabled property
            if ($null -ne $Config.subtitles -and 
                $null -ne $Config.subtitles.extraction -and 
                $Config.subtitles.extraction.ContainsKey('enabled')) {
                return ($Config.subtitles.extraction.enabled -eq $true)
            }
            # Default: enabled
            return $true
        }
        'SubtitleStripping' {
            # Opt-out: enabled unless explicitly disabled
            if ($null -ne $Config.subtitles -and 
                $null -ne $Config.subtitles.stripping -and 
                $Config.subtitles.stripping.ContainsKey('enabled')) {
                return ($Config.subtitles.stripping.enabled -eq $true)
            }
            # Default: enabled
            return $true
        }
        'SubtitleCleanup' {
            # Opt-out: enabled unless explicitly disabled
            if ($null -ne $Config.subtitles -and 
                $null -ne $Config.subtitles.cleanup -and 
                $Config.subtitles.cleanup.ContainsKey('enabled')) {
                return ($Config.subtitles.cleanup.enabled -eq $true)
            }
            # Default: enabled
            return $true
        }
        'OpenSubtitles' {
            # Opt-in: disabled unless explicitly enabled
            # This is different from other features - requires explicit enablement
            if ($null -ne $Config.subtitles -and 
                $null -ne $Config.subtitles.openSubtitles) {
                return ($Config.subtitles.openSubtitles.enabled -eq $true)
            }
            # Default: disabled
            return $false
        }
        'Mp4Remux' {
            # Opt-out: enabled unless explicitly disabled
            if ($null -ne $Config.video -and 
                $null -ne $Config.video.mp4Remux -and 
                $Config.video.mp4Remux.ContainsKey('enabled')) {
                return ($Config.video.mp4Remux.enabled -eq $true)
            }
            # Default: enabled
            return $true
        }
        'omdb' {
            # Opt-in: disabled unless explicitly enabled with API key
            # OMDb enrichment is optional - requires explicit enablement
            if ($null -ne $Config.omdb) {
                return ($Config.omdb.enabled -eq $true)
            }
            # Default: disabled
            return $false
        }
    }
    
    # Should not reach here due to ValidateSet, but default to enabled for safety
    return $true
}