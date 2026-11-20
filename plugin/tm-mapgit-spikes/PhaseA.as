// MapGit Phase A spikes S5–S8: free blocks, silent save, placement, 3D marker.
// All Editor:: functions/types come from the Editor++ dependency (auto-included exports).

// ------------------------- status log -------------------------

string[] g_paLog;

void PA_Log(const string&in msg) {
    print("MapGit A: " + msg);
    g_paLog.InsertLast(msg);
    if (g_paLog.Length > 200) g_paLog.RemoveRange(0, g_paLog.Length - 200);
}

void RenderPhaseALog() {
    UI::Separator();
    UI::Text("log (newest last):");
    UI::BeginChild("pa-log", vec2(0, 180));
    int start = int(g_paLog.Length) - 12;
    for (int i = Math::Max(0, start); i < int(g_paLog.Length); i++) {
        UI::TextWrapped(g_paLog[i]);
    }
    UI::EndChild();
}

// ------------------------- helpers -------------------------

CGameCtnBlockInfo@ FindTemplateBlockInfo(CGameCtnChallenge@ map) {
    for (uint i = 0; i < map.Blocks.Length; i++) {
        CGameCtnBlock@ b = map.Blocks[i];
        if (b.IsGhostBlock()) continue;
        if (b.BlockInfo !is null) return b.BlockInfo;
    }
    return null;
}

// returns a grid cell not used by any normal block; nat3(0,0,0) if none found
nat3 FindFreeCell(CGameCtnChallenge@ map) {
    dictionary usedDict;
    for (uint i = 0; i < map.Blocks.Length; i++) {
        CGameCtnBlock@ b = map.Blocks[i];
        if (b.IsGhostBlock()) continue;
        usedDict["" + b.Coord.x + "," + b.Coord.y + "," + b.Coord.z] = true;
    }

    for (int z = 2; z < 40; z++) {
        for (int y = 1; y < 8; y++) {
            for (int x = 2; x < 40; x++) {
                if (!usedDict.Exists("" + x + "," + y + "," + z)) {
                    return nat3(x, y, z);
                }
            }
        }
    }
    return nat3(0, 0, 0);
}

CGameCtnBlock@ FindBlockAt(CGameCtnChallenge@ map, const nat3 &in cell) {
    for (uint i = 0; i < map.Blocks.Length; i++) {
        CGameCtnBlock@ b = map.Blocks[i];
        if (b.Coord.x == cell.x && b.Coord.y == cell.y && b.Coord.z == cell.z && !b.IsGhostBlock()) {
            return b;
        }
    }
    return null;
}

// ------------------------- S5: free blocks -------------------------

void S5_DumpFreeBlocks() {
    auto map = GetMap();
    if (map is null) { PA_Log("S5: no map open"); return; }

    string path = IO::FromStorageFolder("free-blocks.csv");
    IO::File f(path, IO::FileMode::Write);
    f.WriteLine("src,name,coordX,coordY,coordZ,posXmm,posYmm,posZmm,pyrYawHd,pyrPitchHd,pyrRollHd,flags,isGround,isGhost,variant,color,lm,hasWaypoint");

    uint n = 0;
    uint shown = 0;

    for (uint pass = 0; pass < 2; pass++) {
        bool baked = pass == 1;
        uint len = baked ? map.BakedBlocks.Length : map.Blocks.Length;
        for (uint i = 0; i < len; i++) {
            CGameCtnBlock@ b = baked ? map.BakedBlocks[i] : map.Blocks[i];
            Editor::BlockSpec@ spec = Editor::MakeBlockSpec(b);
            if (spec is null) continue;
            if (!spec.isFree) continue;

            n++;
            if (shown < 5) {
                shown++;
                PA_Log("S5: '" + spec.name + "' pos=" + spec.pos.ToString() + " pyr=" + spec.pyr.ToString());
            }

            f.WriteLine((baked ? "F2" : "F") + "," + spec.name +
                "," + spec.coord.x + "," + spec.coord.y + "," + spec.coord.z +
                "," + Mm(spec.pos.x) + "," + Mm(spec.pos.y) + "," + Mm(spec.pos.z) +
                "," + Hd(spec.pyr.x) + "," + Hd(spec.pyr.y) + "," + Hd(spec.pyr.z) +
                "," + spec.flags +
                "," + (spec.isGround ? 1 : 0) +
                "," + (spec.isGhost ? 1 : 0) +
                "," + spec.variant +
                "," + int(spec.color) +
                "," + int(spec.lmQual) +
                "," + (spec.waypoint !is null ? 1 : 0));
        }
    }

    f.Close();

    PA_Log("S5: " + n + " free blocks (incl. baked) -> " + path);
    PA_Log("S5: crosscheck against C#: engine sees 1851 free blocks for Ninconpoop (file)");
}

