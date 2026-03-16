#Requires -Version 5.1
<#
.SYNOPSIS
    TOML parser and writer for Stagearr configuration
.DESCRIPTION
    Lightweight TOML parser supporting the subset used by config files:
    - [section] and [section.subsection] table headers
    - Key-value pairs: strings, booleans, integers, arrays of strings
    - # comments (full-line and inline)
    - Multi-line arrays

    Also provides a writer that preserves comment structure from a sample file.
#>

function ConvertFrom-SAToml {
    <#
    .SYNOPSIS
        Parses a TOML string into a hashtable.
    .PARAMETER Content
        The TOML content string to parse.
    .OUTPUTS
        [hashtable] Parsed configuration.
    .EXAMPLE
        $config = Get-Content 'config.toml' -Raw | ConvertFrom-SAToml
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Content
    )

    $result = @{}
    $currentSection = $null
    $lines = @($Content -split "`r?`n")
    $i = 0

    while ($i -lt $lines.Count) {
        $line = $lines[$i]

        # Strip full-line comments and blank lines
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            $i++
            continue
        }

        # Table header: [section] or [section.subsection]
        if ($trimmed -match '^\[([^\]]+)\]$') {
            $currentSection = $Matches[1].Trim()
            $i++
            continue
        }

        # Key-value pair
        if ($trimmed -match '^([A-Za-z0-9_-]+)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $rawValue = $Matches[2].Trim()

            # Parse the value (may consume additional lines for multi-line arrays)
            $parseResult = ConvertFrom-SATomlValue -RawValue $rawValue -Lines $lines -StartIndex $i
            $value = $parseResult.Value
            $i = $parseResult.NextIndex

            # Place into correct section
            if ($currentSection) {
                $parts = $currentSection -split '\.'
                $target = $result
                foreach ($part in $parts) {
                    if (-not $target.ContainsKey($part)) {
                        $target[$part] = @{}
                    }
                    $target = $target[$part]
                }
                $target[$key] = $value
            } else {
                $result[$key] = $value
            }
            continue
        }

        # Unrecognized line — skip
        $i++
    }

    return $result
}

function ConvertFrom-SATomlValue {
    <#
    .SYNOPSIS
        Parses a TOML value, handling multi-line arrays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RawValue,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [int]$StartIndex
    )

    # Strip inline comment (but not # inside quoted strings)
    $value = Remove-SATomlInlineComment -Text $RawValue

    # Boolean
    if ($value -eq 'true') {
        return @{ Value = $true; NextIndex = $StartIndex + 1 }
    }
    if ($value -eq 'false') {
        return @{ Value = $false; NextIndex = $StartIndex + 1 }
    }

    # Quoted string — unescape TOML basic string escapes
    if ($value -match '^"(.*)"$') {
        $str = $Matches[1] -replace '\\\\', "`0" -replace '\\"', '"' -replace "`0", '\'
        return @{ Value = $str; NextIndex = $StartIndex + 1 }
    }

    # Integer
    if ($value -match '^-?\d+$') {
        return @{ Value = [int]$value; NextIndex = $StartIndex + 1 }
    }

    # Array (possibly multi-line)
    if ($value.StartsWith('[')) {
        # Collect full array text, potentially spanning multiple lines
        $arrayText = $value
        $nextIndex = $StartIndex + 1

        # If the array isn't closed on this line, keep reading
        while (-not (Test-SATomlArrayClosed -Text $arrayText)) {
            if ($nextIndex -ge $Lines.Count) {
                throw "Unterminated array starting at line $($StartIndex + 1)"
            }
            $arrayText += ' ' + $Lines[$nextIndex].Trim()
            $nextIndex++
        }

        # Parse array contents
        $items = ConvertFrom-SATomlArray -ArrayText $arrayText
        return @{ Value = $items; NextIndex = $nextIndex }
    }

    # Unquoted string (fallback)
    return @{ Value = $value; NextIndex = $StartIndex + 1 }
}

function Remove-SATomlInlineComment {
    <#
    .SYNOPSIS
        Removes inline comments from a TOML value, respecting quoted strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $inQuote = $false
    for ($j = 0; $j -lt $Text.Length; $j++) {
        $ch = $Text[$j]
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
        }
        elseif ($ch -eq '#' -and -not $inQuote) {
            return $Text.Substring(0, $j).Trim()
        }
    }
    return $Text.Trim()
}

function Test-SATomlArrayClosed {
    <#
    .SYNOPSIS
        Checks if an array literal has balanced brackets (is fully closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $depth = 0
    $inQuote = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote }
        if (-not $inQuote) {
            if ($ch -eq '[') { $depth++ }
            if ($ch -eq ']') { $depth-- }
        }
    }
    return $depth -le 0
}

function ConvertFrom-SATomlArray {
    <#
    .SYNOPSIS
        Parses a TOML array literal into a PowerShell array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArrayText
    )

    # Strip outer brackets
    $inner = $ArrayText.Trim()
    if ($inner.StartsWith('[')) { $inner = $inner.Substring(1) }
    if ($inner.EndsWith(']')) { $inner = $inner.Substring(0, $inner.Length - 1) }

    $inner = $inner.Trim()
    if ($inner -eq '') {
        return , @()
    }

    # Split by comma, respecting quotes
    $items = [System.Collections.Generic.List[object]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuote = $false

    foreach ($ch in $inner.ToCharArray()) {
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
            [void]$current.Append($ch)
        }
        elseif ($ch -eq ',' -and -not $inQuote) {
            $element = $current.ToString().Trim()
            if ($element -ne '') {
                $items.Add((ConvertFrom-SATomlScalar -Text $element))
            }
            [void]$current.Clear()
        }
        else {
            [void]$current.Append($ch)
        }
    }

    # Last element
    $element = $current.ToString().Trim()
    if ($element -ne '') {
        $items.Add((ConvertFrom-SATomlScalar -Text $element))
    }

    return @($items.ToArray())
}

