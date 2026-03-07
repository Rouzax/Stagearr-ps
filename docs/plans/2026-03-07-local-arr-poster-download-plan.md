# Local *arr Poster Download — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix poster corruption by downloading from local *arr server instead of external CDN.

**Architecture:** `ConvertTo-SAArrMetadata` captures the local poster path from the API response. `Get-SAArrPosterData` is refactored to download from the *arr server (LAN) using `Get-SAImporterBaseUrl` + `X-Api-Key` header. JobProcessor resolves which importer config to use and passes it through. JPEG EOI validation as safety net.

**Tech Stack:** PowerShell 5.1+/7.x, Invoke-WebRequest

---

### Task 1: Add PosterLocalPath to ConvertTo-SAArrMetadata

**Files:**
- Modify: `Modules/Stagearr.Core/Private/ArrMetadata.ps1:156-192`

**Step 1: Update poster URL extraction to also capture local path**

In `ConvertTo-SAArrMetadata`, replace lines 156-165:

```powershell
    # Extract poster URLs
    # remoteUrl: CDN URL (TMDb/TheTVDB) — kept as fallback reference
    # url: local *arr proxy path (e.g. /MediaCover/123/poster.jpg) — preferred source
    $posterUrl = $null
    $posterLocalPath = $null
    if ($null -ne $media.images -and $media.images.Count -gt 0) {
        $posterImage = $media.images | Where-Object { $_.coverType -eq 'poster' } | Select-Object -First 1
        if ($null -ne $posterImage) {
            if (-not [string]::IsNullOrWhiteSpace($posterImage.remoteUrl)) {
                $posterUrl = $posterImage.remoteUrl -replace '/original/', "/$PosterSize/"
            }
            if (-not [string]::IsNullOrWhiteSpace($posterImage.url)) {
                $posterLocalPath = $posterImage.url
            }
        }
    }
```

**Step 2: Add PosterLocalPath to the result hashtable**

In the result hashtable (line 174-190), add `PosterLocalPath` after `PosterUrl`:

```powershell
        PosterUrl       = $posterUrl       # CDN URL — fallback reference
        PosterLocalPath = $posterLocalPath  # Local *arr path — preferred for download
        PosterData      = $null            # Will be populated by Get-SAArrPosterData
```

**Step 3: Verify syntax**

Run: `pwsh -NoProfile -Command "Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force -ErrorAction Stop; Write-Host 'OK'"`
Expected: `OK`

**Step 4: Commit**

```bash
git add Modules/Stagearr.Core/Private/ArrMetadata.ps1
git commit -m "Add PosterLocalPath to arr metadata for local poster download"
```

---

### Task 2: Refactor Get-SAArrPosterData for local *arr download

**Files:**
- Modify: `Modules/Stagearr.Core/Private/ArrMetadata.ps1:472-614`

**Step 1: Replace Get-SAArrPosterData with local download implementation**

Replace the entire function (lines 472-614) with:

```powershell
function Get-SAArrPosterData {
    <#
    .SYNOPSIS
        Downloads poster image from local *arr server.
    .DESCRIPTION
        Downloads a poster image from the local Sonarr/Radarr server's cached poster
        and returns it in the format expected by the email system (Bytes, MimeType, ContentId).

        Uses the *arr's /api/v3/{localPath} endpoint with X-Api-Key authentication.
        This avoids external CDN downloads (TheTVDB/TMDb) which can silently truncate
        on slow connections, producing corrupt JPEG images.

        Validates JPEG integrity after download — returns $null if truncated.
    .PARAMETER PosterLocalPath
        Local *arr poster path (e.g., /MediaCover/123/poster.jpg?lastWrite=...).
        From the 'url' field in the *arr images array.
    .PARAMETER ArrConfig
        Importer configuration hashtable (host, port, apiKey, ssl, urlRoot).
        Used to construct the base URL via Get-SAImporterBaseUrl.
    .PARAMETER TimeoutSeconds
        Request timeout (default: 10).
    .OUTPUTS
        Hashtable with Bytes, MimeType, ContentId - or $null on failure.
    .EXAMPLE
        $metadata = ConvertTo-SAArrMetadata -ScanResult $file -AppType 'Sonarr'
        if ($metadata.PosterLocalPath) {
            $metadata.PosterData = Get-SAArrPosterData -PosterLocalPath $metadata.PosterLocalPath -ArrConfig $config.importers.sonarr
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PosterLocalPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$ArrConfig,

        [Parameter()]
        [int]$TimeoutSeconds = 10
    )

    if ([string]::IsNullOrWhiteSpace($PosterLocalPath)) {
        return $null
    }

    # Build local URL: base URL + /api/v3 + local path
    $urlInfo = Get-SAImporterBaseUrl -Config $ArrConfig
    # Strip leading slash from local path if present to avoid double slash
    $cleanPath = $PosterLocalPath.TrimStart('/')
    $posterUrl = "$($urlInfo.Url)/api/v3/$cleanPath"

    Write-SAVerbose -Label 'Poster' -Text "Downloading poster..."

    # Ensure TLS 1.2 for PowerShell 5.1
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    try {
        $requestParams = @{
            Uri             = $posterUrl
            Method          = 'GET'
            TimeoutSec      = $TimeoutSeconds
            UseBasicParsing = $true
            Headers         = @{ 'X-Api-Key' = $ArrConfig.apiKey }
            ErrorAction     = 'Stop'
        }

        # Add Host header for reverse proxy compatibility
        if ($urlInfo.HostHeader) {
            $requestParams.Headers['Host'] = $urlInfo.HostHeader
        }

        $response = Invoke-WebRequest @requestParams -Verbose:$false

        if ($response.StatusCode -ne 200) {
            Write-SAVerbose -Label 'Poster' -Text "Poster download failed: HTTP $($response.StatusCode)"
            return $null
        }

        # Get raw bytes - handle PS5.1 vs PS7 differences
        $imageBytes = $null

        if ($response.RawContentStream) {
            $response.RawContentStream.Position = 0
            $memStream = New-Object System.IO.MemoryStream
            $response.RawContentStream.CopyTo($memStream)
            $imageBytes = $memStream.ToArray()
            $memStream.Dispose()
        } elseif ($response.Content -is [byte[]]) {
            $imageBytes = $response.Content
        } elseif ($response.Content -is [string]) {
            Write-SAVerbose -Label 'Poster' -Text 'Content returned as string, attempting byte conversion'
            $imageBytes = [System.Text.Encoding]::ISO88591.GetBytes($response.Content)
        } else {
            $imageBytes = $response.Content
        }

        if ($null -eq $imageBytes -or $imageBytes.Length -eq 0) {
            Write-SAVerbose -Label 'Poster' -Text 'Poster download returned empty content'
            return $null
        }

        # Validate JPEG integrity — truncated downloads produce corrupt images
        $isJpeg = $imageBytes.Length -ge 2 -and $imageBytes[0] -eq 0xFF -and $imageBytes[1] -eq 0xD8
        if ($isJpeg -and ($imageBytes[$imageBytes.Length - 2] -ne 0xFF -or $imageBytes[$imageBytes.Length - 1] -ne 0xD9)) {
            $sizeKb = [math]::Round($imageBytes.Length / 1024, 0)
            Write-SAVerbose -Label 'Poster' -Text "Poster appears truncated (missing JPEG EOI marker, $sizeKb KB)"
            return $null
        }

        # Determine MIME type from URL or default to JPEG
        $mimeType = 'image/jpeg'
        if ($PosterLocalPath -match '\.png($|\?)') {
            $mimeType = 'image/png'
        } elseif ($PosterLocalPath -match '\.gif($|\?)') {
            $mimeType = 'image/gif'
        } elseif ($PosterLocalPath -match '\.webp($|\?)') {
            $mimeType = 'image/webp'
        }

        # Generate unique Content-ID with extension for Mailozaurr compatibility
        $ext = switch ($mimeType) {
            'image/png'  { '.png' }
            'image/gif'  { '.gif' }
            'image/webp' { '.webp' }
            default      { '.jpg' }
        }
        $contentId = "poster-$([guid]::NewGuid().ToString('N').Substring(0, 8))$ext"

        $sizeKb = [math]::Round($imageBytes.Length / 1024, 0)
        Write-SAVerbose -Label 'Poster' -Text "Downloaded ($sizeKb KB, CID: $contentId)"

        return @{
            Bytes     = $imageBytes
            MimeType  = $mimeType
            ContentId = $contentId
        }

    } catch [System.Net.WebException] {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match 'timed out') {
            Write-SAVerbose -Label 'Poster' -Text "Poster download timed out after $TimeoutSeconds seconds"
        } elseif ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            Write-SAVerbose -Label 'Poster' -Text 'Poster not found (404)'
        } else {
            Write-SAVerbose -Label 'Poster' -Text "Poster download failed: $errorMsg"
        }
        return $null

    } catch {
        Write-SAVerbose -Label 'Poster' -Text "Poster download failed: $($_.Exception.Message)"
        return $null
    }
}
```