// ------------------------- S6: silent save -------------------------

void S6_SilentSave() {
    startnew(S6_Coro);
}

void S6_Coro() {
    auto ed = GetEditorFree();
    if (ed is null) { PA_Log("S6: no editor"); return; }
    if (ed.PluginMapType is null) { PA_Log("S6: PluginMapType null (map never saved?)"); return; }

    string fileName = ed.PluginMapType.MapFileName;
    PA_Log("S6: MapFileName = '" + fileName + "'");
    int64 mtimeBefore = 0;
    if (fileName != "" && IO::FileExists(IO::FromUserGameFolder("Maps/" + fileName))) {
        mtimeBefore = IO::FileModifiedTime(IO::FromUserGameFolder("Maps/" + fileName));
    }

    bool ok = Editor::SaveMapSameName(ed);
    PA_Log("S6: Editor::SaveMapSameName -> " + (ok ? "true" : "false"));

    sleep(1500); // give the save a moment to flush

    string fileNameAfter = ed.PluginMapType.MapFileName;
    PA_Log("S6: MapFileName after = '" + fileNameAfter + "'");
    int64 mtimeAfter = 0;
    if (fileNameAfter != "" && IO::FileExists(IO::FromUserGameFolder("Maps/" + fileNameAfter))) {
        mtimeAfter = IO::FileModifiedTime(IO::FromUserGameFolder("Maps/" + fileNameAfter));
    }
    PA_Log("S6: mtime " + mtimeBefore + " -> " + mtimeAfter + " " +
           (mtimeAfter > mtimeBefore ? "(FILE WRITTEN ✓)" : "(unchanged — check with 'check' from outside)"));
}

// ------------------------- S7: place & delete -------------------------

void S7_PlaceAndDelete() {
    startnew(S7_Coro);
}

