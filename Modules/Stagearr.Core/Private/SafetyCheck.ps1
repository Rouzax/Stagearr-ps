#Requires -Version 5.1
<#
.SYNOPSIS
    Safety checks for downloaded content.
.DESCRIPTION
    Detects dangerous files (executables, scripts) in downloads that should
    only contain media files. Used by TV/Movie processing to catch malware
    disguised as media releases.
#>

function Test-SADangerousDownload {
    <#
    .SYNOPSIS
        Checks if a download contains only dangerous (executable/script) files.
    .DESCRIPTION
        Scans the source path for files with dangerous extensions. Returns dangerous
        ONLY when ALL files in the download are dangerous (no media or other harmless
        files present). A download with mixed content (e.g., .mkv + .exe) is NOT
        flagged - the normal pipeline will process the media and ignore the rest.
    .PARAMETER SourcePath
        Path to the download (file or folder).
    .OUTPUTS
        PSCustomObject with IsDangerous (bool) and DangerousFiles (array of names).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $safeResult = [PSCustomObject]@{
        IsDangerous    = $false
        DangerousFiles = @()
    }

    $dangerousExts = $script:SAConstants.DangerousExtensions

    # Single file
    if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
        $ext = [System.IO.Path]::GetExtension($SourcePath)
        if ($ext -and ($dangerousExts -contains $ext.ToLower())) {
            return [PSCustomObject]@{
                IsDangerous    = $true
                DangerousFiles = @([System.IO.Path]::GetFileName($SourcePath))
            }
        }
        return $safeResult
    }

    # Folder
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        return $safeResult
    }

    $allFiles = @(Get-ChildItem -LiteralPath $SourcePath -File -Recurse -ErrorAction SilentlyContinue)
    if ($allFiles.Count -eq 0) {
        return $safeResult
    }

    $dangerous = @($allFiles | Where-Object {
        $ext = $_.Extension
        $ext -and ($dangerousExts -contains $ext.ToLower())
    })

    if ($dangerous.Count -eq 0) {
        return $safeResult
    }

    # Only flag if ALL files are dangerous (no harmless files mixed in)
    $nonDangerous = @($allFiles | Where-Object {
        $ext = $_.Extension
        (-not $ext) -or ($dangerousExts -notcontains $ext.ToLower())
    })

    if ($nonDangerous.Count -gt 0) {
        return $safeResult
    }

    return [PSCustomObject]@{
        IsDangerous    = $true
        DangerousFiles = @($dangerous | ForEach-Object { $_.Name })
    }
}
