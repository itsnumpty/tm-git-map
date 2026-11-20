# Phase 0 report — feasibility proof

Date: 2026-11-19 · Environment: Windows 11, .NET SDK 10.0.201, git 2.50.1, OpenplanetNext installed,
Trackmania user data at `C:\Users\taneo\OneDrive\Documents\Trackmania` (OneDrive-redirected Documents),
game install at `C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games\Trackmania`.

## What was built

| Component | Contents |
|---|---|
| `src/MapGit.Core` | `MapManifest` (mapInfo / blocks / items / embedded), canonical JSON + SHA-256 manifest hash, `ManifestKeys` (grid `b:x,y,z[#gh]`, free `f:mm-pos|hd-rot`, items `i:mm-pos|hd-rot`), `ManifestCanonicalizer` (sort + deterministic duplicate suffixes), `ManifestDiff` (keyed diff), `ThreeWayMerge` (classic 3-way with conflict kinds AddAdd / ModifyModify / ModifyDelete / DeleteModify / Metadata / Embedded) |
| `src/MapGit.Gbx` | `MapFile.ExtractManifest` (GBX.NET), `MapFidelityProbe` (parse → save → reparse comparison) |
| `src/MapGit.Git` | `GitSpike` (LibGit2Sharp: init, commit, branch, checkout, merge) |
| `src/MapGit.Cli` | `manifest`, `diff`, `probe`, `crosscheck`, `git-spike` |
| `src/MapGit.Core.Tests` | 25 tests: 14 merge scenarios, 6 canonicalizer/key tests, 2 real-map tests, 1 git spike, + test data helpers |
| `plugin/tm-mapgit-spikes` | Openplanet spike plugin (S1–S4 below) |

## Findings

### F1 — Manifest extraction works on real maps and is deterministic ✅

