# Phase 1 progress

Day 1 (2026-11-19 evening) — engine-side Phase 1 is functional end-to-end.
Day 2 (2026-11-20) — **architecture pivot: plugin-only runtime** (user decision). The C#
solution remains as reference implementation + conformance harness + repair CLI; all
user-facing git functionality (commit/branch/merge/push/pull) lives in the Openplanet
plugin. GitHub sync uses the git database REST API (blobs/trees/commits/refs as
base64+JSON) so remote repos are real, cloneable git repositories.

## Phase A closed (2026-11-20) — see docs/phase-a-report.md

All spikes verified in-game (S5 free blocks, S6 silent save, S7 place/delete blocks+items,
S8 3D markers+camera, S9 open-map-by-path, S10 embedded items via
`MemoryTemp/CurrentMap_EmbeddedFiles`, S11 spec extraction with full ledger conformance,
S12 GitHub device flow). Full-map crosscheck: engine vs plugin extraction equivalent
(all 5603 blocks / 28 items matched; only extras = 2304 known grass double-refs).
Key manifest consequence: plugin canonical block set = `map.Blocks` ∪ nod-identity-deduped
`BakedBlocks` = 5603 = the engine's flat file list.

## Phase B round 1 (2026-11-20) — ManifestBuilder v1 conformance

Production plugin `tm-mapgit` v0.1.0 (junctioned, E++ dependency). Round-1 conformance
against the C# engine manifest on Ninconpoop TEST closed every systematic gap:

- **All 5603 block keys and 28 item keys match exactly** (0 engine-only / 0 plugin-only),
  all compared fields match — variant/subVariant included after probe round 1.
