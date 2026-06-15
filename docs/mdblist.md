# MDBList Collection Sync

After a successful import to Radarr or Sonarr, Stagearr can mark the imported movie or episode as "collected" on [MDBList](https://mdblist.com/). This updates the In Library status on your MDBList account, which powers dynamic list filtering.

---

## Why Use It

MDBList lets you build lists based on filters, including a "not collected" filter that excludes titles already in your library. Once Stagearr marks an import as collected, that title drops off any such list automatically. This is useful for watchlist management, automated requests via Overseerr/Jellyseerr, or keeping Radarr/Sonarr lists from re-requesting things you already own.

---

## Prerequisites

- A free MDBList account at [mdblist.com](https://mdblist.com/)
- An API key from your [MDBList preferences page](https://mdblist.com/preferences/) (under the API section)
- No Patreon or supporter subscription is required. Collection sync works on the free plan.

Stagearr reuses the tmdb, tvdb, and imdb IDs that Radarr and Sonarr already return from their import responses. No extra ID configuration is needed.

---

## Scope

- **Radarr (movies):** supported.
- **Sonarr (TV):** supported.
- **Medusa:** not supported in this version.

---

## How to Enable

Add the following section to `config.toml`:

```toml
[mdblist]
enabled = true
apiKey = "your_api_key_here"
timeoutSeconds = 10
```

Get your API key at [mdblist.com/preferences/](https://mdblist.com/preferences/) under the API section.

### Setup wizard

If you use the interactive setup wizard, it will prompt for MDBList settings when you run:

```powershell
.\Stagearr.ps1 -Setup
```

### Syncing new keys

After updating Stagearr, run the following to see whether any new `[mdblist]` keys were added since your last config update:

```powershell
.\Stagearr.ps1 -SyncConfig
```

This reports missing or extra keys without modifying your file.

---

## What Happens

### On success

After a successful import, Stagearr sends a POST to the MDBList collection sync API using the IDs provided by Radarr or Sonarr. Under the Import phase in the console you will see:

```
MDBList  Marked as collected
```

### On failure

If the MDBList call fails (invalid API key, network error, no usable ID), the import still succeeds and the job is not failed. The call is best-effort and non-fatal. The console shows:

```
MDBList  Not marked (non-fatal)
```

A warning is included in the email notification. Nothing prints if MDBList is disabled or if no usable ID was available.

---

## Granularity

### Movies

Movies are marked at the title level: the entire movie is flagged as collected.

### TV episodes

Stagearr marks the exact season and episode that imported, not the whole show. Season packs and partial imports are handled precisely: only the episodes that actually imported are marked as collected. Episodes you already owned were filtered out before import and are not re-marked.

### Title-level list behavior

MDBList evaluates a show as "collected" for title-level lists (such as a "not collected" TV list) as soon as any episode is collected. This means that once Stagearr marks even one episode, the show drops off that list. This is the intended behavior of such a list: you have started collecting the show, so it is no longer "not collected."

If you are using episode-level filtering rather than title-level filtering, only the specific episodes you have collected are considered.

---

## Troubleshooting

### "MDBList: Not marked (non-fatal)"

This warning appears in the console and email when the collection sync call did not succeed. The import itself still completed normally. Common causes:

| Cause | Fix |
|-------|-----|
| Invalid or empty API key | Verify your API key at [mdblist.com/preferences/](https://mdblist.com/preferences/) under the API section and update `mdblist.apiKey` in `config.toml`. |
| No internet access or MDBList is down | Check that the machine running Stagearr can reach `api.mdblist.com`. Try again later if MDBList is experiencing an outage. |
| No usable ID for the item | The Radarr or Sonarr import response did not include a tmdb, tvdb, or imdb ID. Check that the item is correctly identified in your media server. |

Run with `-Verbose` to see the HTTP response from MDBList and confirm which error was returned.

---

## Configuration Summary

| Config key | Default | Description |
|-----------|---------|-------------|
| `mdblist.enabled` | `false` | Enable MDBList collection sync after import. |
| `mdblist.apiKey` | `""` | MDBList API key. Required when enabled. |
| `mdblist.timeoutSeconds` | `10` | HTTP request timeout for MDBList API calls. |

For all settings and their defaults, see the [Settings Reference](settings-reference.md#mdblist).