Fixtures (copied from the user's real maps, git-ignored):

| Fixture | Size | Blocks | Items | Parse | Manifest hash stable (2 parses) |
|---|---|---|---|---|---|
| `[LC] Windmill Village ft _ Pengi [Part 1]` (collab, custom items, skins) | 2824.6 KB | 21,078 (3,286 ghost, 272 free, 109 skinned) | 1,596 | 417 ms | ✅ |
| `Ninconpoop` (vanilla) | 772.5 KB | 5,603 (37 ghost, 1,851 free, 298 skinned) | 28 | 342 ms | ✅ |
| `AutoSave14` | 167.9 KB | — | — | 335 ms | ✅ |

### F2 — GBX.NET round trip preserves canonical content ✅ (biggest risk retired)

`parse → GBX.NET save → reparse` produces the **identical canonical manifest** on all three
fixtures (blob bytes change, as expected — recompression — but every tracked block, item and
metadata field round-trips). This means the engine can materialize merged maps headlessly
without corrupting tracked content, and the manifest is a reliable diff/merge substrate.

### F3 — TM2020 maps use LZO body compression (licensing answered)

GBX header: `version=6 format=B compressionFlags=0x55` — body is LZO; parsing requires
**GBX.NET.LZO** (native minilzo, **GPLv3**). Consequence: **the engine ships GPLv3**
(engine = MapGit.Core/Gbx/Git/Cli/Tray). The Openplanet plugin talks JSON over localhost and
is a separate work — it can keep any license. (Alternative for later: commercial minilzo
license from Oberon to go MIT.)

### F4 — Merge semantics validated ✅

14 scenario tests pass: independent additions merge as a clean union (the common case that
makes this whole concept work); same-object divergent edits produce typed conflicts
ready for in-editor resolution; map metadata merges field-by-field; embedded zip is atomic
(union when unchanged, conflict when diverged).

### F5 — LibGit2Sharp spike ✅

Init → commit → branch → divergent commits → merge produces a real two-parent merge commit
(`NonFastForward`). Git-host-backed sync is fully viable locally; HTTPS/PAT push is Phase 1.

### F6 — Openplanet API surface confirmed (docs-based; verified in-game, see F8–F10)

- `cast<CGameCtnEditorCommon>(GetApp().Editor)` → `Challenge`, `Cursor`, `ButtonSaveOnClick()`
  (quicksave), `SaveChallengeFromScript_OnSave()`, `ButtonLoadOnClick()`.
- `map.MapInfo` inherits `CGameFid` → **`MapInfo.Path` gives the open map's file path** —
  path discovery solved.
- Blocks: `DescId.GetName()` (name), `Coord.x/y/z` (nat3), `Direction`, `IsGround`,
  `IsGhostBlock()`, `MapElemColor`, `MapElemLmQuality`, `Skin`, `WaypointSpecialProperty`.
- Items: `ItemModel.Id.GetName()`, `AbsolutePositionInMap`, `Yaw/Pitch/Roll`, `Scale`,
  `MapElemColor`, `MapElemLmQuality`.
- Not exposed in-game (but fine engine-side via GBX.NET, and available via Editor++ for
  live apply): block free-position/YawPitchRoll, IsFree/IsPillar flags.
- Coordinate note: GBX.NET normalizes block coords by -(1,0,1) vs raw in-game values —
  `crosscheck` auto-detects the alignment.

### F7 — Openplanet platform capabilities confirmed

Full file IO (`IO::File`, `IO::FromStorageFolder`), HTTP client (`Net::HttpGet/Post`),
non-blocking TCP sockets, JSON, SQLite, hashing — the planned tray-service IPC (localhost)
and watch-folder fallback are both implementable.

## In-game spike verification (2026-11-19, Ninconpoop, dev mode)

### F8 — S1–S3 verified ✅

- Live map access works: uid, name, **file path (`map.MapInfo.Path`)**, counts.
- Block/item enumeration works with engine-compatible names (`DescId.GetName()` /
  `ItemModel.Id.GetName()`) — 2,845 blocks + 28 items dumped, plugin compiled first try.
- `ButtonSaveOnClick()` triggers the save flow — **but for a map not yet saved this
  session it opens the save dialog** ("Save As" semantics, which regenerates the map uid
  and names the map from the dialog). Phase 1 needs a silent resave à la Editor Helpers'
  Quicksave ("no dialogs") — check its source when building the real plugin. Evidence:
  dump at 19:04:14 (memory: uid `xVu6…` / "Ninconpoop") → quicksave → `Ninconpoop TEST.Map.Gbx`
  written 19:04:35 with uid `SCvz…`.

### F9 — Crosscheck: engine ↔ game data agreement ✅ (S4 closed for grid blocks & items)

- **Blocks: 2,813/2,813 in-game grid blocks matched the engine manifest exactly,
  0 dump-only** — identical names, coordinates and ghost flags.
- **Items: 28/28 matched, 0 engine-only, 0 dump-only** (incl. custom
  `zzz_ImportedItems\…Item.Gbx`).
- **Coordinate alignment: offset (0,0) is a perfect match** — in-game coords equal
  GBX.NET's normalized coords exactly. Phase 1 op-apply needs **no coordinate translation**.

### F10 — Block list split fully reconciled ✅

File total **5,603** = in-memory `map.Blocks` **2,845** (2,813 grid + 32 fresh free blocks)
+ in-memory `map.BakedBlocks` **2,758** (939 grid + 1,819 free). Free blocks carry `-1,-1`
grid coords both in memory and in the file (their identity is the free-position key);
blocks placed this session stay in `map.Blocks` and get "baked" on save. The spike dump
now includes `B2` baked lines so crosscheck covers all 5,603.

### F11 — Embedded item content churns on EVERY in-game save ⚠ (Phase 1: semantic fingerprint required)

Three consecutive saves of the same no-edit map produced three different embedded entry
content hashes (`7ba83a…` → `1dda57…` → `ca89c7…`) while **name and size stay identical**
— only the bytes churn (likely a timestamp/counter or lightmap data inside the item GBX).
Consequence: raw embedded hashing would cause an embedded conflict on every merge (both
sides always save before committing). Phase 1 mitigation (mandatory):
1. Fingerprint embedded items **semantically** — parse the embedded GBX (GBX.NET can parse
   `CGameItemModel` from a stream) and hash item identity + mesh/shape data rather than
   serialized bytes.
2. Fallback policy: same-name entry churn = non-blocking (take-ours + note), while
   added/removed entries remain mergeable.

### F12 — Field-level diffing; false-positive found & fixed ✅

`mapgit diff --fields` prints exactly which properties changed per object (and per entry
inside embedded arrays, paired by name). First use caught a real engine bug: two
same-cell duplicate blocks (`DecoCliffVFC` at 31,19,24) appeared to swap direction/variant
across saves — the game reorders same-cell blocks, and the canonicalizer's sort wasn't
total, so deterministic "#2" suffixes flipped. **Fixed** with a full-content tiebreaker +
regression test (`same_cell_duplicates_are_ordered_by_content_not_input_order`). After
the fix, a no-edit save cycle shows **zero block changes** across all 5,603 blocks.

### F13 — Tooling fixes from in-game feedback

- `crosscheck`: coords as `long`, free blocks (`-1`/uint-max) skipped symmetrically,
  `B2` baked lines, baked count from the M-line.
- `diff`: safe summaries for scalar values; `--fields` mode with per-entry recursion.
- Manifest embedded schema: **per-entry content hashes** (whole-zip bytes are unstable).
- Canonical sort made **total** (F12).
- **Uid removed from the canonical manifest** (F14).

### F14 — The editor regenerates the map uid on EVERY save ✅ (handled)

`xVu6…` → `SCvz…` (Save As) → `mvtJ…` (in-place re-save) → `yDst…` (another in-place
re-save). Design consequences, applied:
- uid is **excluded from the canonical manifest** (never diffed/merged/hashed);
- repo↔map binding uses the **file path** (`MapInfo.Path` in-game) and MapGit's own
  stable repo id — never the uid.

### F15 — (superseded by F12) same-cell duplicate reordering

What looked like per-save block volatility was the canonicalizer sort bug described in
F12. No save-volatile block fields exist in the tracked set.

### F16 — Baked blocks & the full in-game ↔ file ledger ✅

Final crosscheck (all lines incl. `B2`): **3,752/3,752 valid-coord file blocks matched
in-game exactly, engine-only 0**; the only dump-only entries are 2,304 `Grass` handles
the editor double-references (same nods in `map.Blocks` AND `map.BakedBlocks`, deduped on
save). Free blocks skip symmetrically (engine 1,851 = dump 1,851). Items 28/28 exact.
Ledger: file 5,603 = blocks chunk 2,845 (↔ `map.Blocks` 1:1) + baked chunk 2,758
(↔ `BakedBlocks` non-grass 1:1); memory baked 5,062 = 2,758 + 2,304 grass dupes.

## Phase 0 verification: COMPLETE

All in-game verification is done (2026-11-19, sessions at 19:01, 19:13 and 19:18).
Save-volatility across a no-edit open→save cycle, final state:

| Data | Save-stable? | Handling |
|---|---|---|
| Blocks (grid, ghost, free), baked blocks | ✅ fully stable | canonical manifest |
| Items incl. custom | ✅ fully stable | canonical manifest |
| Map metadata (name, times, mood, …) | ✅ stable | canonical manifest (uid excluded) |
| Map uid | ❌ regenerated every save | excluded from manifest; repo binds by path + own id |
| Embedded item bytes | ❌ churn every save (name/size stable) | Phase 1 semantic fingerprint + lenient policy |
| Thumbnail, lightmaps | excluded by design | blob-level tracking on commits |

## Go / no-go

**GO for Phase 1 — Phase 0 fully closed.** Every spike passed; all engine risks
retired or mitigated by design. Known Phase 1 work items from the findings:
1. Embedded semantic fingerprints (F11) — required before the first real merge.
2. Silent resave (Editor Helpers' Quicksave pattern) — `ButtonSaveOnClick()` opens the
   save dialog and regenerates uid; check skybaks/EditorHelpers source.
3. Repo↔map binding by file path + stable repo id (never uid).
4. Live apply must target `map.Blocks`/`map.AnchoredObjects` and avoid duplicating
   double-referenced terrain blocks (F16).

Phase 1 build order:
1. Repo model (commit graph, content-addressed snapshots) + `MapGit.Git` real repo commands.
2. Tray service: localhost JSON API + repo folder watching (plugin ↔ engine protocol v1).
3. Plugin `tm-mapgit`: status/commit/pull/push/branch panel (ImGui) + quicksave integration.
4. Live merge apply via Editor++ dependency (`Editor::BlockSpec`/`ItemSpec`) + conflict
   markers + resolution UI → merge commit.
5. GitHub transport (PAT in Windows Credential Manager).
