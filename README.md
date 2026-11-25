# MapGit — version control for Trackmania 2020 maps, built into the editor

MapGit lets a group of mappers build **one shared map together** without anyone
needing to know what git is. You edit; MapGit remembers every version, syncs
with your team through GitHub, and — when two people change *the same block* —
shows the conflict **in the 3D world** (real ghost models where possible) and
lets you pick a winner visually.

Everything runs inside Trackmania as an [Openplanet](https://openplanet.dev)
plugin. No external apps, no command line, no git.

## What you get

- **Versions** — every share is a snapshot of the whole map. The panel shows a
  timeline: *who* changed *what*, *when*.
- **Share** — saves your current work and sends it to the shared map. If a
  teammate changed something else meanwhile, both sets of changes combine
  automatically (or you resolve conflicts in the world first).
- **Update** — brings in the changes your teammates shared. The panel tells you
  when there's something new ("Your team shared new changes — Update to see them").
- **Stamps** — name a checkpoint (`before-rework`, `v1-beta`) and go back to it
  any time. Going back never destroys history — your next share becomes a new
  version on top.
- **Visual conflict resolution** — when you and a teammate changed the same
  block or item, MapGit places a **real ghost model** of theirs in the world
  (wireframe fallback if the model isn't in inventory) and outlines yours in
  green. Click *go to it* to fly the camera there, then choose per conflict:
  **Keep mine / Take theirs / Keep both / Remove**. Resolve, **Apply & Share**,
  done.
- **Custom / embedded items** — manifests fingerprint embedded files (TolerantHash);
  merge tries to resolve custom models via inventory / reload. See
  [docs/status.md](docs/status.md) for limits.
- **Real GitHub repositories under the hood** — each map is a genuine git repo
  (`map.Map.Gbx` + `manifest.json` per version), cloneable by power users, but
  mappers never have to touch it.

## Install

1. Install [Openplanet Next](https://openplanet.dev) and [Editor++](https://github.com/XertroV/openplanet-editorplus)
   (MapGit depends on the `Editor` plugin for editor operations and 3D drawing).
2. Copy (or junction) `plugin/tm-mapgit` into `OpenplanetNext/Plugins/`.
3. Start the game and open the map editor. MapGit appears in the menu bar.

## Getting started

1. Open a map in the editor and open the MapGit window.
2. If it says the map isn't being watched yet, click **Start tracking this map**.
3. Click **Connect to GitHub** once (opens a browser, enter the shown code —
   the login is stored on your PC and can be revoked at
   github.com/settings/applications at any time).
4. Edit your map. When you're happy, type a short note and hit **Share**.
5. Teammates do the same on their machines: they **Update** to receive, edit,
   **Share** to publish. When you both touched the same block, the visual
   merge walks you through it.

## Safety

- Your map file on disk is only replaced by verified content: every merged or
  restored version is rebuilt and **hash-checked against the expected result**
  first. If anything doesn't match, MapGit puts your map back exactly as it was.
- The map always keeps working as a normal file — versions are snapshots *of*
  it, stored content-addressed in `Documents\Trackmania\MapGit\<map>\`.
- Medal times: Trackmania clears them by design whenever you edit (unvalidation).
  MapGit records that honestly in every version; it never fakes them back.
- The GitHub token lives in the plugin's own storage folder
  (`OpenplanetNext/PluginStorage/tm-mapgit/auth.json`). Openplanet has no
  secret storage — the file is plaintext, but it is never written to the shared
  settings file and never logged.

## For power users: Developer tools

Enable **Developer tools** in the plugin settings to reveal the full git-facing
UI: version lines (branches), switching (checkout), raw upload/download
(push/pull), manifest dumps, merge from `origin/<branch>`, and the terminology
switch that flips every label between plain language and git terms. The shared
map is the `main` branch of the map's GitHub repository; everything is standard
git underneath.

## The C# engine (this repository's other half)

The `src/` solution is MapGit's **reference implementation and conformance
harness** — the spec the plugin's AngelScript ports are validated against:

- `MapGit.Core` — manifest model, canonical JSON + hashing, keyed diff,
  3-way merge, float-noise-tolerant fingerprints
- `MapGit.Gbx` — .Map.Gbx ↔ manifest extraction (GBX.NET + GBX.NET.LZO),
  fidelity probing, headless merge materializer
- `MapGit.Repo` / `MapGit.Git` — repository model, content-addressed object
  storage, verification invariants
- `MapGit.Cli` — `manifest`, `diff`, `probe`, `crosscheck`, `embedded`,
  `init/status/commit/log/branch/checkout/merge`

```
dotnet build MapGit.slnx          # note: use --no-incremental for full rebuilds
dotnet test  MapGit.slnx          # merge scenarios, repo flows, real maps
```

The plugin's manifest builder is validated against the engine on real maps
(5,603-block conformance: every block, item and metadata field matched).
TM2020 maps use LZO compression, so `GBX.NET.LZO` (GPLv3) is required by the
engine — **the C# solution ships GPLv3**; the Openplanet plugin is a separate
work (MIT) and does not link it.

## Repository layout

```
plugin/tm-mapgit/        the Openplanet plugin (the product)
plugin/tm-mapgit-spikes/ the verification spike plugin (API proofs, kept as reference)
src/                     the C# reference engine + conformance harness + CLI
docs/                    status and known limits
```

## Status

Collaborative Share/Update (including diverge → visual merge), ghost model
previews, skins, embedded fingerprints, and everyday UX are implemented.
See [docs/status.md](docs/status.md) for the detailed shipped / known-limits list.

## Conventions

- Plugin metadata: `author = "its_numpty"`, `category = "Map Editor"`.
- The C# engine remains the spec: AngelScript ports must match its test suite.
