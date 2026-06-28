# MDBList Collection Sync

After a successful import to Radarr or Sonarr, Stagearr can mark the imported movie or TV show as "collected" on [MDBList](https://mdblist.com/). This updates the In Library status on your MDBList account, which powers dynamic list filtering.

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

### TV shows

TV is marked based on whether the show is fully downloaded, because MDBList's title-level list filters (such as a "not collected" list) only treat a show as collected when it has a show-level entry. Per-episode marking alone does not remove a show from those lists, even at 100% episode coverage.

- **Fully downloaded** (you have every aired, monitored episode): Stagearr marks the whole show as collected, so it drops off "not collected" title-level lists.
- **Partial** (you are missing one or more aired episodes): Stagearr marks only the episodes you imported, so the show stays on "not collected" / "get more" lists until you are caught up.

"Fully downloaded" is judged against aired, monitored episodes (using Sonarr's own episode counts), so a show you are caught up on counts as complete even if future episodes have not aired yet. When a new season starts and you are behind again, imports are marked episode-level until you complete it.

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

### Items I marked keep reappearing on my "not collected" list

If shows or movies you have imported (and that were marked collected) come back onto a title-level "not collected" MDBList list a day or two later, the cause is almost always MDBList's **Trakt collection sync overwriting MDBList's own collection**.

How it happens:

- In MDBList, **Preferences → Trakt → "Trakt Sync (Watchlist, Watched, Ratings, Library)"** periodically imports your Trakt collection. "Library" here means your collection.
- On each sync, MDBList makes its collection match Trakt. Anything in MDBList's collection that is **not** in your Trakt collection is pruned, including the entries Stagearr adds.
- Trakt's free tier caps how many items you can have collected. If your Trakt collection is at that cap, newly imported titles cannot be added to Trakt, so MDBList keeps removing them on every sync and they return to "not collected."

To confirm: the reappearance lines up with the "Last sync was ..." time shown under that toggle.

Fix: turn **off** the "Trakt Sync (Watchlist, Watched, Ratings, Library)" toggle in MDBList (Preferences → Trakt), then Save. MDBList then keeps its own collection and Stagearr's marks persist.

- There is no separate switch for only the collection ("Library"); disabling the master toggle also stops the watchlist / watched / ratings sync from Trakt into MDBList. Your Trakt account itself is not changed.
- Lists that filter on rating (for example "rating 6 or higher") are unaffected, because those use public ratings, not your synced personal data.
- After disabling, re-mark your existing library once so already-imported titles are collected (your media server can re-scan, or mark them in bulk).

---

## Configuration Summary

| Config key | Default | Description |
|-----------|---------|-------------|
| `mdblist.enabled` | `false` | Enable MDBList collection sync after import. |
| `mdblist.apiKey` | `""` | MDBList API key. Required when enabled. |
| `mdblist.timeoutSeconds` | `10` | HTTP request timeout for MDBList API calls. |

For all settings and their defaults, see the [Settings Reference](settings-reference.md#mdblist).