function ConvertFrom-SATomlScalar {
    <#
    .SYNOPSIS
        Parses a single TOML scalar value (string, bool, integer).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $Text = Remove-SATomlInlineComment -Text $Text

    if ($Text -eq 'true') { return $true }
    if ($Text -eq 'false') { return $false }
    if ($Text -match '^"(.*)"$') {
        return ($Matches[1] -replace '\\\\', "`0" -replace '\\"', '"' -replace "`0", '\')
    }
    if ($Text -match '^-?\d+$') { return [int]$Text }
    return $Text
}

function ConvertTo-SAToml {
    <#
    .SYNOPSIS
        Writes a config hashtable to TOML format, preserving the sample file's comment structure.
    .DESCRIPTION
        Reads the sample TOML file to get the layout and comments, then replaces values
        with the provided config. This ensures generated config files maintain the nice
        commented structure from the sample.
    .PARAMETER Config
        The configuration hashtable to write.
    .PARAMETER SamplePath
        Path to the sample TOML file to use as template.
    .OUTPUTS
        [string] The TOML-formatted configuration.
    .EXAMPLE
        $toml = ConvertTo-SAToml -Config $config -SamplePath 'config-sample.toml'
        Set-Content -Path 'config.toml' -Value $toml
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$SamplePath
    )

    if (-not (Test-Path -LiteralPath $SamplePath)) {
        throw "Sample config not found: $SamplePath"
    }

    $sampleLines = Get-Content -LiteralPath $SamplePath
    $output = [System.Text.StringBuilder]::new()
    $currentSection = $null
    $i = 0

    while ($i -lt $sampleLines.Count) {
        $line = $sampleLines[$i]
        $trimmed = $line.Trim()

        # Blank lines and comment lines — pass through
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            [void]$output.AppendLine($line)
            $i++
            continue
        }

        # Table header
        if ($trimmed -match '^\[([^\]]+)\]$') {
            $currentSection = $Matches[1].Trim()
            [void]$output.AppendLine($line)
            $i++
            continue
        }

        # Key-value pair — replace value from config
        if ($trimmed -match '^([A-Za-z0-9_-]+)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $rawValue = $Matches[2].Trim()

            # Skip multi-line array lines in sample
            if ($rawValue.StartsWith('[') -and -not (Test-SATomlArrayClosed -Text $rawValue)) {
                $skipIndex = $i + 1
                while ($skipIndex -lt $sampleLines.Count) {
                    $rawValue += ' ' + $sampleLines[$skipIndex].Trim()
                    if (Test-SATomlArrayClosed -Text $rawValue) {
                        break
                    }
                    $skipIndex++
                }
                $i = $skipIndex + 1
            } else {
                $i++
            }

            # Extract inline comment from sample line
            $inlineComment = ''
            $sampleValue = Remove-SATomlInlineComment -Text $Matches[2].Trim()
            $afterValue = $Matches[2].Trim()
            if ($afterValue.Length -gt $sampleValue.Length) {
                # There's content after the value — it's an inline comment
                $commentStart = $afterValue.IndexOf('#', $sampleValue.Length)
                if ($commentStart -ge 0) {
                    $inlineComment = ' ' + $afterValue.Substring($commentStart)
                }
            }

            # Look up the value in the config
            $configValue = $null
            $found = $false

            if ($currentSection) {
                $parts = $currentSection -split '\.'
                $target = $Config
                $valid = $true
                foreach ($part in $parts) {
                    if ($target -is [hashtable] -and $target.ContainsKey($part)) {
                        $target = $target[$part]
                    } else {
                        $valid = $false
                        break
                    }
                }
                if ($valid -and $target -is [hashtable] -and $target.ContainsKey($key)) {
                    $configValue = $target[$key]
                    $found = $true
                }
            } else {
                if ($Config.ContainsKey($key)) {
                    $configValue = $Config[$key]
                    $found = $true
                }
            }

            # Determine indentation from original line
            $indent = ''
            if ($line -match '^(\s+)') {
                $indent = $Matches[1]
            }

            # Format the value
            $formattedValue = if ($found) {
                ConvertTo-SATomlValueString -Value $configValue
            } else {
                # Keep sample default
                $sampleValue
            }

            $outputLine = "${indent}${key} = ${formattedValue}"
            if ($inlineComment) {
                $outputLine += $inlineComment
            }
            [void]$output.AppendLine($outputLine)
            continue
        }

        # Other lines — pass through
        [void]$output.AppendLine($line)
        $i++
    }

    # Remove trailing newline to match file convention
    $text = $output.ToString()
    return $text.TrimEnd("`r`n") + "`n"
}

function ConvertTo-SATomlValueString {
    <#
    .SYNOPSIS
        Converts a PowerShell value to its TOML string representation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        $Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -is [bool]) {
        if ($Value) { return 'true' } else { return 'false' }
    }

    if ($Value -is [int] -or $Value -is [long]) {
        return "$Value"
    }

    if ($Value -is [array]) {
        $elements = foreach ($item in $Value) {
            ConvertTo-SATomlValueString -Value $item
        }
        return '[' + ($elements -join ', ') + ']'
    }

    # String — quote it
    return '"' + $Value.ToString().Replace('\', '\\').Replace('"', '\"') + '"'
}
