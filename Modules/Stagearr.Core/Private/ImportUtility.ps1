#Requires -Version 5.1
<#
.SYNOPSIS
    Import utility functions for Stagearr
.DESCRIPTION
    Shared helper functions used by import operations:
    - Hostname resolution with IPv4 preference
    - Base URL building with Host header support
    - Remote path translation
    - Label type detection
    
    These functions have no external dependencies beyond the core module
    and are used by Import.ps1 and its submodules.
#>

#region Hostname Resolution

# Hostname resolution cache - prevents duplicate verbose messages for same host
# Key: hostname, Value: PSCustomObject with ResolvedHost, OriginalHost, WasResolved
$script:SAHostnameCache = @{}

function Reset-SAHostnameCache {
    <#
    .SYNOPSIS
        Clears the hostname resolution cache.
    .DESCRIPTION
        Call this at job start or between jobs in worker mode to ensure
        fresh DNS resolution. Called by Reset-SAImportState in Import.ps1.
    #>
    [CmdletBinding()]
    param()
    
    $script:SAHostnameCache = @{}
}

function Resolve-SAHostToIPv4 {
    <#
    .SYNOPSIS
        Resolves a hostname to its IPv4 address with caching.
    .DESCRIPTION
        Prevents IPv6 timeout issues on LANs where IPv6 isn't properly routed.
        Results are cached per hostname to avoid redundant verbose output.
        Returns both the resolved IP and the original hostname (for Host header).
    .PARAMETER Hostname
        The hostname to resolve.
    .OUTPUTS
        PSCustomObject with ResolvedHost, OriginalHost, and WasResolved properties.
    .EXAMPLE
        $resolved = Resolve-SAHostToIPv4 -Hostname 'radarr.local'
        # Returns: @{ ResolvedHost = '192.168.1.10'; OriginalHost = 'radarr.local'; WasResolved = $true }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hostname
    )
    
    # Check cache first (expire after configured TTL to pick up DNS changes)
    if ($script:SAHostnameCache.ContainsKey($Hostname)) {
        $cached = $script:SAHostnameCache[$Hostname]
        $ttl = if ($script:SAConstants.HostnameCacheTtlMinutes) { $script:SAConstants.HostnameCacheTtlMinutes } else { 30 }
        if ($null -ne $cached.CachedAt -and ((Get-Date) - $cached.CachedAt).TotalMinutes -lt $ttl) {
            return $cached
        }
        $script:SAHostnameCache.Remove($Hostname)
    }
    
    # Default result - no resolution needed
    $result = [PSCustomObject]@{
        ResolvedHost = $Hostname
        OriginalHost = $Hostname
        WasResolved  = $false
        CachedAt     = Get-Date
    }
    
    # If it's already an IP address, return as-is
    $ipAddress = $null
    if ([System.Net.IPAddress]::TryParse($Hostname, [ref]$ipAddress)) {
        $script:SAHostnameCache[$Hostname] = $result
        return $result
    }
    
    # If it's localhost, return as-is
    if ($Hostname -eq 'localhost') {
        $script:SAHostnameCache[$Hostname] = $result
        return $result
    }
    
    try {
        # Resolve hostname and find IPv4 address
        $addresses = [System.Net.Dns]::GetHostAddresses($Hostname)
        $ipv4 = $addresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
        
        if ($null -ne $ipv4) {
            $result.ResolvedHost = $ipv4.IPAddressToString
            $result.WasResolved = $true
            # Log resolution only on first lookup (cached results won't trigger this)
            Write-SAVerbose -Text "Resolved $Hostname -> $($result.ResolvedHost)"
        }
        
        $script:SAHostnameCache[$Hostname] = $result
        return $result
        
    } catch {
        # Resolution failed, return original hostname
        $script:SAHostnameCache[$Hostname] = $result
        return $result
    }
}

#endregion

#region URL Building