void S7_Coro() {
    auto map = GetMap();
    auto ed = GetEditorFree();
    if (map is null || ed is null) { PA_Log("S7: no map/editor"); return; }

    // ---- block ----
    CGameCtnBlockInfo@ info = FindTemplateBlockInfo(map);
    if (info is null) { PA_Log("S7: no template block found"); return; }
    nat3 cell = FindFreeCell(map);
    if (cell.x == 0) { PA_Log("S7: no free cell found"); return; }
    PA_Log("S7: placing '" + info.IdName + "' at " + cell.x + "," + cell.y + "," + cell.z);

    Editor::BlockSpec@ spec = Editor::MakeBlockSpec(info, cell, 0 /* North */);
    if (spec is null) { PA_Log("S7: MakeBlockSpec returned null"); return; }

    Editor::BlockSpec@[] specs;
    specs.InsertLast(spec);
    uint blocksBefore = map.Blocks.Length;
    bool placed = Editor::PlaceBlocks(specs, true /* undo point */);
    yield(); yield(); yield();
    PA_Log("S7: PlaceBlocks -> " + (placed ? "true" : "false") +
           "  (blocks " + blocksBefore + " -> " + map.Blocks.Length + ")");

    CGameCtnBlock@ placedBlock = FindBlockAt(map, cell);
    PA_Log("S7: found placed block: " + (placedBlock is null ? "NO ✗" : placedBlock.DescId.GetName() + " ✓"));

    if (placedBlock !is null) {
        CGameCtnBlock@[] delArr;
        delArr.InsertLast(placedBlock);
        bool deleted = Editor::DeleteBlocks(delArr, true);
        yield(); yield();
        PA_Log("S7: DeleteBlocks -> " + (deleted ? "true" : "false") +
               "  (blocks " + map.Blocks.Length + ")");
    }

    // ---- item ----
    if (map.AnchoredObjects.Length == 0) {
        PA_Log("S7: no items in map; skipping item part");
        return;
    }

    CGameCtnAnchoredObject@ tmpl = map.AnchoredObjects[0];
    if (tmpl.ItemModel is null) { PA_Log("S7: template item has no model"); return; }

    vec3 newPos = tmpl.AbsolutePositionInMap + vec3(256, 0, 0); // +8 blocks, stays inside map bounds
    PA_Log("S7: item newPos = " + newPos.ToString() + " (map size 48x48 = ~1536 units; out-of-bounds items place silently!)");
    Editor::ItemSpec@ itemSpec = Editor::MakeItemSpec(tmpl.ItemModel, newPos, vec3(tmpl.Yaw, tmpl.Pitch, tmpl.Roll));
    if (itemSpec is null) { PA_Log("S7: MakeItemSpec returned null"); return; }
    itemSpec.scale = tmpl.Scale;

    Editor::ItemSpec@[] itemSpecs;
    itemSpecs.InsertLast(itemSpec);
    uint itemsBefore = map.AnchoredObjects.Length;
    bool itemPlaced = Editor::PlaceItems(itemSpecs, true);
    yield(); yield(); yield();
    PA_Log("S7: PlaceItems -> " + (itemPlaced ? "true" : "false") +
           "  (items " + itemsBefore + " -> " + map.AnchoredObjects.Length + ")");

    CGameCtnAnchoredObject@ placedItem = null;
    for (uint i = 0; i < map.AnchoredObjects.Length; i++) {
        CGameCtnAnchoredObject@ a = map.AnchoredObjects[i];
        if (a.ItemModel is null || a.ItemModel.Id.GetName() != tmpl.ItemModel.Id.GetName()) continue;
        if (Math::Abs(a.AbsolutePositionInMap.x - newPos.x) < 8
            && Math::Abs(a.AbsolutePositionInMap.z - newPos.z) < 8) {
            @placedItem = a;
            break;
        }
    }
    PA_Log("S7: found placed item: " + (placedItem is null ? "NO ✗" : placedItem.ItemModel.Id.GetName() + " ✓"));

    if (placedItem !is null) {
        CGameCtnAnchoredObject@[] delItems;
        delItems.InsertLast(placedItem);
        bool itemDeleted = Editor::DeleteItems(delItems, true);
        yield(); yield();
        PA_Log("S7: DeleteItems -> " + (itemDeleted ? "true" : "false") +
               "  (items " + map.AnchoredObjects.Length + ")");
    }

    PA_Log("S7 done — undo with Ctrl+Z restores everything (two undo points).");
}

// ------------------------- S8: 3D marker + camera -------------------------

bool g_s8Active = false;
vec3 g_s8Pos;

void S8_StartMarkerAtMapCenter() {
    auto ed = GetEditor();
    if (ed is null) { PA_Log("S8: no editor"); return; }
    g_s8Pos = ed.GetMapCenter();
    g_s8Active = true;
    PA_Log("S8: marker ON at map center " + g_s8Pos.ToString() + " (red wireframe box)");
}

void S8_StartMarkerAtFirstBlock() {
    auto map = GetMap();
    if (map is null || map.Blocks.Length == 0) { PA_Log("S8: no blocks"); return; }
    g_s8Pos = Editor::CoordToPos(map.Blocks[0].Coord);
    g_s8Active = true;
    PA_Log("S8: marker ON at first block " + g_s8Pos.ToString());
}

void S8_StopMarker() {
    g_s8Active = false;
    auto di = Editor::DrawLinesAndQuads::GetOrCreateDrawInstance("mapgit-spike-marker");
    if (di !is null) di.Deregister();
    PA_Log("S8: marker OFF");
}

