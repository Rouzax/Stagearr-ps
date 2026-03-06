#Requires -Version 5.1
<#
.SYNOPSIS
    Path validation and security utilities.
.DESCRIPTION
    Functions to validate paths and prevent security issues:
    - Path traversal attack prevention
    - Safe filename generation
    - Sample file detection
    
    SECURITY: These functions are critical for preventing malicious
    archive contents from escaping intended directories.
    
    Used by: Video.ps1 (RAR extraction), Staging.ps1, JobProcessor.ps1
#>

function Get-SASafeName {
    <#
    .SYNOPSIS
        Sanitizes a name for safe use in file paths.
    .DESCRIPTION
        Removes or replaces characters that could be used for path traversal
        or are invalid in file/folder names. This is a critical security function.
    .PARAMETER Name
        The name to sanitize (e.g., download label, folder name).
    .EXAMPLE
        Get-SASafeName -Name "..\..\..\Windows"
        # Returns: "______Windows"
    .EXAMPLE
        Get-SASafeName -Name "Movie<>Title"
        # Returns: "Movie__Title"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )
    
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-SAVerbose -Label "Sanitize" -Text "Empty input -> 'unnamed'"
        return 'unnamed'
    }
    
    $original = $Name
    
    # Replace invalid filename characters: < > : " / \ | ? *
    $safe = $Name -replace '[<>:"/\\|?*]', '_'
    
    # Replace path traversal sequences (..)
    $safe = $safe -replace '\.\.', '_'
    
    # Trim leading/trailing dots and spaces (invalid on Windows)
    $safe = $safe.Trim('. ')
    
    # Final check for empty result
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'unnamed'
    }
    
    # Only log if sanitization changed the input
    if ($safe -ne $original) {
        Write-SAVerbose -Label "Sanitize" -Text "'$original' -> '$safe'"
    }
    
    return $safe
}

function Assert-SAPathUnderRoot {
    <#
    .SYNOPSIS
        Validates that a path is within the specified root boundary.
    .DESCRIPTION
        Critical security function that prevents path traversal attacks.
        Resolves both paths to their canonical form and verifies the target
        path starts with the root path. Throws an exception if validation fails.
    .PARAMETER Path
        The path to validate.
    .PARAMETER Root
        The root boundary path that the target must be under.
    .EXAMPLE
        Assert-SAPathUnderRoot -Path "C:\Staging\label\file" -Root "C:\Staging"
        # Succeeds silently
    .EXAMPLE
        Assert-SAPathUnderRoot -Path "C:\Staging\..\Windows" -Root "C:\Staging"
        # Throws: Path escapes root boundary
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$Root
    )
    
    # Resolve to canonical (full) paths
    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    
    # Ensure root ends with directory separator for accurate comparison
    if (-not $resolvedRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $resolvedRoot = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    }
    
    # Check if path starts with root
    if (-not $resolvedPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Also allow exact match (path equals root without trailing separator)
        $rootWithoutSep = $resolvedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not $resolvedPath.Equals($rootWithoutSep, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Security violation: Path '$Path' escapes root boundary '$Root'"
        }
    }
}

function Test-SASamplePath {
    <#
    .SYNOPSIS
        Tests if a path is or contains a "Sample" folder (case-insensitive).
    .DESCRIPTION
        Detects sample files that should be excluded from processing.
        Checks for:
        - /Sample/ or \Sample\ directories in path
        - .sample. in filename
        
        Sample files are typically short preview clips included in releases
        that should not be imported to media libraries.
    .PARAMETER Path
        The path to test.
    .EXAMPLE
        Test-SASamplePath -Path "C:\Movies\Film\Sample\sample.mkv"
        # Returns: $true
    .EXAMPLE
        Test-SASamplePath -Path "C:\Movies\Film\movie.mkv"
        # Returns: $false
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    # Check for /Sample/ or \Sample\ in path
    if ($Path -match '(?i)(\\|/)Sample(\\|/)') {
        return $true
    }
    
    # Check for .sample. in filename
    $fileName = Split-Path -Path $Path -Leaf
    if ($fileName -match '(?i)\.sample\.') {
        return $true
    }
    
    return $false
}
