# Local *arr Poster Download

## Problem

Sonarr poster images use TheTVDB CDN URLs which don't support URL-based resizing
(unlike TMDb's `/t/p/{size}/` pattern used by Radarr). The full-resolution poster
(680x1000, ~200KB) downloads from an external CDN with a 5-second timeout. On slow
connections, the download truncates silently — PowerShell accepts the partial response
as complete (chunked encoding, no Content-Length mismatch). The resulting JPEG is
missing its EOI marker, causing green block artifacts in the bottom half.

## Solution

Download posters from the local *arr server instead of the external CDN. Sonarr and
Radarr cache all posters locally and serve them at `/api/v3/{localPath}` with
`X-Api-Key` authentication. This is a LAN download — fast and reliable.

## Changes

### 1. ConvertTo-SAArrMetadata (ArrMetadata.ps1)

Capture `$posterImage.url` (local path like `/MediaCover/123/poster.jpg?lastWrite=...`)
alongside the existing `remoteUrl`. Store as `PosterLocalPath` in the returned hashtable.

### 2. Get-SAArrPosterData (ArrMetadata.ps1)

- Add `ArrConfig` parameter (importer config hashtable with host, port, apiKey, etc.)
- Add `PosterLocalPath` parameter (the local path from metadata)
- Construct local URL: `Get-SAImporterBaseUrl` + `/api/v3` + local path
- Download with `X-Api-Key` header
- Remove CDN-only download path (keep `PosterUrl` parameter as unused fallback)
- Add JPEG EOI marker validation: check last 2 bytes are `0xFF 0xD9`
- Return `$null` if validation fails (no poster better than corrupt poster)

### 3. JobProcessor.ps1

- Determine which importer config was used (from label type + config, same logic as
  `Invoke-SAImport`)
- Pass `ArrConfig` and `PosterLocalPath` to `Get-SAArrPosterData`

### Unchanged

- `Get-SAOmdbPosterData` (Omdb.ps1) — OMDb/Amazon CDN works fine, no changes needed
- Radarr flow also benefits — downloads from local Radarr instead of TMDb CDN
