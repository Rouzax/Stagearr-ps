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
- **The Kodi device you point at has all your sources.** It needs one for each Radarr and Sonarr root folder.
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

If several Kodi devices share one MySQL or MariaDB library, point Stagearr at just one of them. Choose one that stays on, has `cleanonupdate` set, and lists all your sources.

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
```

Stagearr works out the paths by itself in most setups, so you do not need `pathMap` yet. See [When you need pathMap](#when-you-need-pathmap) if a title is skipped.

**2. Test it.** Let one new movie and one new show come through Stagearr. Check that they appear in Kodi, and that the job log shows `Kodi: Scanned and confirmed`.

**3. Change Radarr and Sonarr.** In each app, open Settings > Connect > your Kodi connection, then untick **Update Library** and **Clean Library**. Leave the connection in place if you want its on-screen notifications.

---

## What Happens on Each Import

1. Stagearr finds the folder of each imported title. A pack with several titles gets one scan per title, and a season pack gets one scan of the show.
2. It reads Kodi's video sources and matches the title's folder to one by comparing folder names. `\\server\data\kids\movies` matches `smb://SERVER/Data/Kids/Movies/`, for example. Host names and drive letters do not need to match, and case does not matter.
3. It asks Kodi to list the best-matching source and only continues if the title's folder is there. It never falls back to a weaker match, and it stops if two sources match equally well and both hold the title.
4. It waits for any running scan to finish, then scans the folder, using Kodi's exact spelling.
5. It waits for Kodi to finish and checks the title is in the library.
6. It retries any titles waiting from earlier jobs, if time is left.

Your files are never changed. Kodi adds the new entry, and its own clean removes the old one after an upgrade. An upgraded movie comes back unwatched with no resume point, and an upgraded episode loses its resume point, because Kodi treats the new file as a new item.

Expect this step to take up to about a minute, longer if it is also catching up on missed titles. With `cleanonupdate` on, Kodi checks your whole library for missing files after every scan, and that clean is usually most of the wait. The title appears before the clean starts. That clean can also remove entries for files that went missing elsewhere, as it does after a full scan.

Stagearr scans even if something is playing, because a job cannot wait for a film to finish.

---

## When you need pathMap

Leave `pathMap` empty unless the job's email tells you to set it. You need it when:

- Folder names differ, for example `D:\Films` in Radarr and `smb://NAS/Movies/` in Kodi.
- A source is a multipath source.
- The same title folder is in two sources that match equally well.

`pathMap` cannot get around a missing source. Kodi only lists folders inside a source it shares, so the source must exist on the device Stagearr talks to, and must not be locked. On a shared library each device keeps its own list of sources.

Each entry is `arrPath|kodiPath`, in one string, with each backslash doubled. An entry takes priority over automatic matching:

```toml
pathMap = ["D:\\Films\\|smb://NAS/Movies/"]
```

---

## Missed Scans

If Stagearr cannot finish a scan for a passing reason, it remembers the title in `kodi-pending.json`, in your queue folder. This happens when Kodi is unreachable, stays busy past the time limit, cannot list a folder (for example while a share is down), or a scan cannot be confirmed.

The next job to reach the import step retries those titles after its own, whether or not it imported anything. Passthrough jobs do not count. Retries only use the time left in that job, so a backlog cannot hold up the queue. The job's email says what it caught up on.

There is no timer, so a title waits until such a job runs. A title is dropped if Kodi can list the source and its folder is gone. After 7 days a title gets one last try and is then dropped. The email names anything dropped. A title on the list that is imported again is handled as part of that job.

If the list cannot be read, Stagearr renames it to `kodi-pending.bad.json` and starts a new one, so nothing is overwritten. The email says so.

Stagearr does not retry a title Kodi refused or a path it could not match, because those would fail the same way. Fix the cause, then run a scan in Kodi: open Videos, then choose **Update library** from the side menu.

---

## What Stops Updating Kodi

Once Update Library is off in Radarr and Sonarr, only imports that go through Stagearr reach Kodi. These do not, until you run a scan in Kodi:

- Files imported directly in Radarr or Sonarr
- Renamed files

---

## Results in the Log and Email

| Result | Meaning | What to do |
|--------|---------|------------|
| `Kodi: Scanned and confirmed` | The title is in Kodi. If another title in the job had a problem, the email adds a note. | Nothing, unless the note says otherwise. |
| `Kodi: Caught up on ...` | Titles from the retry list reached Kodi. It can follow the line above or stand alone. | Nothing. |
| `Kodi: Not scanned` | The title did not reach Kodi. The email has a note with the reason, and says if Stagearr will retry. The email stays green. | If it will retry, nothing. Otherwise fix the cause, then run a scan in Kodi. |
| `Kodi: Not everything reached Kodi` | The scan ran and Kodi did not add something. The email turns amber and the warning names it. | See [Troubleshooting](troubleshooting.md#kodi-not-everything-reached-kodi). |

Kodi problems never fail a job. If Kodi is unreachable, Stagearr stops trying until the worker's next run, so a queue of jobs does not wait on each one. Those titles go on the retry list.

---

## Scope

- **Radarr and Sonarr:** supported.
- **Medusa:** not supported. Medusa jobs skip this step with no message.

---

## Undo

Set `enabled = false` under `[kodi]`, then tick Update Library again in Radarr and Sonarr. Any `kodi-pending.json` left in your queue folder is then ignored, and you can delete it.

See the [`[kodi]` settings](settings-reference.md#kodi) for every key.
