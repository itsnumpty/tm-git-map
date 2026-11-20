// MapGit Phase A spikes S9–S11: open map by path, embedded items (Fids), manifest dump v2.

// ------------------------- S9: open map by path -------------------------

string g_s9Path;
bool g_s9UseFileScheme = false;
bool g_s9Busy = false;

void S9_OpenMap() {
    if (g_s9Path.Length == 0) { PA_Log("S9: enter a path first"); return; }
    startnew(S9_Coro);
}

void S9_Coro() {
    g_s9Busy = true;
    string target = g_s9Path.Replace("\\", "/");
    if (g_s9UseFileScheme && !target.StartsWith("file://")) {
        target = "file:///" + target;
    }
    PA_Log("S9: opening: " + target);

    if (!Permissions::OpenAdvancedMapEditor()) {
        PA_Log("S9: no permission to open the advanced editor (Club required)");
        g_s9Busy = false;
        return;
    }

    auto app = cast<CGameManiaPlanet>(GetApp());
    app.BackToMainMenu();
    while (!app.ManiaTitleControlScriptAPI.IsReady) yield();
    while (app.Switcher.ModuleStack.Length < 1 || cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) yield();
    yield();
    app.ManiaTitleControlScriptAPI.EditMap(target, "", "");
    PA_Log("S9: EditMap called — watch what happens (save prompt may appear if the map is dirty)");
    g_s9Busy = false;
}

// ------------------------- S10: embedded items via Fids -------------------------

void S10_ScanEmbedded() {
    auto map = GetMap();
    if (map is null) { PA_Log("S10: no map open"); return; }

    // 1) try the documented name on each drive
    string[] drives = { "fake", "user", "game", "programdata", "resource" };
    CSystemFidsFolder@ folder = null;
    string foundDrive = "";
    for (uint d = 0; d < drives.Length; d++) {
        CSystemFidsFolder@ candidate = S10_TryGetFolder(drives[d], "CurrentMap_EmbeddedFiles");
        if (candidate !is null) {
            @folder = candidate;
            foundDrive = drives[d];
            break;
        }
    }

    if (folder !is null) {
        PA_Log("S10: found on drive '" + foundDrive + "' — enumerating...");
        try {
            S10_EnumFolder(folder, 0);
        } catch {
            PA_Log("S10: exception: " + getExceptionInfo());
        }
        return;
    }

    // 2) try inside MemoryTemp (wiki: System/Folders/MemoryTemp — fake drive)
    CSystemFidsFolder@ viaMemTemp = Fids::GetFakeFolder("MemoryTemp/CurrentMap_EmbeddedFiles");
    if (viaMemTemp !is null) {
        PA_Log("S10: found via MemoryTemp/CurrentMap_EmbeddedFiles — enumerating...");
        try {
            S10_EnumFolder(viaMemTemp, 0);
        } catch {
            PA_Log("S10: exception: " + getExceptionInfo());
        }
        return;
    }

    // 3) enumerate MemoryTemp itself — the embedded folder should be one of its children
    CSystemFidsFolder@ memTemp = Fids::GetFakeFolder("MemoryTemp");
    if (memTemp !is null) {
        try { Fids::UpdateTree(memTemp); } catch { /* rescan may fail on some folders */ }
        PA_Log("S10: MemoryTemp contents:");
        try {
            S10_EnumFolder(memTemp, 0);
        } catch {
            PA_Log("S10: MemoryTemp enumeration failed: " + getExceptionInfo());
        }
        return;
    }

    // 4) discovery mode: list the root folders of every drive to find the real name
    PA_Log("S10: 'CurrentMap_EmbeddedFiles' not found — discovering drive roots...");
    for (uint d = 0; d < drives.Length; d++) {
        CSystemFidsFolder@ root = S10_TryGetFolder(drives[d], "");
        if (root is null) { PA_Log("S10: drive '" + drives[d] + "': no root folder"); continue; }
        try { Fids::UpdateTree(root); } catch { /* some drives may not support rescans */ }
        try {
            auto trees = root.Trees;
            PA_Log("S10: drive '" + drives[d] + "' root: " + trees.Length + " folders, "
                   + root.Leaves.Length + " files");
            for (uint i = 0; i < trees.Length && i < 40; i++) {
                PA_Log("S10:   " + trees[i].DirName);
            }
        } catch {
            PA_Log("S10: drive '" + drives[d] + "' enumeration failed: " + getExceptionInfo());
        }
    }
}

CSystemFidsFolder@ S10_TryGetFolder(const string&in drive, const string&in path) {
    if (drive == "fake") return Fids::GetFakeFolder(path);
    if (drive == "user") return Fids::GetUserFolder(path);
    if (drive == "game") return Fids::GetGameFolder(path);
    if (drive == "programdata") return Fids::GetProgramDataFolder(path);
    if (drive == "resource") return Fids::GetResourceFolder(path);
    return null;
}

void S10_EnumFolder(CSystemFidsFolder@ folder, int depth) {
    if (folder is null || depth > 3) return;

    auto files = folder.Leaves;
    for (uint i = 0; i < files.Length; i++) {
        PA_Log("S10: " + Text::Repeat("  ", depth) + "file: " + files[i].FileName);
    }

    auto folders = folder.Trees;
    for (uint i = 0; i < folders.Length; i++) {
        PA_Log("S10: " + Text::Repeat("  ", depth) + "dir : " + folders[i].DirName);
        S10_EnumFolder(folders[i], depth + 1);
    }
}

