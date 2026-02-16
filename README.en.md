# EEV — Enshrouded Entity Viewer (PowerShell)

[Deutsch](README.md)

A fast, local viewer for **Enshrouded** worlds.
The project processes already-unpacked game resources (entities + metadata) and generates an interactive, self-contained `viewer/index.html`.

The workflow is intentionally split into two steps:

1. **Chunking** (`chunk-world.ps1`): collects chunks/entities/templates and writes a compact dataset (optionally sharded).
2. **Rendering** (`render-viewer.ps1`): reads the dataset and builds an interactive 2D/3D view with filters, color modes, terrain, coverage overlay, and more.

---

## Requirements

- Windows 10/11
- PowerShell 7+ (tested with 7.5)
- Unpacked Enshrouded resources (see [Preparing game data](#preparing-game-data))
- Enough disk space (from a few hundred MB up to multiple GB, depending on run size)

## Preparing game data

Use Brabb3l’s **KFC parser** to unpack game resources (not included in this repository):

- Repository: <https://github.com/Brabb3l/kfc-parser>
- License: GPLv3

This viewer only consumes generated output files and does not include code from that project.

## Repository layout

- `scripts/chunk-world.ps1` — Parsing/chunking, optional sharding, template lookup, summary output
- `scripts/render-viewer.ps1` — Generates `viewer/index.html` from a JSON file or shard directory
- `viewer/` — Target folder for generated viewer output and run data
- `docs/screenshots/` — Example screenshots

## Screenshots

![EEV 2D](docs/screenshots/eev-2d.png)
![EEV 3D](docs/screenshots/eev-3d.png)

---

## Quick start (iteration)

1. Open PowerShell in the repo.
2. Ensure unpacked game data exists under `unpacked/`.
3. Create a small sharded run:

```powershell
scripts/chunk-world.ps1 -UnpackedRoot unpacked -OutPath viewer\run-quick `
  -Parallel -ThrottleLimit 4 -WriteShards -ShardSize 100000 `
  -MaxChunks 800 -MaxEntitiesPerChunk 3 -OnlyLayer0
```

4. Render the viewer:

```powershell
scripts/render-viewer.ps1 -DataPath viewer\run-quick
```

5. Open `viewer/index.html` in your browser.

**UI tips:**
- Toggle between 2D/3D
- Enable/disable Grid, Terrain, and Coverage
- Use group/subcategory filters
- Switch color mode (subcategory, group, grayscale, monochrome)

## Full run (maximum dataset)

For large datasets, use larger shards and a high `-MaxEntitiesPerChunk` value:

```powershell
scripts/chunk-world.ps1 -UnpackedRoot unpacked -OutPath viewer\run-full `
  -Parallel -ThrottleLimit 6 -WriteShards -ShardSize 200000 `
  -MaxEntitiesPerChunk 1000000

scripts/render-viewer.ps1 -DataPath viewer\run-full
```

---

## Important notes

- Use `-SkipTemplateLookup` **only** for quick test runs. Without template lookup, names, groups, and subcategories are missing in the UI.
- Shards keep memory usage stable and simplify large/resumable runs.
- Large runs create many large JSON files — plan enough free disk space.

---

## Script reference

### `scripts/chunk-world.ps1`

**Parameters**

- `-UnpackedRoot <path>` — Path to unpacked resources (default: `unpacked`)
- `-OutPath <path>` —
  - without `-WriteShards`: output file (JSON)
  - with `-WriteShards`: target directory (or a base path that becomes `<base>-shards`)
- `-MaxEntitiesPerChunk <int>` — Limit per chunk (default: 300)
- `-MaxChunks <int>` — Maximum number of chunk files to process (`0` = all)
- `-OnlyLayer0` — Process layer 0 only
- `-SkipTemplateLookup` — Skip template name resolution (faster, but less UI information)
- `-Parallel` — Enable parallel processing (PowerShell 7)
- `-ThrottleLimit <int>` — Degree of parallelism
- `-WriteShards` — Write shards instead of a single JSON file
- `-ShardSize <int>` — Entities per shard (default: 100,000)

**Behavior**

- Single-file mode writes one JSON to `-OutPath`.
- Shard mode writes `meta.json` + `entities-*.json`.
- If `-OutPath` points to an existing file, a `<basename>-shards` directory is created to avoid collisions.
- Exported `chunks[].path` and `templates[].path` values are masked as `[REDACTED_PATH]`.

### `scripts/render-viewer.ps1`

**Parameters**

- `-DataPath <path>` — Path to a single JSON dataset or a shard directory
- `-OutDir <path>` — Output directory for final `index.html` (default: `viewer`)

---

## Viewer features

- 2D and 3D map view
- Grid and coverage overlay
- Group/subcategory filters including counts
- Color modes: subcategory, group, grayscale, monochrome (with color picker)
- Adjustable point size in 2D and 3D
- Terrain options: percentile (10–90), smoothing (0–4), opacity (0–1), optional height coloring
- Stable alignment between point cloud and terrain via a shared transform

## Performance tips

- Prefer shard mode for large worlds.
- Start with `-ThrottleLimit 4` and increase to 6–8 depending on SSD performance.
- For very large runs, increase `-ShardSize` (e.g., 200,000) to reduce file count.

## Troubleshooting

- **Viewer is empty/white:** rerun rendering and check for the success message.
- **No groups/subcategories:** run chunking without `-SkipTemplateLookup`.
- **Run appears slow/stalled:** lower `-ThrottleLimit` or move data to a faster drive.

## License & legal

- This repository is licensed under **GNU GPL v3** (see `LICENSE`).
- It processes output from **kfc-parser** (Brabb3l, GPLv3), but does not include third-party source code.

## Acknowledgements

Thanks to Brabb3l for the KFC parser and reverse-engineering work that made data unpacking possible.