**Step 2: Verify syntax**

Run: `pwsh -NoProfile -Command "Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force -ErrorAction Stop; Write-Host 'OK'"`
Expected: `OK`

**Step 3: Commit**

```bash
git add Modules/Stagearr.Core/Private/ArrMetadata.ps1
git commit -m "Refactor Get-SAArrPosterData to download from local *arr server

Downloads from local Sonarr/Radarr poster cache via /api/v3/{path}
with X-Api-Key auth instead of external CDN (TheTVDB/TMDb).
Adds JPEG EOI marker validation to catch any truncated downloads."
```

---

### Task 3: Update Get-SAArrMetadataFromScan convenience function

**Files:**
- Modify: `Modules/Stagearr.Core/Private/ArrMetadata.ps1:620-709`

This function is currently unused but should stay consistent with the new API.

**Step 1: Add ArrConfig parameter and update poster download call**

Add `ArrConfig` parameter to the function:

```powershell
        [Parameter()]
        [hashtable]$ArrConfig,
```

Update the poster download block (lines 695-698) from:

```powershell
    if ($DownloadPoster -and -not [string]::IsNullOrWhiteSpace($metadata.PosterUrl)) {
        $metadata.PosterData = Get-SAArrPosterData -PosterUrl $metadata.PosterUrl
    }
```

To:

```powershell
    if ($DownloadPoster -and $null -ne $ArrConfig -and -not [string]::IsNullOrWhiteSpace($metadata.PosterLocalPath)) {
        $metadata.PosterData = Get-SAArrPosterData -PosterLocalPath $metadata.PosterLocalPath -ArrConfig $ArrConfig
    }
```

**Step 2: Verify syntax**

Run: `pwsh -NoProfile -Command "Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force -ErrorAction Stop; Write-Host 'OK'"`
Expected: `OK`

**Step 3: Commit**

```bash
git add Modules/Stagearr.Core/Private/ArrMetadata.ps1
git commit -m "Update Get-SAArrMetadataFromScan for local poster download API"
```

---

### Task 4: Update JobProcessor to pass arr config for poster download

**Files:**
- Modify: `Modules/Stagearr.Core/Public/JobProcessor.ps1:659-672`

**Step 1: Replace the poster download block**

Replace lines 659-672 (the `elseif` block for ArrMetadata):