function Get-SAImporterBaseUrl {
    <#
    .SYNOPSIS
        Builds base URL for importer API.
    .DESCRIPTION
        Resolves hostname to IPv4 to avoid IPv6 timeout issues on local networks.
        Returns URL (with IP for connection), DisplayUrl (with hostname for display),
        and HostHeader (for reverse proxy compatibility).
    .PARAMETER Config
        Importer configuration hashtable containing host, port, ssl, and urlRoot.
    .OUTPUTS
        PSCustomObject with Url, DisplayUrl, and HostHeader properties.
    .EXAMPLE
        $urlInfo = Get-SAImporterBaseUrl -Config $config.importers.radarr
        # Returns: @{ Url = 'http://192.168.1.10:7878'; DisplayUrl = 'http://radarr.local:7878'; HostHeader = 'radarr.local:7878' }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $apiHost = $Config.host
    if ([string]::IsNullOrWhiteSpace($apiHost)) {
        $apiHost = 'localhost'
    }
    
    $port = $Config.port
    if (-not $port) {
        $port = 8080
    }
    
    $scheme = 'http'
    if ($Config.ssl -eq $true -or $Config.useSsl -eq $true) {
        $scheme = 'https'
    }
    
    # Build display URL (with original hostname)
    $urlRoot = $Config.urlRoot
    $displayUrl = if (-not [string]::IsNullOrWhiteSpace($urlRoot)) {
        $urlRoot = $urlRoot.Trim('/')
        "$scheme`://$apiHost`:$port/$urlRoot"
    } else {
        "$scheme`://$apiHost`:$port"
    }
    
    # Resolve to IPv4 to avoid IPv6 timeout issues
    $resolved = Resolve-SAHostToIPv4 -Hostname $apiHost
    
    # Build connection URL (with resolved IP)
    $connectionUrl = if (-not [string]::IsNullOrWhiteSpace($urlRoot)) {
        "$scheme`://$($resolved.ResolvedHost)`:$port/$urlRoot"
    } else {
        "$scheme`://$($resolved.ResolvedHost)`:$port"
    }
    
    # Build Host header value (original hostname with port if non-standard)
    $hostHeader = $null
    if ($resolved.WasResolved) {
        # Resolution verbose logging is handled by Resolve-SAHostToIPv4 (only on first lookup)
        if (($scheme -eq 'http' -and $port -ne 80) -or ($scheme -eq 'https' -and $port -ne 443)) {
            $hostHeader = "$apiHost`:$port"
        } else {
            $hostHeader = $apiHost
        }
    }
    
    return [PSCustomObject]@{
        Url        = $connectionUrl
        DisplayUrl = $displayUrl
        HostHeader = $hostHeader
    }
}

#endregion

#region Path Translation

function Convert-SAToRemotePath {
    <#
    .SYNOPSIS
        Converts local staging path to remote path for import.
    .DESCRIPTION
        When Stagearr runs on a different machine than the media server,
        paths need to be translated. Preserves the label subfolder structure.
    .PARAMETER LocalPath
        Local staging path (e.g., C:\Processing\TV\ShowName).
    .PARAMETER RemotePath
        Remote path mapping from config (e.g., \\server\staging).
    .PARAMETER StagingRoot
        Local staging root to determine relative path structure.
    .OUTPUTS
        String with the translated remote path.
    .EXAMPLE
        # Local: C:\Processing\TV\Movie
        # StagingRoot: C:\Processing
        # RemotePath: \\server\staging
        # Result: \\server\staging\TV\Movie
        Convert-SAToRemotePath -LocalPath 'C:\Processing\TV\Movie' -RemotePath '\\server\staging' -StagingRoot 'C:\Processing'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,
        
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        
        [Parameter()]
        [string]$StagingRoot
    )
    
    # If we have staging root, preserve the relative structure (label/foldername)
    if (-not [string]::IsNullOrWhiteSpace($StagingRoot)) {
        # Normalize paths for comparison
        $normalizedLocal = $LocalPath -replace '\\', '/'
        $normalizedRoot = $StagingRoot.TrimEnd('/\') -replace '\\', '/'
        
        if ($normalizedLocal.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            # Get relative path (e.g., "TV/ShowName")
            $relativePath = $normalizedLocal.Substring($normalizedRoot.Length).TrimStart('/')
            return Join-Path -Path $RemotePath -ChildPath $relativePath
        }
    }
    
    # Fallback: just use folder name (legacy behavior)
    $folderName = Split-Path -Path $LocalPath -Leaf
    return Join-Path -Path $RemotePath -ChildPath $folderName
}

#endregion

#region Label Type Detection

function Get-SALabelType {
    <#
    .SYNOPSIS
        Determines the label type for processing.
    .DESCRIPTION
        Returns the label type based on configuration:
        - 'tv' for TV show labels
        - 'movie' for movie labels
        - 'passthrough' for unknown labels (copy only, no processing)
    .PARAMETER Label
        The download label to check.
    .PARAMETER Config
        Configuration hashtable containing labels.tv, labels.tvLabels, labels.movie, labels.movieLabels.
    .OUTPUTS
        String: 'tv', 'movie', or 'passthrough'
    .EXAMPLE
        $type = Get-SALabelType -Label 'sonarr' -Config $config
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    # Check TV labels
    $tvLabels = @($Config.labels.tv)
    if ($Config.labels.tvLabels) {
        $tvLabels += $Config.labels.tvLabels
    }
    if ($Label -in $tvLabels -or $Label -eq 'tv') {
        return 'tv'
    }
    
    # Check movie labels
    $movieLabels = @($Config.labels.movie)
    if ($Config.labels.movieLabels) {
        $movieLabels += $Config.labels.movieLabels
    }
    if ($Label -in $movieLabels -or $Label -eq 'movie') {
        return 'movie'
    }
    
    # Unknown label = passthrough mode
    return 'passthrough'
}

#endregion
