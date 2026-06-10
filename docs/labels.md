# Labels & Content Routing

Stagearr uses the label (category) assigned to a torrent in qBittorrent to decide how to process and where to import it. Every torrent must have a label for Stagearr to route it correctly.

## How labels map to content types

When a torrent completes, qBittorrent calls Stagearr with the torrent's label. Stagearr compares that label against four groups defined in the `[labels]` section of `config.toml`:

| Config key | What matches | Routes to |
|-----------|-------------|-----------|
| `labels.tv` | Primary TV label | TV import pipeline |
| `labels.tvLabels` | Additional TV aliases | TV import pipeline |
| `labels.movie` | Primary movie label | Movie import pipeline |
| `labels.movieLabels` | Additional movie aliases | Movie import pipeline |
| `labels.skip` | Skip label | No processing at all |
| (anything else) | Unrecognized label | Passthrough mode |

Matching is case-insensitive. The `tv` and `movie` values are always checked; `tvLabels` and `movieLabels` extend them with additional aliases.

## Configuring labels

```toml
[labels]
tv = "tv"
movie = "movie"
skip = "skip"
tvLabels    = ["tv", "sonarr", "series"]
movieLabels = ["movie", "radarr", "film"]
```

The defaults shown above are from `config-sample.toml`.

> **Note:** The built-in fallback defaults use capitalized values (`"TV"`, `"Movie"`, `"NoProcess"`) so they do not accidentally match common lowercase qBittorrent labels. Set these to match exactly what your torrent client assigns.

### tv and tvLabels

`tv` is the primary TV label. `tvLabels` is a list of additional labels that are also treated as TV content. You do not need to repeat the `tv` value inside `tvLabels`; the primary label is always matched regardless.

TV content is routed to Medusa or Sonarr depending on `processing.tvImporter`. See [Importing](importing.md) for which importer is selected.

### movie and movieLabels

`movie` is the primary movie label. `movieLabels` extends it with aliases. Movie content is always routed to Radarr.

### skip

Any torrent with the `skip` label is acknowledged by Stagearr but immediately discarded. No files are touched, no staging occurs, and nothing is imported. Use this to prevent Stagearr from processing test downloads or content you want to handle manually.

## Passthrough mode

When the torrent label does not match any configured label (TV, movie, or skip), Stagearr enters passthrough mode:

- Files are extracted from RAR archives (if present) and copied to the staging folder.
- No video remuxing, subtitle processing, or importer call occurs.
- The job still completes and a notification is sent (if email is configured).

This is intentional: it lets you use Stagearr as an extraction helper for one-off downloads that do not belong to any media library.

See [Pipeline Overview](pipeline.md) for how passthrough fits into the full processing flow.

## Setting up qBittorrent labels

qBittorrent lets you assign categories (labels) per torrent or set default categories per download folder. Configure qBittorrent to use the same label values you set in `config.toml`. See [qBittorrent Integration](qbittorrent.md) for the full setup.

## See also

- [Settings Reference: [labels]](settings-reference.md#labels) - all label config keys with defaults
- [Configuration Overview](configuration.md) - how `config.toml` is loaded and merged with defaults