```powershell
    } elseif ($null -ne $importResult -and $null -ne $importResult.ArrMetadata) {
        # Auto mode with ArrMetadata available
        $omdbData = $importResult.ArrMetadata
        Write-SAVerbose -Text "Email metadata: Using ArrMetadata from $($importResult.ArrMetadata.Source)"

        # Download poster from local *arr server if enabled and local path available
        $posterEnabled = $Context.Config.omdb.poster.enabled -ne $false
        if ($posterEnabled -and -not [string]::IsNullOrWhiteSpace($omdbData.PosterLocalPath) -and $null -eq $omdbData.PosterData) {
            # Resolve which importer config to use
            $labelType = Get-SALabelType -Label $Context.State.ProcessingLabel -Config $Context.Config
            $arrConfig = switch ($labelType) {
                'tv'    { $Context.Config.importers.sonarr }
                'movie' { $Context.Config.importers.radarr }
                default { $null }
            }
            if ($null -ne $arrConfig) {
                $omdbData.PosterData = Get-SAArrPosterData -PosterLocalPath $omdbData.PosterLocalPath -ArrConfig $arrConfig
            }
        }
```

This removes the TMDb URL size replacement logic (no longer needed — we download from the local server) and resolves the correct importer config from the label type.

**Step 2: Verify syntax**

Run: `pwsh -NoProfile -Command "Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force -ErrorAction Stop; Write-Host 'OK'"`
Expected: `OK`

**Step 3: Commit**

```bash
git add Modules/Stagearr.Core/Public/JobProcessor.ps1
git commit -m "Download poster from local *arr server instead of CDN

Resolves importer config from label type and passes it to
Get-SAArrPosterData for local LAN download. Removes CDN URL
size replacement logic that didn't work for TheTVDB URLs."
```

---

### Task 5: Smoke test against live Sonarr

**Step 1: Test local poster download via PowerShell**

Run:
```bash
pwsh -NoProfile -Command '
Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force
$config = @{ host = "download.home.lan"; port = 8989; apiKey = "b4b941e66ea54777abb58be1e8135d34"; ssl = $false; urlRoot = "" }
$result = Get-SAArrPosterData -PosterLocalPath "/MediaCover/1/poster.jpg?lastWrite=639083191098108416" -ArrConfig $config
if ($result) {
    $last2 = "{0:X2} {1:X2}" -f $result.Bytes[$result.Bytes.Length - 2], $result.Bytes[$result.Bytes.Length - 1]
    Write-Host "Size: $($result.Bytes.Length) bytes, MIME: $($result.MimeType), CID: $($result.ContentId), EOI: $last2"
} else {
    Write-Host "FAILED: returned null"
}
'
```

Expected: `Size: 203690 bytes, MIME: image/jpeg, CID: poster-XXXXXXXX.jpg, EOI: FF D9`

**Step 2: Test with Radarr too**

Run:
```bash
pwsh -NoProfile -Command '
Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force
$config = @{ host = "download.home.lan"; port = 7878; apiKey = "b1f40c11096045d1bed72a2d32687c97"; ssl = $false; urlRoot = "" }
$result = Get-SAArrPosterData -PosterLocalPath "/MediaCover/975/poster.jpg?lastWrite=638870210159828389" -ArrConfig $config
if ($result) {
    $last2 = "{0:X2} {1:X2}" -f $result.Bytes[$result.Bytes.Length - 2], $result.Bytes[$result.Bytes.Length - 1]
    Write-Host "Size: $($result.Bytes.Length) bytes, MIME: $($result.MimeType), CID: $($result.ContentId), EOI: $last2"
} else {
    Write-Host "FAILED: returned null"
}
'
```

Expected: Similar output with valid JPEG.

---

### Task 6: Update documentation

**Files:**
- Modify: `Docs/FUNCTION-REFERENCE.md`

**Step 1: Update Get-SAArrPosterData entry**

Find the entry for `Get-SAArrPosterData` and update its signature to reflect the new parameters (`PosterLocalPath`, `ArrConfig` instead of `PosterUrl`).

**Step 2: Commit**

```bash
git add Docs/FUNCTION-REFERENCE.md
git commit -m "Update function reference for local poster download changes"
```