- Settled mappings (all verified empirically against the engine):
  - manifest `variant` = in-game **`MobilIndex`** (not `BlockInfoVariantIndex`, which
    reads 0 for baked blocks); `subVariant` = **`MobilVariantIndex`** (probe verdict:
    4957 exact multiset matches, 59 duplicate-collapse artifacts, 0 real mismatches).
  - free-block position = `spec.pos − (0, 56, 0)` — the in-memory field sits 56 units
    (Stadium2020 7-cell base) above the file's `AbsolutePositionInMap`.
  - free-block rotation = `(spec.pyr.y, spec.pyr.x, spec.pyr.z)` — E++ pyr is
    pitch-first; manifest is yaw-first.
  - color/lightmapQuality = enum names (`EMapElemColor`: Default/White/Green/Blue/Red/Black;
    `EMapElemLightmapQuality`: Normal/High/VeryHigh/Highest/Low/VeryLow/Lowest).
  - in-game items expose `Yaw`/`Pitch`/`Roll` floats (no `YawPitchRoll` vec3).
  - `-0` normalized to `0` in key formatting on BOTH sides (C# ManifestKeys + plugin MG_Num)
    — file floats carry -1e-7 noise where memory holds exact 0 (latent false-diff removed).
    37/37 C# tests pass; engine manifest hash updated accordingly.
- Known remaining v1 gaps (excluded from comparison, tracked for v1.1/v2): mapInfo
  `collection` (in-game nod name "Stadium" vs file meta id "Stadium2020" — no in-game
  source found yet), skinFile/skinUrl (needs E++ `GetPackDescs`), item `pivot`,
  `decalId`, `isClip`/`isPillar`, `hasMacroblockRef`, `authorScore`/`playMode`/`cost`/
  `hasGhostBlocks`, embedded entries (Fids byte-read + TolerantHash port), byte-exact
  float formatting for hash equality.

### Round 2 findings (2026-11-20 afternoon)

- **Commit pipeline works end-to-end**: repo store, content-addressed blobs/manifests/
  commits, refs, dirty rules (volatile-only saves skipped), status + history. First
  commits made in `Documents\Trackmania\MapGit\Ninconpoop_TEST-f6dfb57a`.
- `Crypto::Sha256` (native) replaces a hand-rolled port; verified byte-identical to .NET
  (the plugin's file hash equals the C# manifest hash).
- **Times clearing on edit is expected TM2020 behavior** (editing unvalidates the map and
  clears medal times). The manifest honestly records null; the diff layer will show it as
  a normal mapInfo change; never "restore" them. Times/score/type/style can live in the
  header OR ChallengeParameters — both sides (C# MapFile + plugin) now fall back, and
  emit null for unset.
- **Silent saves after edits write the baked form** (852 KB → 175 KB): complete and
  manifest-stable per the engine round-trip. The blob (restore point) churns its hash
  every save (uid + form), the manifest is the stable identity — by design.
- Additional mapInfo fields closed: decoration (DecorationName — matches the engine's
  meta id exactly), titleId, authorLogin, mapType, mapStyle, createdWithSimpleEditor.
- Free-position −56 is NOT `Collection.TerrainHeightOffset` (diag reads 1 for
  Stadium2020); it stays an empirical 7-cell constant for the Stadium2020 collection —
  re-verify for other collections.

### Phase B.3 (2026-11-20) — branches + checkout: verified

- `Create branch` (checkout -b semantics) + branch dropdown (refs/heads via IO::IndexFolder).
- `Checkout` = dirty refusal (live manifest vs current tip) → restore the target branch's
  blob to the map file → HEAD switch → editor reopen via the S9 mechanism → auto status
  refresh. Full demo verified: commit → branch experiment → edit → commit → checkout main
  (editor reloads, experiment blocks gone, clean) → checkout experiment (blocks back,
  clean) → same-branch checkout no-ops.
- **Manifest stability across save→disk→reload proven in-plugin**: after each checkout the
  rebuilt manifest hashes exactly to the committed manifest (c4c5e7da, bf4794f7cd).
- AngelScript notes: `UI::Combo` doesn't exist — use BeginCombo/Selectable/EndCombo
  (E++ pattern); wstring/string ternaries fail ("unambiguous implicit conversion") —
  assign via if/else; `IO::FromUserGameFolder` resolves the game user folder.
- Not yet exercised: the checkout dirty-refusal path (same comparison primitive as the
  verified dirty detection — low risk).

## Done

### 1. Embedded semantic fingerprints (report item F11)

- `TolerantHash` (MapGit.Core): content hash that quantizes runs of plausible floats at
  their own (possibly unaligned) alignment to ~1/1024 relative precision. The game rewrites
  a handful of floats inside embedded items on every save; the fingerprint ignores that
  noise while still separating genuinely different items.
- Manifest embedded schema: entries are `{name, size, fingerprint}` (raw sha removed).
- **Acceptance proven on real data**: `vanilla.Map.Gbx` (Sep 4 save) vs
  `vanilla-resaved.Map.Gbx` (after multiple Nov 19 in-game save cycles) now produce
  **identical manifest hashes** — `mapgit diff` reports 0 changes.
- Unit tests incl. the exact observed churn pattern (unaligned float struct) as a
  regression test.

### 2. Repository model (`MapGit.Repo` + `MapGit.Git` + `MapGit.Gbx`)

Layout per repo (a real git repository underneath):

```
<repo>.mapgit/
  map.meta.json        # repoId (stable identity — never the game uid, see F14)
  work/map.Map.Gbx     # working map (tracked by git; checkout restores branch content)
  objects/
    manifests/<hash>.json
    maps/<hash>.gbx.brotli        # content-addressed, deduplicated snapshots
  .git/                # branches = MapGit branches; commit metadata in message header
```

- `MapRepository`: `Init` / `CommitWorking` (volatile-only saves are skipped — "nothing to
  commit") / `CreateBranch` / `Checkout` (refuses dirty tree, like git) / `Status`
  (manifest-level dirty tracking with +/~/- counts) / `Log` / `Merge`.
- `Merge`: merge-base via git; fast-forward; clean merge → **materialize + verify +
  two-parent merge commit**; conflicts → typed conflict report, working map untouched.
- `MapMaterializer` (headless): applies a merged manifest onto a parsed map — grid/free/
  ghost blocks, items (pos/rot/scale/pivot/color/lm), mapInfo fields, embedded entry
  add/remove from theirs. Strict failure on unsupported placements (skins/waypoint
  props/decals) — loud, never silent loss.
- `GitBackend`: commits with explicit parents, unborn-HEAD handled (first commit lands on
  `main`, not the git default), **git object database as the durable store** — object
  files that branch checkouts remove from the working tree are read back from the
  referencing commit's tree.
- Verification invariant: after every materialized merge, the saved file's manifest must
  hash-match the computed merge result, or the merge aborts with details and the work
  file is restored.

### 3. CLI

`mapgit init | status | commit | log | branch | checkout | merge` (plus the Phase 0 tools:
`manifest`, `diff [--fields]`, `probe`, `crosscheck`, `embedded`, `git-spike`).

### 4. Tests — 37/37

End-to-end repo flows on a real 772 KB / 5,603-block map: init→edit→commit→status;
checkout restores branch content; **branch merge produces a clean union with a
manifest-verified merged file and a two-parent commit**; conflicting merge reports the
AddAdd conflict and preserves the work file; fast-forward takes theirs' content;
materializer round-trips a real free block and a real item to byte-exact manifest equality.

## Engineering notes (LibGit2Sharp lessons)

- On a fresh repo, `Head.FriendlyName` is the git default (`master`): the first MapGit
  commit must explicitly target `main`.
- Switching HEAD onto a new branch on an unborn-HEAD repo needs a **forced** checkout
  (safe: the tip is the commit just created from the current index).
- Object files tracked by git get removed from the working tree by branch checkouts;
  the git odb (via the referencing commit) is the reliable read path.

## Next (post-pivot roadmap)

1. **Phase B (started)**: production plugin `tm-mapgit` — ManifestBuilder v1
   (live map → manifest; structural conformance vs C#, byte-exact later), silent-save
   commit flow, local object store + branches/status/log UI.
2. Phase C: GitHub push/pull via git database REST API + repo-per-map dialog
   (device-flow auth already proven in S12).
3. Phase D: merge engine port (C# 37-test suite as spec) + live apply via E++ specs +
   3D conflict markers/resolution UI.
4. Production OAuth app registration (device flow enabled).
