# Phase A Report — Plugin-Only Spike Verification (closed 2026-11-20)

Phase A verified every game-side capability the plugin-only architecture needs, using the
spike plugin `tm-mapgit-spikes` v0.2.1 (depends on Editor++ 0.10.0). All spikes S5–S12 are
verified in-game against `Ninconpoop TEST.Map.Gbx`.

## Spike verdicts

| Spike | Capability | Verdict | Evidence |
|---|---|---|---|
| S5 | Free blocks via E++ specs | ✅ | 1851 free blocks; `Editor::MakeBlockSpec(block)` yields free pos/pyr; count = engine count |
| S6 | Silent save | ✅ | `Editor::SaveMapSameName()` → true; file mtime updated; no dialog |
| S7 | Block & item place/delete | ✅ | `PlaceBlocks` 2845→2846→2845; `PlaceItems` 28→29→28 (found by name) |
| S8 | 3D drawing + camera control | ✅ | marker via `GetOrCreateDrawInstance`/`PushLineSegment`/`Draw()`; camera via `SetCamAnimationGoTo(DirToLookUvFromCamera(...))` → true |
| S9 | Open map by path (branch switching) | ✅ | `BackToMainMenu` + readiness waits + `ManiaTitleControlScriptAPI.EditMap(path,"","")`; editor reloads automatically (~15 s) |
| S10 | Embedded items via Fids | ✅ | found at fake drive `MemoryTemp/CurrentMap_EmbeddedFiles` |
| S11 | Spec-based manifest extraction | ✅ | specFail=0 on all 2845+5062 blocks; ledger matches F16 exactly |
| S12 | GitHub device flow + REST API | ✅ | login `its_numpty` (id 73725656); token stored in hidden setting |

Full-map conformance (Phase-0 CSV dump + `mapgit crosscheck`): uid match; free 1851=1851;
all 3752 engine grid blocks matched with 0 engine-only; all 28 items match field-by-field;
only dump extras are the 2304 known F16 grass double-refs. **The in-game extraction is
formally equivalent to the C# engine on the whole map.**

## Verified APIs (use these)

```
Editor::MakeBlockSpec(block)                  // free pos/pyr, isFree/isGhost/isGround, name, coord, variant
Editor::MakeBlockSpec(info, coord, dir)       // grid placement spec
Editor::MakeItemSpec(model, pos, pyr)         // item placement spec
Editor::PlaceBlocks / PlaceItems / DeleteBlocks / DeleteItems   // all return bool, create undo points
Editor::SaveMapSameName()                     // silent save
Editor::SetCamAnimationGoTo(float lookUv, vec3 pos, float time) // camera jump
Editor::DirToLookUvFromCamera(vec3 target)    // bound variant (returns float)
Editor::GetOrCreateDrawInstance(name) / PushLineSegment / RequestLineColor / Draw()
ManiaTitleControlScriptAPI.EditMap(path, "", "")   // path = map.MapInfo.FileName (FULL path!)
Fids::GetFakeFolder("MemoryTemp/CurrentMap_EmbeddedFiles")   // embedded items tree
Fids::GetFakeFolder("") etc.                  // drive roots; .Trees/.Leaves/.DirName; Fids::UpdateTree(folder)
```

## Hard-won API facts (do not re-guess)

- `Editor::DirToLookUv(vec3)` is **unbound at runtime** ("Unbound function called"); use `DirToLookUvFromCamera`.
- `Editor::SetCamTargetLocation` does not exist; `CHmsCamera` has no `.Pos`; `.Location` is an `iso4` **value** (no `.Position`). Use the E++ camera calls only.
- `map.MapInfo.Path` is the folder only ("My Maps/"); `map.MapInfo.FileName` already contains the full path. (wstring+wstring has no `+` operator — go through `string`.)
- `PlaceItems`/`PlaceBlocks` return **true but silently place nothing when the target is out of
  map bounds** (S7 root cause: +1024 offset on a 48×48 map). The apply engine must validate
  bounds before placing.
- `CSystemFidsFolder` members: `Leaves`/`Trees`/`DirName` (not FidFiles/FidFolders/FolderName).
- In-game `CGameCtnAnchoredObject` has no `PackDesc` (item skins not directly reachable).
- `IO::File` cannot take handles as params (locals only); `sleep()` only in coroutines (`startnew`).
- MwFastBuffer element access: use explicit `@handle = buf[i];`; `buf[i] is null` fails
  ("Both operands must be handles"); `auto a = buf[i]` then assigning `a` to a handle var fails.
- `UI::BeginTabBar` returns void (no `if`); no `string * int` (use `Text::Repeat`).
- `CGameCtnBlock` raw members verified in-game: `DescId.GetName()`, `Coord`, `Direction`,
  `IsGround`, `IsGhostBlock()` (method), `MapElemColor`, `MapElemLmQuality`,
  `BlockInfoVariantIndex`, `Skin`, `AbsolutePositionInMap`, `YawPitchRoll`.

## Dev-loop rules with Editor++ installed

- **Never "Reload All Plugins"** — E++ frees its hook memory on unload and cannot re-init
  in-session (its own notice: restart required). It also breaks dependency load order.
- Single-plugin reload is safe and recompiles only the target (verified repeatedly).
- After a compile failure the plugin logs errors with file/line/col; fix and single-reload.

## Bake ledger (conformance foundation)

For `Ninconpoop TEST` (engine flat file list 5603 = 3752 grid + 1851 free):

- `map.Blocks` 2845 = 994 grid + 1851 free (1:1 with the file's blocks chunk)
- `map.BakedBlocks` 5062 = 2758 baked chunk + 2304 **grass double-refs** (the *same nods*
  appear in both lists)
- Plugin canonical block set = `map.Blocks` ∪ (`BakedBlocks` minus nod-identity dupes) = **5603**
  (dedup by handle identity, not by fields — two legitimately identical blocks are distinct nods)
- GBX.NET `GetBlocks()+GetBakedBlocks()` = 5603 already duplicate-free

## Embedded items location

`MemoryTemp/CurrentMap_EmbeddedFiles` on the fake drive contains `MapContentLoaded.zip`,
`ContentLoaded/` (loaded tree: `Items/zzz_ImportedItems/...`, `ClubItems`, `Stadium`) and
`ContentToSave/` (what the next save writes). Reading entry bytes from Fids for
TolerantHash fingerprinting is an open Phase B item.

## Open items into Phase B

1. ManifestBuilder v1 field gaps: `IsClip`, `IsPillar`, `SubVariant`, item `Pivot`,
   `SkinFile/SkinUrl`, `DecalId`, `MacroblockReference` — in-game members not yet
   confirmed; probe and close.
2. Byte-exact canonical JSON (float shortest-roundtrip formatting differs between
   AngelScript and .NET) — v1 compares structurally; byte-exactness needed for hash equality.
3. Embedded entries: name/size list is reachable; byte read + TolerantHash port pending.
4. Production OAuth app registration (device flow enabled) for the released plugin.
