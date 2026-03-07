#Requires -Version 5.1
<#
.SYNOPSIS
    Context object management for Stagearr
.DESCRIPTION
    Creates and manages the context object that carries configuration, job info,
    and state through the entire processing pipeline.
#>

function New-SAContext {
    <#
    .SYNOPSIS
        Creates a new processing context object.
    .DESCRIPTION
        The context object is passed through all processing functions and contains:
        - Configuration settings
        - Current job information
        - Tool paths (validated)
        - State tracking
    .PARAMETER Config
        Configuration hashtable (from Read-SAConfig).
    .PARAMETER Job
        Job object being processed (optional, can be set later).
    .EXAMPLE
        $ctx = New-SAContext -Config $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter()]
        [hashtable]$Job,

        [Parameter()]
        [switch]$VerboseMode
    )
    
    # Initialize console renderer with config settings
    Initialize-SAConsoleRenderer -UseColors $Config.logging.consoleColors -VerboseMode:$VerboseMode
    
    # Create context object
    $context = @{
        # Configuration
        Config = $Config
        
        # Current job (set when processing starts)
        Job = $Job
        
        # Resolved tool paths
        Tools = @{
            WinRar       = $Config.tools.winrar
            MkvMerge     = $Config.tools.mkvmerge
            MkvExtract   = $Config.tools.mkvextract
            SubtitleEdit = $Config.tools.subtitleEdit
        }
        
        # Processing state
        State = @{
            StartTime       = $null
            StagingPath     = $null
            SourcePath      = $null
            IsRarArchive    = $false
            IsSingleFile    = $false
            IsFolder        = $false
            HasVideoFiles   = $false
            ProcessingLabel = $null
            # Video batch processing state (for console header deduplication)
            VideoFileIndex  = 0
            VideoFileCount  = 0
        }
        
        # Paths
        Paths = @{
            ScriptRoot   = $null
            ConfigFile   = $null
            StagingRoot  = $Config.paths.stagingRoot
            LogArchive   = $Config.paths.logArchive
            QueueRoot    = $Config.paths.queueRoot
        }
        
        # Runtime flags
        Flags = @{
            NoCleanup = $false
            NoMail    = $false
            DryRun    = $false
        }
        
        # Results/stats (accumulated during processing)
        Results = @{
            SubtitlesExtracted = 0
            SubtitlesDownloaded = 0
            SubtitlesRemoved   = 0
            FilesRemuxed       = 0
            FilesExtracted     = 0
            FilesCopied        = 0
            Errors             = [System.Collections.Generic.List[string]]::new()
            Warnings           = [System.Collections.Generic.List[string]]::new()
        }
    }
    
    # Log external tool versions (per OUTPUT-STYLE-GUIDE: verbose output at startup)
    Write-SAToolVersions -Context $context
    
    return $context
}

function Initialize-SAContext {
    <#
    .SYNOPSIS
        Initializes context for a specific job, validating tools and creating directories.
    .PARAMETER Context
        The context object to initialize.
    .PARAMETER Job
        The job to process.
    .EXAMPLE
        Initialize-SAContext -Context $ctx -Job $job
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Job
    )
    
    # Set job
    $Context.Job = $Job
    $Context.State.StartTime = Get-Date
    $Context.State.ProcessingLabel = $Job.input.downloadLabel
    
    # Set flags from job and config
    # NoCleanup: true if either -NoCleanup switch was passed OR cleanupStaging config is false
    $noCleanupFromJob = [bool]$Job.input.noCleanup
    $noCleanupFromConfig = ($Context.Config.processing.cleanupStaging -eq $false)
    $Context.Flags.NoCleanup = $noCleanupFromJob -or $noCleanupFromConfig
    $Context.Flags.NoMail = [bool]$Job.input.noMail
    
    # Determine source type
    $sourcePath = $Job.input.downloadPath
    $Context.State.SourcePath = $sourcePath
    
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        $Context.State.IsSingleFile = $true
        $Context.State.IsFolder = $false
        
        if ($sourcePath -match '\.rar$') {
            $Context.State.IsRarArchive = $true
        }
    } elseif (Test-Path -LiteralPath $sourcePath -PathType Container) {
        $Context.State.IsSingleFile = $false
        $Context.State.IsFolder = $true
        
        # Check for RAR files in folder
        $rarFiles = Get-ChildItem -LiteralPath $sourcePath -Filter '*.rar' -Recurse -ErrorAction SilentlyContinue
        if ($rarFiles.Count -gt 0) {
            $Context.State.IsRarArchive = $true
        }
    }
    
    # Build staging path: <stagingRoot>/<label>/<n>
    $downloadName = Split-Path -Path $sourcePath -Leaf
    if ($Context.State.IsSingleFile -and $downloadName -match '^(.+)\.[^.]+$') {
        # Remove extension for single files
        $downloadName = $Matches[1]
    }
    
    # SECURITY: Sanitize label and name to prevent path traversal attacks
    $safeLabel = Get-SASafeName -Name $Job.input.downloadLabel
    $safeName = Get-SASafeName -Name $downloadName
    
    $stagingPath = Join-Path -Path $Context.Paths.StagingRoot -ChildPath $safeLabel
    $stagingPath = Join-Path -Path $stagingPath -ChildPath $safeName
    
    # SECURITY: Validate the final path is within staging root
    Assert-SAPathUnderRoot -Path $stagingPath -Root $Context.Paths.StagingRoot
    
    $Context.State.StagingPath = $stagingPath
    
    # Note: Output system (console, file log, email) is initialized by Initialize-SAOutputSystem
    # in Invoke-SAJobProcessing after context is ready
    
    # Ensure directories exist
    New-SADirectory -Path $Context.Paths.StagingRoot
    New-SADirectory -Path $Context.Paths.LogArchive
    New-SADirectory -Path $Context.Paths.QueueRoot
}

