# Kodi Library Updates

After Radarr or Sonarr imports a title, Stagearr can scan just that title's folder in Kodi and confirm it appeared. This replaces the whole-library scans that Radarr and Sonarr usually trigger. The feature is optional and off by default.

---

## Why Use It

Radarr's Kodi connection scans your whole library for every new movie, and Sonarr does the same for new shows. On a large library each scan can take minutes, and a scan request that arrives during another scan cancels it.

With this feature on, Stagearr scans only the imported folder. It also tells you in the job log and email whether the title reached Kodi. A title Kodi could not match would otherwise go unnoticed.

---

## Prerequisites

- **Kodi's web server is on:** Settings > Services > Control > Allow remote control via HTTP. Note the port, and the username and password if you set them.
- **Your library is in a source Kodi already knows.** Stagearr scans inside your existing Movies and TV sources. It does not add sources.
- **`cleanonupdate` is on,** in Kodi's `advancedsettings.xml`. Stagearr never removes library entries itself. Without this setting, an upgrade leaves the old entry next to the new one.

    ```xml
    <advancedsettings>
      <videolibrary>
        <cleanonupdate>true</cleanonupdate>
      </videolibrary>
    </advancedsettings>
    ```

- **PowerShell 7.4 or later,** if any title has accents or other non-ASCII characters. Older versions may misread Kodi's reply, and such titles are then skipped.
- **`Ignore different video versions on scan` stays on** (the default, in Kodi's video library settings). When off, Kodi can open a prompt during an upgrade and wait for an answer, which blocks later scans.

**Not supported:** Kodi sources with a login inside the path, such as `smb://user:pass@SERVER/Media/`. Kodi hides the login when it lists folders, so the scan path would not match the library. Save the login in Kodi's password manager instead.

If several Kodi devices share one MySQL or MariaDB library, point Stagearr at just one of them. Choose one that stays on and has `cleanonupdate` set.

---

## Setup

Do these steps in this order. Changing Radarr and Sonarr last means you never have a gap where nothing updates Kodi.

**1. Add the settings** to `config.toml`:

```toml
[kodi]
enabled = true
host = "htpc.example.lan"
port = 8080
username = ""
password = ""
pathMap = ["D:\\Media\\|smb://SERVER/Media/"]
```

`pathMap` tells Stagearr how a Radarr or Sonarr path looks to Kodi. Each entry is `arrPath|kodiPath`, in one string, with each backslash doubled. Add one entry per library root if they do not share a parent.

To find the right values, compare a movie's path in Radarr with the same movie's path in Kodi. For example, `D:\Media\Movies\Film (2024)` in Radarr and `smb://SERVER/Media/Movies/Film (2024)/` in Kodi give the entry above.

**2. Test it.** Let one new movie and one new show come through Stagearr. Check that they appear in Kodi, and that the job log shows `Kodi: Scanned and confirmed`.

**3. Change Radarr and Sonarr.** In each app, open Settings > Connect > your Kodi connection, then untick **Update Library** and **Clean Library**. Leave the connection in place if you want its on-screen notifications.

---

## What Happens on Each Import

1. Stagearr finds the folder of each imported title. A pack with several titles gets one scan per title, and a season pack gets one scan of the show.
2. It maps the path and asks Kodi to list the parent folder, so it uses the exact path Kodi sees.
3. It waits for any running scan to finish, then scans the folder.
4. It waits for Kodi to finish and checks the title is in the library.

Your files are never changed. Kodi adds the new entry, and its own clean removes the old one after an upgrade.

Expect a scan to take from a few seconds to about half a minute. With `cleanonupdate` on, Kodi checks your whole library for missing files after every scan, so large libraries take longer. That clean can also remove entries for files that went missing elsewhere, as it does after a full scan.

Stagearr scans even if something is playing, because a job cannot wait for a film to finish.

---

## What Stops Updating Kodi

Once Update Library is off in Radarr and Sonarr, only imports that go through Stagearr reach Kodi. These do not, until you run a scan in Kodi:

- Files imported directly in Radarr or Sonarr
- Renamed files
- A title Stagearr skipped, as described below

Stagearr does not retry a skipped scan. To catch up, run a scan in Kodi: open Videos, then choose **Update library** from the side menu. Kodi's **Update library on startup** setting also does this on each start.

Upgrades lose the movie's watched state and any resume point, because Kodi treats the new file as a new item. This also happens with Radarr's own Kodi connection.

---

## Results in the Log and Email

| Result | Meaning | What to do |
|--------|---------|------------|
| `Kodi: Scanned and confirmed` | The title is in Kodi. | Nothing. |
| `Kodi: Not scanned` | The title did not reach Kodi. The email has a note with the reason. The job still counts as a success. | Fix the cause, then run a scan in Kodi. |
| `Kodi: Not everything reached Kodi` | Part of the job reached Kodi, or the scan ran but something is missing. The email warning names it. | See [Troubleshooting](troubleshooting.md#kodi-not-everything-reached-kodi). |

Kodi problems never fail a job. If Kodi is unreachable, Stagearr stops trying until the worker's next run, so a queue of jobs does not wait on each one.

---

## Scope

- **Radarr and Sonarr:** supported.
- **Medusa:** not supported. Medusa jobs skip this step with no message.

---

## Undo

Set `enabled = false` under `[kodi]`, then tick Update Library again in Radarr and Sonarr.

See the [`[kodi]` settings](settings-reference.md#kodi) for every key.