// ------------------------- S11: manifest dump v2 (spec-based) -------------------------

void S11_DumpManifestV2() {
    auto map = GetMap();
    if (map is null) { PA_Log("S11: no map open"); return; }

    string path = IO::FromStorageFolder("manifest-a.csv");
    IO::File f(path, IO::FileMode::Write);

    f.WriteLine("MB,src,name,coordX,coordY,coordZ,posXmm,posYmm,posZmm,pyrYawHd,pyrPitchHd,pyrRollHd,isFree,isGround,isGhost,variant,color,lm,hasWaypoint,hasSkin,dir");
    f.WriteLine("MI,model,px,py,pz,yaw,pitch,roll,scale,color,lm,hasWaypoint");

    uint gridBlocks = 0, freeBlocks = 0, ghostBlocks = 0, bakedCount = 0, specFail = 0, memGrid = 0;

    for (uint pass = 0; pass < 2; pass++) {
        bool baked = pass == 1;
        uint len = baked ? map.BakedBlocks.Length : map.Blocks.Length;
        for (uint i = 0; i < len; i++) {
            CGameCtnBlock@ b = baked ? map.BakedBlocks[i] : map.Blocks[i];
            Editor::BlockSpec@ spec = Editor::MakeBlockSpec(b);
            if (spec is null) {
                specFail++;
                continue;
            }

            if (spec.isFree) freeBlocks++;
            else { gridBlocks++; if (!baked) memGrid++; }
            if (spec.isGhost) ghostBlocks++;
            if (baked) bakedCount++;

            f.WriteLine("MB," + (baked ? "bk" : "b") + "," + spec.name +
                "," + spec.coord.x + "," + spec.coord.y + "," + spec.coord.z +
                "," + Mm(spec.pos.x) + "," + Mm(spec.pos.y) + "," + Mm(spec.pos.z) +
                "," + Hd(spec.pyr.x) + "," + Hd(spec.pyr.y) + "," + Hd(spec.pyr.z) +
                "," + (spec.isFree ? 1 : 0) +
                "," + (spec.isGround ? 1 : 0) +
                "," + (spec.isGhost ? 1 : 0) +
                "," + spec.variant +
                "," + int(spec.color) +
                "," + int(spec.lmQual) +
                "," + (spec.waypoint !is null ? 1 : 0) +
                "," + (b.Skin !is null ? 1 : 0) +
                "," + int(b.Direction));
        }
    }

    for (uint i = 0; i < map.AnchoredObjects.Length; i++) {
        auto a = map.AnchoredObjects[i];
        f.WriteLine("MI," + (a.ItemModel is null ? "?" : a.ItemModel.Id.GetName()) +
            "," + Mm(a.AbsolutePositionInMap.x) + "," + Mm(a.AbsolutePositionInMap.y) + "," + Mm(a.AbsolutePositionInMap.z) +
            "," + Hd(a.Yaw) + "," + Hd(a.Pitch) + "," + Hd(a.Roll) +
            "," + Mm(a.Scale) +
            "," + int(a.MapElemColor) +
            "," + int(a.MapElemLmQuality) +
            "," + (a.WaypointSpecialProperty !is null ? 1 : 0));
    }

    f.Close();

    PA_Log("S11: map.Blocks " + (memGrid + freeBlocks) + " = grid " + memGrid + " + free " + freeBlocks +
           " | BakedBlocks " + bakedCount + " | ghost " + ghostBlocks +
           " | items " + map.AnchoredObjects.Length + " | specFail " + specFail);
    PA_Log("S11: F16 ledger (Ninconpoop TEST): map.Blocks 2845 = 994 grid + 1851 free; BakedBlocks 5062 = 2758 baked + 2304 grass dupes; ghost 37; items 28; engine flat file list 5603 = 3752 grid + 1851 free");
    PA_Log("S11: written -> " + path);
}

// ------------------------- UI -------------------------

void RenderPhaseA2Tab() {
    auto map = GetMap();

    UI::Text("S9 — open map by path (branch switching)");
    if (map !is null && g_s9Path.Length == 0) {
        // FileName already contains the full path ("My Maps/Ninconpoop TEST.Map.Gbx")
        g_s9Path = map.MapInfo.FileName;
    }
    bool changed;
    UI::SetNextItemWidth(520);
    g_s9Path = UI::InputText("##s9-path", g_s9Path, changed);
    UI::SameLine();
    g_s9UseFileScheme = UI::Checkbox("file://", g_s9UseFileScheme);
    UI::BeginDisabled(g_s9Busy);
    if (UI::Button("Open this map in editor")) S9_OpenMap();
    UI::EndDisabled();
    UI::TextWrapped("(prefilled with the current map's path — reopening the current map is a safe test; unsaved-changes prompts may appear)");

    UI::Separator();
    UI::Text("S10 — embedded items via Fids");
    if (UI::Button("Scan embedded items")) S10_ScanEmbedded();

    UI::Separator();
    UI::Text("S11 — manifest dump v2 (spec-based, incl. free blocks)");
    if (UI::Button("Dump manifest v2 (CSV)")) S11_DumpManifestV2();

    RenderPhaseALog();
}