function Get-SAContextLogPath {
    <#
    .SYNOPSIS
        Gets the log file path for the current job.
    .DESCRIPTION
        Returns a plain-text log file path (.log extension) per OUTPUT-STYLE-GUIDE:
        "The filesystem log is the definitive run record... plain text (no HTML),
        written in UTF-8, with no ANSI color codes."
    .PARAMETER Context
        The context object.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    $dateFormat = $Context.Config.logging.dateFormat
    if ([string]::IsNullOrWhiteSpace($dateFormat)) {
        $dateFormat = 'yyyy.MM.dd_HH.mm.ss'
    }
    
    $timestamp = Get-Date -Format $dateFormat
    
    # Sanitize timestamp for filename (replace invalid chars)
    $timestamp = $timestamp -replace '[<>:"/\\|?*]', '.'
    
    $downloadName = Split-Path -Path $Context.Job.input.downloadPath -Leaf
    
    # Sanitize filename
    $safeName = $downloadName -replace '[<>:"/\\|?*]', '_'
    
    # Use .log extension for plain-text logs (per OUTPUT-STYLE-GUIDE)
    $logFileName = "$timestamp-$safeName.log"
    return Join-Path -Path $Context.Paths.LogArchive -ChildPath $logFileName
}

function Get-SAContextDuration {
    <#
    .SYNOPSIS
        Gets the elapsed processing time.
    .PARAMETER Context
        The context object.
    #>
    [CmdletBinding()]
    [OutputType([TimeSpan])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    if ($null -eq $Context.State.StartTime) {
        return [TimeSpan]::Zero
    }
    
    return (Get-Date) - $Context.State.StartTime
}

function Write-SAToolVersions {
    <#
    .SYNOPSIS
        Logs external tool versions to verbose output.
    .DESCRIPTION
        Logs versions of PowerShell and external tools needed for enabled features
        to verbose output for troubleshooting. Per OUTPUT-STYLE-GUIDE, tool versions
        should be logged at startup or first use.
        
        Only logs tools required for enabled features:
        - WinRAR: Always (core functionality)
        - MKVToolNix: When SubtitleExtraction, SubtitleStripping, or Mp4Remux enabled
        - SubtitleEdit: When SubtitleCleanup enabled
        
        Uses file metadata (VersionInfo) rather than executing tools to avoid
        unexpected behavior if tools change their CLI interface.
    .PARAMETER Context
        The context object containing tool paths and config.
    .EXAMPLE
        Write-SAToolVersions -Context $ctx
        # VERBOSE: PowerShell: 7.5.4 Core
        # VERBOSE: WinRAR: 7.13 (C:\Program Files\WinRAR\rar.exe)
        # VERBOSE: MKVToolNix: 96.0 (C:\Program Files\MKVToolNix\mkvmerge.exe)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    $config = $Context.Config
    
    # Log PowerShell version first (helps debug PS5.1 vs PS7 issues)
    $psVersion = $PSVersionTable.PSVersion.ToString()
    $editionInfo = $PSVersionTable.PSEdition
    Write-SAVerbose -Label "PowerShell" -Text "$psVersion $editionInfo"
    
    # Build list of tools to log based on enabled features
    $tools = [System.Collections.Generic.List[hashtable]]::new()
    
    # WinRAR is always needed (RAR extraction is core functionality)
    $tools.Add(@{ Name = 'WinRAR'; Path = $Context.Tools.WinRar })
    
    # MKVToolNix needed for extraction, stripping, or MP4 remux
    $needsMkvToolNix = (Test-SAFeatureEnabled -Config $config -Feature 'SubtitleExtraction') -or
                       (Test-SAFeatureEnabled -Config $config -Feature 'SubtitleStripping') -or
                       (Test-SAFeatureEnabled -Config $config -Feature 'Mp4Remux')
    if ($needsMkvToolNix) {
        $tools.Add(@{ Name = 'MKVToolNix'; Path = $Context.Tools.MkvMerge })
    }
    
    # SubtitleEdit needed for cleanup
    if (Test-SAFeatureEnabled -Config $config -Feature 'SubtitleCleanup') {
        $tools.Add(@{ Name = 'SubtitleEdit'; Path = $Context.Tools.SubtitleEdit })
    }
    
    foreach ($tool in $tools) {
        $path = $tool.Path
        
        # Skip unconfigured tools
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        
        # Skip tools that don't exist
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        
        try {
            # Get version from file metadata (safer than executing)
            $fileInfo = Get-Item -LiteralPath $path -ErrorAction Stop
            $version = $fileInfo.VersionInfo.ProductVersion
            
            if (-not [string]::IsNullOrWhiteSpace($version)) {
                # Clean up version string (extract just the version number)
                if ($version -match '^(\d+\.\d+(?:\.\d+)?)') {
                    $version = $Matches[1]
                }
                Write-SAVerbose -Label $tool.Name -Text "$version ($path)"
            } else {
                # No version in metadata, just show path
                Write-SAVerbose -Label $tool.Name -Text "($path)"
            }
        } catch {
            # Metadata read failed, just show path
            Write-SAVerbose -Label $tool.Name -Text "($path)"
        }
    }
}

function Get-SAToolVersionsForLog {
    <#
    .SYNOPSIS
        Returns tool versions in a format suitable for file log header.
    .DESCRIPTION
        Collects version information for PowerShell and external tools needed for
        enabled features, returns it as a hashtable for the file log renderer.
        
        Only includes tools required for enabled features:
        - WinRAR: Always (core functionality)
        - MKVToolNix: When SubtitleExtraction, SubtitleStripping, or Mp4Remux enabled
        - SubtitleEdit: When SubtitleCleanup enabled
        
        Per OUTPUT-STYLE-GUIDE: "External tool versions should be logged at startup 
        or first use. This is invaluable for troubleshooting issues that only occur 
        with specific versions."
    .PARAMETER Context
        The context object containing tool paths and config.
    .OUTPUTS
        Hashtable with tool names as keys and version info (hashtable with Version and Path) as values.
    .EXAMPLE
        $versions = Get-SAToolVersionsForLog -Context $ctx
        # Returns:
        # @{
        #     'PowerShell' = @{ Version = '7.5.4 Core'; Path = '' }
        #     'WinRAR' = @{ Version = '7.13'; Path = 'C:\Program Files\WinRAR\rar.exe' }
        #     'MKVToolNix' = @{ Version = '96.0'; Path = 'C:\Program Files\MKVToolNix\mkvmerge.exe' }
        # }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    $config = $Context.Config
    $versions = @{}
    
    # PowerShell version first (helps debug PS5.1 vs PS7 issues)
    $psVersion = $PSVersionTable.PSVersion.ToString()
    $editionInfo = $PSVersionTable.PSEdition
    $versions['PowerShell'] = @{
        Version = "$psVersion $editionInfo"
        Path    = ''
    }
    
    # Build list of tools based on enabled features
    $tools = [System.Collections.Generic.List[hashtable]]::new()
    
    # WinRAR is always needed (RAR extraction is core functionality)
    $tools.Add(@{ Name = 'WinRAR'; Path = $Context.Tools.WinRar })
    
    # MKVToolNix needed for extraction, stripping, or MP4 remux
    $needsMkvToolNix = (Test-SAFeatureEnabled -Config $config -Feature 'SubtitleExtraction') -or
                       (Test-SAFeatureEnabled -Config $config -Feature 'SubtitleStripping') -or
                       (Test-SAFeatureEnabled -Config $config -Feature 'Mp4Remux')
    if ($needsMkvToolNix) {
        $tools.Add(@{ Name = 'MKVToolNix'; Path = $Context.Tools.MkvMerge })
    }
    
    # SubtitleEdit needed for cleanup
    if (Test-SAFeatureEnabled -Config $config -Feature 'SubtitleCleanup') {
        $tools.Add(@{ Name = 'SubtitleEdit'; Path = $Context.Tools.SubtitleEdit })
    }
    
    foreach ($tool in $tools) {
        $path = $tool.Path
        
        # Skip unconfigured tools
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        
        # Skip tools that don't exist
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        
        try {
            # Get version from file metadata (safer than executing)
            $fileInfo = Get-Item -LiteralPath $path -ErrorAction Stop
            $version = $fileInfo.VersionInfo.ProductVersion
            
            if (-not [string]::IsNullOrWhiteSpace($version)) {
                # Clean up version string (extract just the version number)
                if ($version -match '^(\d+\.\d+(?:\.\d+)?)') {
                    $version = $Matches[1]
                }
                $versions[$tool.Name] = @{
                    Version = $version
                    Path    = $path
                }
            } else {
                # No version in metadata, just show path
                $versions[$tool.Name] = @{
                    Version = '(version unavailable)'
                    Path    = $path
                }
            }
        } catch {
            # Metadata read failed, just note the path
            $versions[$tool.Name] = @{
                Version = '(version unavailable)'
                Path    = $path
            }
        }
    }
    
    return $versions
}