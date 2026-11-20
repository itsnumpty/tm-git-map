# MapGit — git-style version control for Trackmania 2020 maps

MapGit lets multiple mappers work on the same map **asynchronously**: checkpoint commits,
branch, experiment, and merge — with conflicts (two people touching the same spot)
resolved **inside the map editor**, not in a text diff.

- **`src/MapGit.Core`** — manifest model, canonical JSON + hashing, keyed diff, 3-way merge, float-noise-tolerant fingerprints
- **`src/MapGit.Gbx`** — .Map.Gbx ↔ manifest extraction, round-trip fidelity probing, headless merge materializer (GBX.NET + GBX.NET.LZO)
- **`src/MapGit.Git`** — LibGit2Sharp backend (branches, merge commits, object storage)
- **`src/MapGit.Repo`** — repository model: commits, branches, merge with verification, content-addressed snapshots
- **`src/MapGit.Cli`** — `manifest`, `diff`, `probe`, `crosscheck`, `embedded`, `init`, `status`, `commit`, `log`, `branch`, `checkout`, `merge`
- **`src/MapGit.Tray`** — tray service (next): localhost API for the plugin, map watcher, git sync
- **`plugin/tm-mapgit-spikes`** — Openplanet (AngelScript) Phase 0 spike plugin (verified in-game)
- **`docs/phase-0-report.md`** — Phase 0 findings · **`docs/phase-1-progress.md`** — Phase 1 status

## Status

**Phase 0 complete (verified in-game). Phase 1 engine side functional (37/37 tests).**

- Manifest extraction is deterministic; **GBX.NET parse → save → reparse preserves the
  canonical manifest on all tested real maps** (incl. a 21k-block/1.6k-item collab map).
- **In-game ↔ engine data agreement proven by crosscheck**: every file block/item matches
  the editor's live objects exactly; full baked/free/grass-double-reference ledger
  reconciles.
- Save-volatility mapped and handled: map uid regenerates every save (excluded — repo
  identity is MapGit's own id); embedded item bytes churn every save (semantic
  fingerprints — two real saves of the same map hash identically now); blocks, items and
  metadata are fully save-stable.
- **Full repository flows proven on a real map**: init → edit → commit → branch →
  diverge → merge produces a manifest-verified merged map file with a two-parent commit;
  conflicting merges report typed conflicts and preserve the work file; volatile-only
  saves are skipped as no-ops.
- TM2020 maps use **LZO** body compression → `GBX.NET.LZO` (GPLv3) is required.
  **Licensing consequence: the engine must ship GPLv3** (the Openplanet plugin is a
  separate work communicating over JSON and is not affected).

Next up: tray service + the real `tm-mapgit` Openplanet panel (status/commit/pull/push),
live merge apply with in-editor conflict markers. See `docs/phase-1-progress.md`.

## Conventions

- **Plugin metadata (all Openplanet plugins in this repo, including the eventual `tm-mapgit` release plugin):** `author = "its_numpty"`, `category = "Map Editor"`.
- The C# solution remains the conformance lab: AngelScript ports must match the C# test suite semantics.

## Build & test

```
dotnet build MapGit.slnx
dotnet test MapGit.slnx
```

Tests auto-discover real maps in `fixtures/maps/` (git-ignored local files) and
silently skip if none are present.

## CLI quick start

```
dotnet run --project src/MapGit.Cli -- manifest path\to\map.Map.Gbx
dotnet run --project src/MapGit.Cli -- diff base.Map.Gbx other.Map.Gbx
dotnet run --project src/MapGit.Cli -- probe path\to\map.Map.Gbx
dotnet run --project src/MapGit.Cli -- crosscheck map.Map.Gbx spike-dump.csv
```

`crosscheck` compares an in-game spike dump (see `plugin/tm-mapgit-spikes`) against the
engine's manifest of the saved file — validating that both sides agree on block/item
names, coordinates and ghost flags.

## Architecture (short version)

Commit = full map snapshot (content-addressed) + canonical manifest (deterministic
extraction). Merge = 3-way on manifests (per-position keying). Materialization prefers
**the game's own serializer**: the plugin applies merge operations to the live map and
the user saves; engine-side GBX writing is a headless fallback. Sync = real git
repositories under the hood (GitHub/GitLab), driven by the engine — mappers never touch
git. See the plan discussion and `docs/phase-0-report.md` for details.
