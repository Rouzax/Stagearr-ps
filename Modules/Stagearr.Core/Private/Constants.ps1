#Requires -Version 5.1
<#
.SYNOPSIS
    Centralized constants for Stagearr
.DESCRIPTION
    Contains all magic numbers and default values used throughout the codebase.
    Centralizing these values:
    - Makes behavior discoverable
    - Enables consistent defaults across modules
    - Simplifies future tuning
    
    Usage: Access via $script:SAConstants.PropertyName
    
    Note: These are defaults. Many can be overridden via configuration.
#>

$script:SAConstants = @{
    #region HTTP / API Defaults
    
    # Default retry count for HTTP requests
    DefaultMaxRetries = 3
    
    # Delay between retry attempts (seconds)
    DefaultRetryDelaySeconds = 2
    
    # Default HTTP request timeout (seconds)
    DefaultTimeoutSeconds = 30
    
    # Connection test timeout - shorter for quick checks (seconds)
    ConnectionTestTimeoutSeconds = 10
    
    #endregion
    
    #region Import Defaults
    
    # How long to wait for import completion (minutes)
    DefaultImportTimeoutMinutes = 10
    
    # How often to poll for import status (seconds)
    ImportPollIntervalSeconds = 5
    
    #endregion
    
    #region Lock Defaults
    
    # Default timeout waiting for lock acquisition (seconds)
    LockWaitTimeoutSeconds = 60
    
    # How often to retry lock acquisition (seconds)
    LockRetryIntervalSeconds = 5
    
    # Tolerance for process start time comparison (seconds)
    # Accounts for clock precision differences
    ProcessStartTimeTolerance = 2
    
    #endregion
    
    #region OpenSubtitles Defaults
    
    # Token validity period (hours) - OpenSubtitles tokens last 24h, we refresh at 23h
    TokenExpiryHours = 23
    
    # Delay between download requests to respect rate limits (seconds)
    OpenSubtitlesRateLimitDelay = 5

    # XML-RPC endpoint for uploads (REST API doesn't support upload yet)
    OpenSubtitlesXmlRpcUrl = 'https://api.opensubtitles.org:443/xml-rpc'

    # Delay between upload requests (milliseconds)
    OpenSubtitlesUploadDelayMs = 1500

    # Delay between API calls (search, existence checks) to respect rate limits (milliseconds)
    # OpenSubtitles allows 40 requests/10 seconds = 250ms minimum spacing
    OpenSubtitlesApiDelayMs = 250

    # Filenames too generic for OpenSubtitles upload (case-insensitive, matched against base name without extension)
    OpenSubtitlesUploadBlockedNames = @('_unpack', 'video', 'output', 'movie', 'film')

    #endregion
    
    #region SubtitleEdit Defaults
    
    # Base timeout for SubtitleEdit processing (seconds)
    SubtitleEditBaseTimeout = 60
    
    # Additional time per file for SubtitleEdit (seconds)
    SubtitleEditPerFileTimeout = 10
    
    #endregion
    
    #region Email Defaults
    
    # Email send timeout (seconds)
    EmailSendTimeoutSeconds = 10
    
    #endregion
    
    #region Console Output

    # Progress heartbeat interval for long operations (seconds)
    HeartbeatIntervalSeconds = 15

    #endregion

    #region File Extensions

    # Video file extensions recognized throughout the pipeline
    VideoExtensions = @('.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.ts')

    # Regex pattern for video extensions (without dots, for pattern matching)
    VideoExtensionsPattern = 'mkv|mp4|avi|m4v|mov|wmv|ts'

    #endregion

    #region DNS Cache

    # Hostname resolution cache TTL (minutes)
    HostnameCacheTtlMinutes = 30

    #endregion

    #region Update Defaults

    # GitHub repository for update checks
    UpdateGitHubRepo = 'Rouzax/Stagearr-ps'

    # Default hours between update checks
    DefaultUpdateCheckIntervalHours = 24

    # Update check timeout (seconds) - keep short to not delay processing
    UpdateCheckTimeoutSeconds = 10

    # Timestamp file name
    UpdateTimestampFile = 'lastUpdateCheck.json'

    #endregion
}

# Make constants read-only after initialization
# (PowerShell doesn't have true immutability, but this signals intent)
Set-Variable -Name 'TSConstants' -Scope Script -Option ReadOnly -Force -ErrorAction SilentlyContinue