void DrawMarkerFrame() {
    if (!g_s8Active) return;
    auto di = Editor::DrawLinesAndQuads::GetOrCreateDrawInstance("mapgit-spike-marker");
    if (di is null) return;

    di.ResetLines();
    di.RequestLineColor(vec3(1, 0, 0)); // red

    vec3 h = vec3(16, 4, 16); // half extents of one 32x8x32 block cell
    vec3 a = g_s8Pos - h;
    vec3 b = g_s8Pos + h;

    vec3 c000 = vec3(a.x, a.y, a.z);
    vec3 c100 = vec3(b.x, a.y, a.z);
    vec3 c010 = vec3(a.x, b.y, a.z);
    vec3 c110 = vec3(b.x, b.y, a.z);
    vec3 c001 = vec3(a.x, a.y, b.z);
    vec3 c101 = vec3(b.x, a.y, b.z);
    vec3 c011 = vec3(a.x, b.y, b.z);
    vec3 c111 = vec3(b.x, b.y, b.z);

    di.PushLineSegment(c000, c100);
    di.PushLineSegment(c010, c110);
    di.PushLineSegment(c001, c101);
    di.PushLineSegment(c011, c111);
    di.PushLineSegment(c000, c010);
    di.PushLineSegment(c100, c110);
    di.PushLineSegment(c001, c011);
    di.PushLineSegment(c101, c111);
    di.PushLineSegment(c000, c001);
    di.PushLineSegment(c100, c101);
    di.PushLineSegment(c010, c011);
    di.PushLineSegment(c110, c111);

    di.Draw();
}

void S8_JumpCamera() {
    if (!g_s8Active) { PA_Log("S8: start the marker first"); return; }
    vec3 camPos = g_s8Pos + vec3(0, 64, 128);

    // primary: E++ camera animation (DirToLookUvFromCamera = angle from current cam toward target)
    try {
        bool ok = Editor::SetCamAnimationGoTo(Editor::DirToLookUvFromCamera(g_s8Pos), camPos, 192.0);
        PA_Log("S8: SetCamAnimationGoTo(DirToLookUvFromCamera) -> " + (ok ? "true" : "false"));
        return;
    } catch {
        PA_Log("S8: SetCamAnimationGoTo failed: " + getExceptionInfo());
    }

    // E++ camera animation: angle measured from the current camera toward the marker
    try {
        bool ok = Editor::SetCamAnimationGoTo(Editor::DirToLookUvFromCamera(g_s8Pos), camPos, 192.0);
        PA_Log("S8: SetCamAnimationGoTo(DirToLookUvFromCamera) -> " + (ok ? "true" : "false"));
        return;
    } catch {
        PA_Log("S8: SetCamAnimationGoTo failed: " + getExceptionInfo());
    }

    // cam.Location is an iso4 value (no Position member) and SetCamTargetLocation doesn't exist
    // in this E++ build — report the exception above; it names the unbound import.
    PA_Log("S8: camera teleport failed — report the exception line above (says which E++ function is unbound)");
}

void S8_HighlightFirstBlock() {
    auto ed = GetEditorFree();
    auto map = GetMap();
    if (ed is null || map is null || map.Blocks.Length == 0) { PA_Log("S8: no editor/blocks"); return; }
    Editor::SetEditorPickedBlock(ed, map.Blocks[0]);
    PA_Log("S8: SetEditorPickedBlock(first block) — game selection outline should show");
}

// ------------------------- UI -------------------------

void RenderPhaseATab() {
    auto map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor (with Editor++ active) to run Phase A spikes.");
        RenderPhaseALog();
        return;
    }

    UI::Text("S5 — free blocks via E++ specs");
    if (UI::Button("Dump free blocks (CSV)")) S5_DumpFreeBlocks();

    UI::Separator();
    UI::Text("S6 — silent resave (E++ SaveMapSameName)");
    if (UI::Button("Silent save (no dialog)")) S6_SilentSave();

    UI::Separator();
    UI::Text("S7 — place + delete block & item (E++ specs)");
    if (UI::Button("Run place/delete test")) S7_PlaceAndDelete();
    UI::TextWrapped("(uses a free cell + an existing block/item as template; adds undo points)");

    UI::Separator();
    UI::Text("S8 — 3D marker + camera + selection");
    if (UI::Button("Marker @ map center")) S8_StartMarkerAtMapCenter();
    UI::SameLine();
    if (UI::Button("@ first block")) S8_StartMarkerAtFirstBlock();
    UI::SameLine();
    if (UI::Button("Off")) S8_StopMarker();
    if (UI::Button("Camera jump to marker")) S8_JumpCamera();
    UI::SameLine();
    if (UI::Button("Highlight first block")) S8_HighlightFirstBlock();

    RenderPhaseALog();
}
