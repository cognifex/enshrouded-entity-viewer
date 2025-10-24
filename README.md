EEV — Enshrouded Entity Viewer (PowerShell)

Overview

This repository contains a fast, offline entity viewer for Enshrouded worlds. It parses the unpacked game resources (entities and metadata) and renders an interactive 2D/3D visualization in a self‑contained `viewer/index.html`. The workflow is split into two steps for speed and stability:

- Chunking: Collect entities/chunks/templates from the unpacked resources and write a compact JSON dataset. For large runs, data is written in shards (meta.json + `entities-*.json`).
- Rendering: Take a dataset (single JSON or shard directory) and generate `viewer/index.html` with a rich UI (filters, groups/subcategories, color modes, 2D/3D toggle, terrain, coverage overlay, point size, etc.).

Requirements

- Windows 10/11
- PowerShell 7+ (tested with 7.5)
- Unpacked Enshrouded resources (see “Getting the game data”) on a fast drive (SSD strongly recommended)
- Disk space: ranges from a few 100 MB (quick runs) to multiple GB (full runs)

Getting the game data

Use Brabb3l’s KFC parser to unpack the game files (not included here). You need the “unpacked” directory produced by that tool.

- Project: https://github.com/Brabb3l/kfc-parser
- License: GPLv3 (see link above). This viewer only consumes the outputs produced by that tool; it does not embed or ship any of its code.

Folder layout (this repo)

- `scripts/chunk-world.ps1`  — Chunking, sharding, template lookup, summary output
- `scripts/render-viewer.ps1` — Renders `viewer/index.html` from a dataset (file or shard directory)
- `viewer/`                 — Output folder for the generated viewer (index.html, optional lib files, and your shard runs)

Screenshots

Below are sample outputs rendered by EEV. Place your own screenshots in `docs/screenshots/` to publish with your fork/release.

![EEV 2D](docs/screenshots/eev-2d.png)
![EEV 3D](docs/screenshots/eev-3d.png)

Quick start (fast iteration)

1) Open PowerShell in the repo folder and ensure the unpacked data is available as `unpacked/`.

2) Chunk a small subset quickly (parallel, shards, layer 0 only):

```
scripts/chunk-world.ps1 -UnpackedRoot unpacked -OutPath viewer\run-quick ^
  -Parallel -ThrottleLimit 4 -WriteShards -ShardSize 100000 ^
  -MaxChunks 800 -MaxEntitiesPerChunk 3 -OnlyLayer0
```

3) Render the viewer from the shard directory:

```
scripts/render-viewer.ps1 -DataPath viewer\run-quick
```

4) Open `viewer/index.html` in your browser. Toggle 3D, Grid, Terrain, and use the filters on the right. Color modes: subcategory, group, grayscale, monochrome (with color picker).

Full run (all entities)

For the maximum dataset size, use larger shards and a high per‑chunk entity limit. Start with a conservative throttle to avoid IO saturation.

```
scripts/chunk-world.ps1 -UnpackedRoot unpacked -OutPath viewer\run-full ^
  -Parallel -ThrottleLimit 6 -WriteShards -ShardSize 200000 ^
  -MaxEntitiesPerChunk 1000000

scripts/render-viewer.ps1 -DataPath viewer\run-full
```

Notes

- Leave `-SkipTemplateLookup` off if you want proper names → groups/subcategories and color filters depend on it.
- Shards keep memory stable and enable resumable workflows. Large runs can produce multiple large JSON shard files; ensure you have enough disk space.

Script reference

`scripts/chunk-world.ps1`

Parameters:

- `-UnpackedRoot <path>`   Path to the unpacked resources (default: `unpacked`)
- `-OutPath <path>`        For single‑file mode: output JSON. With `-WriteShards`: a directory (or a base path that becomes `<base>-shards`) containing `meta.json` + `entities-*.json`.
- `-MaxEntitiesPerChunk <int>` Limit entities per chunk (default 300 for fast iteration). Set high (e.g. 1000000) for full runs.
- `-MaxChunks <int>`       Limit number of chunk files processed (0 = all)
- `-OnlyLayer0`            Process only layer 0 entities
- `-SkipTemplateLookup`    Skip template name lookup (faster, but UI shows fewer names; groups/subcategories become “unknown”)
- `-Parallel`              Enable parallel parsing (PowerShell 7)
- `-ThrottleLimit <int>`   Max parallel chunk files (recommended 4–6 on SSD)
- `-WriteShards`           Write shards instead of one big JSON
- `-ShardSize <int>`       Entities per shard (default 100000)

Behavior:

- Single‑file mode: writes one JSON at `-OutPath`.
- Shard mode: creates a shard directory with `meta.json` and numbered `entities-*.json`. If `-OutPath` is an existing file, the writer creates `<basename>-shards` alongside it to avoid collisions.
- Progress: writes periodic progress updates and a summary of chunks/entities/shards.

`scripts/render-viewer.ps1`

Parameters:

- `-DataPath <path>` Path to a single dataset JSON or to a shard directory containing `meta.json` + `entities-*.json`.
- `-OutDir <path>`   Output folder for the viewer (default: `viewer`) with final `index.html`.

Features & UI

- 2D & 3D maps with Grid and Coverage overlay
- Filters: groups (collapsible) and subcategories with counts
- Color by: subcategory, group, grayscale, monochrome (+ color picker)
- Point size: fine control in both 2D and 3D
- Terrain: percentile selection (10–90), smoothing (0–4), opacity (0–1), optional height coloring
- Stable alignment: the 3D point cloud and terrain share a common coordinate transform derived from tile layout and world bounds

Performance tips

- Prefer shard mode for big worlds (keeps memory bounded and makes rendering responsive).
- Start with `-ThrottleLimit 4` and increase to 6–8 if your SSD can keep up.
- Large runs can take time; the renderer shows a progress bar while reading shards and composing the final HTML.

Troubleshooting

- Viewer is empty/white: ensure the renderer completed successfully; re-run `scripts/render-viewer.ps1` and watch for “Viewer generated”.
- No groups/subcategories: do not use `-SkipTemplateLookup` during chunking; otherwise most names will be `unknown`.
- Large shard counts: use a larger `-ShardSize` (e.g. 200000) to reduce file count.
- Performance stalls: lower `-ThrottleLimit` or chunk to a different SSD with more free space.

Legal & licensing

- This repository’s code is licensed under the GNU GPL v3 (see `LICENSE`).
- It consumes outputs produced by the third‑party project “kfc-parser” by Brabb3l (GPLv3). We do not distribute or embed their code here. See: https://github.com/Brabb3l/kfc-parser

Acknowledgements

- Thanks to Brabb3l for the KFC parser and reverse engineering work that makes unpacking possible.
