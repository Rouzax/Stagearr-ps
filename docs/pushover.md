# Pushover Notifications

Stagearr can send a message to your phone through [Pushover](https://pushover.net/) when a job finishes: what was imported, its state, the poster, and a button to open the title in Radarr or Sonarr. You choose per download label who gets a message, and per person whether they get every message or only the good news. The feature is optional and off by default; email keeps working as before.

---

## Why Use It

Radarr and Sonarr can send Pushover messages too, but each is one line of plain text. Stagearr's message is formatted, carries the poster, and comes after Stagearr has finished, so it can tell you about subtitles, Kodi and anything that went wrong.

It also lets you share notifications in a household: TV and movies to everyone, software downloads to you only, with family members only hearing about things that are ready to watch.

---

## Prerequisites

- **A Pushover account** for each person who should get messages, with the Pushover app on their phone. Each account has a **user key**, shown on the Pushover dashboard after you log in.
- **An application token.** On pushover.net, choose **Create an Application/API Token**, name it Stagearr, and copy the token. One token covers all messages.
- **Optional: OMDb.** The plot, poster and IMDb rating come from [OMDb](settings-reference.md#omdb), the same data the email uses. Without it, messages have no plot, poster or rating.

Pushover's free plan allows 10,000 messages a month per account, far more than Stagearr sends.

---

## Setup

**1. Add the settings** to `config.toml`:

```toml
[notifications.pushover]
enabled = true
appToken = "aXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
recipients = ["me|uXXXXXXXXXXXXXXXXXXXXXXXXXXXXX|all", "partner|uYYYYYYYYYYYYYYYYYYYYYYYYYYYYY|success"]
routes = ["tv,movie|me,partner", "software|me"]
```

Replace the token and keys with your own. In this example:

- TV and movie jobs go to `me` and `partner`.
- Jobs labelled `software` go to `me` only.
- Any other label sends nothing.
- `me` gets every message; `partner` only hears when something new was imported.

**2. Send a test message.** In PowerShell, from the Stagearr folder:

```powershell
Import-Module .\Modules\Stagearr.Core\Stagearr.Core.psd1
$config = Read-SAConfig -Path .\config.toml
Test-SAPushoverConfig -Config $config.notifications.pushover
```

Every recipient gets a message called "Stagearr test", and the command lists each name with `Success` true or the error Pushover gave.

**3. Let a job come through** and check that the message arrives. The job log shows `Pushover: Sent to me, partner`.

**4. Turn off Pushover in Radarr and Sonarr**, under Settings > Connect, so you do not get two messages for each import. Stagearr does not change anything there.

---

## Recipients and Routes

**Recipients** are written once, each as `name|key|filter`:

- `name` is your own short name for the person, used in routes and in the job log.
- `key` is their Pushover user key. A Pushover group key works too.
- `filter` is `all` or `success`.

**Routes** say which labels go to whom, each as `labels|names`, with commas between several labels or names:

- A route label `tv` or `movie` also matches every alias in [`[labels]`](labels.md), such as `sonarr` or `radarr`. Any other route label must match the job's label, in any case.
- When several routes match a label, everyone named in them gets the message, once.
- A route with the label `*` is a catch-all: it is used only for labels that no other route names. Leave it out to send nothing for unlisted labels.

```toml
routes = ["tv,movie|me,partner", "software|me", "*|me"]
```

With this line, a job labelled `games` goes to `me` through the catch-all, and a TV job still goes to `me` and `partner` only.

A malformed entry, an unknown name in a route, or a filter other than `all` or `success` is skipped. The rest still works, and the job log names the problem without showing any key.

---

## What Each Person Gets

| Job outcome | `all` recipient | `success` recipient |
|-------------|-----------------|---------------------|
| Everything imported | ✅ Imported, with details | ✅ Ready to watch, with details |
| Some imported, with a problem (a TBA title waiting for its retry, a file the app skipped, a missing subtitle language) | ⚠️ Partly imported, with the problems | ✅ Ready to watch, listing only what was imported |
| Nothing imported yet, TBA retry scheduled | ⏳ Waiting | Nothing |
| Already in the library at equal or better quality | ℹ️ Already in library, sent silently | Nothing |
| Failed or blocked | ❌ Failed, high priority, with the reason | Nothing |
| Passthrough job (unknown label) done | ✅ Done | ✅ Done |
| Passthrough job failed | ❌ Failed | Nothing |

When a TBA retry later imports the missing episode, that retry is its own job and sends its own message, so a `success` recipient still hears about it.

Episodes that were skipped because the library already had them at equal or better quality do not count as a problem: if the rest imported, the job is "Imported".

---

## What a Message Contains

The title gives the state and the name, for example `✅ Imported · Lanterns S01`. The lock screen shows the title and the first lines as plain text; open the message in the Pushover app to see the formatting.

For TV and movies, in this order, each line only when the data is there:

- The plot, from OMDb.
- **Status:** what was imported, such as `Imported S01E01-E03 to Sonarr`. For more than three episodes it shows the count, as the email does.
- **Quality**, **Subtitles**, and **IMDb** with the rating as a link to the IMDb page and the genres.
- **Kodi**, when the [Kodi step](kodi.md) ran. A `success` recipient only sees it when the title is in the library.
- For an `all` recipient: the warnings and errors from the job, the same ones the email lists.
- The poster as the image, and a **View in Radarr** or **View in Sonarr** button. The button uses the address Stagearr has for Radarr or Sonarr, so it only opens where that address is reachable, typically at home. Medusa imports have no button.

For a passthrough job: the number and size of the files, the folder they are in, and how long the job took.

A message is limited to 1024 characters. When there is more, the plot is left out first, then the last warnings; the email and job log always have the full list.

---

## Turning Messages Off for One Job

The `NoMail` label and the `-SkipEmail` switch (also accepted as `-NoMail`) silence every notification for that job: no email and no Pushover message. See [CLI Usage](cli-usage.md).

---

## Troubleshooting

| What you see | Likely cause | What to do |
|--------------|--------------|------------|
| No message, and no `Pushover` line in the job log | `enabled` is false, the job used `NoMail`, or no route matches the label | Check `enabled` and `routes`. The job log's verbose lines show `Pushover: no route for label '...'`. |
| `Pushover: Not sent: appToken is empty` | The token is missing | Copy the application token from pushover.net into `appToken`. |
| `Pushover: Not sent to all: me: application token is invalid` | Wrong token | Copy it again from your application's page on pushover.net. |
| `... me: user identifier is not a valid user, group, or subscribed user key` | Wrong user key for that person | Copy the key from their Pushover dashboard. The others still get their messages. |
| `... monthly message limit reached` | The Pushover account used its monthly quota | Wait for the next month or upgrade the plan. |
| `... config: recipient 'x' has notify 'sometimes'` | A typo in `recipients` or `routes` | Fix the entry the message names. |
| `... out of time` | Pushover did not answer, and all sends for one job share 30 seconds | Nothing; the next job tries again. Lower `timeoutSeconds` if this happens often. |
| Partner never gets messages | Their filter is `success` and the jobs imported nothing new, or they are not in the route for that label | Check `routes` and the table above. |

A Pushover problem never fails a job and never turns the email amber; it only adds the line in the job log.

See the [`[notifications.pushover]` settings](settings-reference.md#notificationspushover) for every key.
