#Requires -Version 7.0
<#
.SYNOPSIS
    Subtitle cleanup engine resolution and argument building (pure helpers).
#>

function Resolve-SASubtitleTool {
    <#
    .SYNOPSIS
        Resolves a configured subtitle-tool path (install dir or binary) to a concrete
        binary and engine tag.
    .DESCRIPTION
        Pure-ish (filesystem reads only). When the path is a directory, seconv is
        preferred over the SubtitleEdit GUI. Engine is detected from the binary's leaf
        name: a leaf starting with 'seconv' -> 'Seconv', otherwise 'SubtitleEditGui'.
    .PARAMETER Path
        The configured tools.subtitleEdit value (may be a directory, a binary, or empty).
    .OUTPUTS
        PSCustomObject with Path (resolved binary or '') and Engine ('Seconv',
        'SubtitleEditGui', or $null when nothing resolves).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    $none = [pscustomobject]@{ Path = ''; Engine = $null }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $none }

    $resolved = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $resolved = $Path
    }
    elseif (Test-Path -LiteralPath $Path -PathType Container) {
        # seconv preferred over the GUI when both are present
        $candidates = @('seconv', 'seconv.exe', 'SubtitleEdit.exe')
        foreach ($name in $candidates) {
            $candidate = Join-Path -Path $Path -ChildPath $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $resolved = $candidate
                break
            }
        }
    }

    if (-not $resolved) { return $none }

    $leaf = Split-Path -Path $resolved -Leaf
    $engine = if ($leaf -match '^(?i)seconv') { 'Seconv' } else { 'SubtitleEditGui' }
    return [pscustomobject]@{ Path = $resolved; Engine = $engine }
}

function Get-SACleanupOperations {
    <#
    .SYNOPSIS
        Maps [subtitles.cleanup] toggles to an ordered operation set (production order).
    .DESCRIPTION
        Pure. Order is fixed: MergeSameTexts, RemoveTextForHI, FixCommonErrors, SplitLongLines
        (matching the legacy /MergeSameTexts /RemoveTextForHI /FixCommonErrors pipeline).
        Missing toggles default to the documented defaults (split defaults off).
    .PARAMETER CleanupConfig
        The subtitles.cleanup config hashtable.
    .OUTPUTS
        Ordered dictionary of operation name -> bool.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CleanupConfig
    )

    function _bool($value, $default) {
        if ($null -eq $value) { return $default }
        return [bool]$value
    }

    $ops = [ordered]@{}
    $ops['MergeSameTexts']  = _bool $CleanupConfig.mergeSameTexts        $true
    $ops['RemoveTextForHI'] = _bool $CleanupConfig.removeHearingImpaired $true
    $ops['FixCommonErrors'] = _bool $CleanupConfig.fixCommonErrors       $true
    $ops['SplitLongLines']  = _bool $CleanupConfig.splitLongLines        $false
    return $ops
}

function Get-SAGuiCleanupArgs {
    <#
    .SYNOPSIS
        Builds SubtitleEdit GUI /convert batch arguments from an ordered operation set.
    .OUTPUTS
        [string[]] argument array for SubtitleEdit.exe.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Operations
    )

    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@('/convert', '*.srt', 'subrip', "/inputfolder:$FolderPath", '/overwrite'))
    if ($Operations['MergeSameTexts'])  { $argList.Add('/MergeSameTexts') }
    if ($Operations['RemoveTextForHI']) { $argList.Add('/RemoveTextForHI') }
    if ($Operations['FixCommonErrors']) { $argList.Add('/FixCommonErrors') }
    # GUI has no CLI line-split flag; FixCommonErrors handles wrapping. SplitLongLines is seconv-only.
    $argList.Add("/outputfolder:$FolderPath")
    return $argList.ToArray()
}

function Get-SASeconvCleanupArgs {
    <#
    .SYNOPSIS
        Builds seconv batch arguments from an ordered operation set.
    .DESCRIPTION
        Operations are emitted in the order given. FixCommonErrors runs once (seconv
        converges internally). When a rules spec is provided, --fix-common-errors-rules
        replaces the bare --fix-common-errors flag (the rules flag implies FCE).
    .OUTPUTS
        [string[]] argument array for seconv.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Operations,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FixCommonErrorsRules,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SettingsPath
    )

    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@('*.srt', 'subrip', "--input-folder:$FolderPath", "--output-folder:$FolderPath", '--overwrite'))
    if ($Operations['MergeSameTexts'])  { $argList.Add('--merge-same-texts') }
    if ($Operations['RemoveTextForHI']) { $argList.Add('--remove-text-for-hi') }
    if ($Operations['FixCommonErrors']) {
        if ([string]::IsNullOrWhiteSpace($FixCommonErrorsRules)) {
            $argList.Add('--fix-common-errors')
        } else {
            $argList.Add("--fix-common-errors-rules:$FixCommonErrorsRules")
        }
    }
    if ($Operations['SplitLongLines']) { $argList.Add('--split-long-lines') }
    if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) { $argList.Add("--settings:$SettingsPath") }
    return $argList.ToArray()
}
