#Requires -Version 5.1
<#
.SYNOPSIS
    Stagearr.Core module loader
.DESCRIPTION
    Loads all private and public functions for the Stagearr core module.
    Private functions are internal helpers; Public functions are exported.
    
    Private/ structure:
    - Output/ subfolder contains all output/rendering related files
    - Other files remain in Private/ root
#>

# Get module root path
$ModuleRoot = $PSScriptRoot

# Define load order for private functions (dependencies first)
$PrivateLoadOrder = @(
    'Constants.ps1'               # Centralized constants (no dependencies, load first)
    'Formatting.ps1'              # Display formatting (size, duration, pluralization) - early, no dependencies
    'PathSecurity.ps1'            # Path validation and security (no dependencies)
    'SafetyCheck.ps1'             # Dangerous file detection for TV/Movie downloads
    'FileIO.ps1'                  # File system I/O utilities (may use PathSecurity)
    'EpisodeFormatting.ps1'       # Episode number formatting (uses Formatting)
    'MediaParsing.ps1'            # Media filename parsing (standalone)
    'MediaDisplay.ps1'            # Media metadata display formatting (source/service names)
    'Utility.ps1'                 # Misc utilities (hash, platform, type conversion, state reset)
    'Output/ConsoleRenderer.ps1'  # Console renderer (event-based output)
    'Output/FileLogRenderer.ps1'  # Plain-text file log renderer
    'Output/EmailHelpers.ps1'     # Email display helpers and color palette (uses MediaDisplay)
    'Output/EmailRenderer.ps1'    # Email state management and orchestration (uses EmailHelpers)
    'Output/EmailSections.ps1'    # Email HTML section builders (uses EmailHelpers, EmailRenderer state)
    'Output/EmailSubject.ps1'     # Email subject line generation (uses EmailHelpers)
    'Output/OutputEvent.ps1'      # Event system (depends on renderers)
    'Language.ps1'                # Language code normalization
    'Process.ps1'                 # External process runner
    'ErrorHandling.ps1'           # User-friendly error translation (depends on Process)
    'Http.ps1'                    # HTTP client with retry
    'Update.ps1'                  # Auto-update check and apply (depends on Http)
    'Omdb.ps1'                    # OMDb API client (metadata, poster download)
    'Toml.ps1'                    # TOML parser and writer (load before Config)
    'ConfigSync.ps1'              # Config sync detection and merge (load before Config)
    'Config.ps1'                  # Configuration loader (depends on ConfigSync for schema validation)
    'Context.ps1'                 # Context object management
    'MkvAnalysis.ps1'             # MKV track analysis
    'ImportUtility.ps1'           # Import utilities (hostname resolution, URL building, path translation)
    'ImportResultParser.ps1'      # Import result parsing (error categorization, hints)
    'ArrMetadata.ps1'             # *arr metadata extraction and normalization (ManualImport scan results)
    'QueueEnrichment.ps1'         # Queue-based enrichment for ManualImport scan results
)

# Define load order for public functions
$PublicLoadOrder = @(
    'Setup.ps1'              # Interactive setup wizard
    'Lock.ps1'               # Global lock management
    'Queue.ps1'              # Job queue management (depends on Lock)
    'Notification.ps1'       # Email notifications
    'Staging.ps1'            # Staging folder operations
    'RarExtraction.ps1'      # RAR extraction with security validation (standalone)
    'Video.ps1'              # Video processing (remux, extract, strip) - uses RarExtraction
    'OpenSubtitles.ps1'      # OpenSubtitles API integration
    'SubtitleProcessing.ps1' # Subtitle processing and analysis (uses OpenSubtitles)
    'ImportArr.ps1'          # Radarr/Sonarr import functions (depends on ImportUtility, ImportResultParser)
    'ImportMedusa.ps1'       # Medusa import functions (depends on ImportUtility, ImportResultParser)
    'Import.ps1'             # Main import dispatcher (depends on ImportArr, ImportMedusa)
    'JobProcessor.ps1'       # Job orchestration (depends on all above)
    'Rerun.ps1'              # Interactive rerun of completed/failed jobs (depends on Queue, Lock)
)

# Load private functions in order
foreach ($file in $PrivateLoadOrder) {
    $filePath = Join-Path -Path $ModuleRoot -ChildPath "Private\$file"
    if (Test-Path -LiteralPath $filePath) {
        try {
            . $filePath
        } catch {
            Write-Error "Failed to load private function file '$file': $_"
            throw
        }
    } else {
        Write-Warning "Private function file not found: $filePath"
    }
}

# Load public functions in order
foreach ($file in $PublicLoadOrder) {
    $filePath = Join-Path -Path $ModuleRoot -ChildPath "Public\$file"
    if (Test-Path -LiteralPath $filePath) {
        try {
            . $filePath
        } catch {
            Write-Error "Failed to load public function file '$file': $_"
            throw
        }
    } else {
        Write-Warning "Public function file not found: $filePath"
    }
}

# Module-level initialization
$script:SAModuleRoot = $ModuleRoot
