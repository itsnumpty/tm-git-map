// MapGit spikes — Developer Mode only (unsigned). Phase 0 + Phase A.
//
// Phase 0 (verified): live map access, CSV dump, quicksave, crosscheck.
// Phase A (new, depends on Editor++):
//   S5  free blocks with positions/rotations (via Editor::MakeBlockSpec)
//   S6  silent resave (Editor::SaveMapSameName)
//   S7  place + delete block & item (Editor::PlaceBlocks/PlaceItems/DeleteBlocks)
//   S8  3D wireframe marker + camera jump + picked-block highlight
//   S9  open a map by path (ManiaTitleControlScriptAPI.EditMap)
//   S10 embedded items enumeration (Fids)
//   S11 manifest dump v2 (blocks incl. free + items, spec-based)
//   S12 GitHub device flow + API (see GitHubSpike.as)
//
// Install: junction already points at this folder in OpenplanetNext\Plugins.
// REQUIRES: Editor++ installed (F3 > plugin manager > search "Editor++"), then restart.

[Setting name="Show spike window"]
bool S_ShowWindow = true;

string g_lastDumpPath = "";

void Main() {
    print("MapGit spikes v0.2 loaded. Editor++ dependency active. Use the window (menu bar).");
}

CGameCtnEditorCommon@ GetEditor() {
    auto app = GetApp();
    if (app is null || app.Editor is null) return null;
    return cast<CGameCtnEditorCommon>(app.Editor);
}

CGameCtnEditorFree@ GetEditorFree() {
    auto app = GetApp();
    if (app is null || app.Editor is null) return null;
    return cast<CGameCtnEditorFree>(app.Editor);
}

CGameCtnChallenge@ GetMap() {
    auto editor = GetEditor();
    if (editor is null) return null;
    return editor.Challenge;
}

void RenderMenu() {
    if (UI::MenuItem("\\$0f0" + Icons::Wrench + " MapGit Spikes", "", S_ShowWindow)) {
        S_ShowWindow = !S_ShowWindow;
    }
}

void Render() {
    DrawMarkerFrame(); // S8: keep the marker alive while active

    if (!S_ShowWindow) return;

    if (UI::Begin("MapGit Spikes", S_ShowWindow)) {
        UI::BeginTabBar("mapgit-spike-tabs");
        if (UI::BeginTabItem("Phase 0")) {
            RenderPhase0Tab();
            UI::EndTabItem();
        }
        if (UI::BeginTabItem("Phase A")) {
            RenderPhaseATab();
            UI::EndTabItem();
        }
        if (UI::BeginTabItem("Phase A2")) {
            RenderPhaseA2Tab();
            UI::EndTabItem();
        }
        if (UI::BeginTabItem("GitHub")) {
            RenderGitHubTab();
            UI::EndTabItem();
        }
        UI::EndTabBar();
    }
    UI::End();
}

// ------------------------- Phase 0 (verified) -------------------------

void RenderPhase0Tab() {
    auto map = GetMap();

    if (map is null) {
        UI::Text("Open the map editor to run the spikes.");
        return;
    }

    RenderMapInfo(map);
    UI::Separator();
    RenderSpikeButtons(GetEditor(), map);

    if (g_lastDumpPath != "") {
        UI::Separator();
        UI::TextWrapped("Last dump: " + g_lastDumpPath);
        if (UI::Button("Copy crosscheck command")) {
            IO::SetClipboard(
                "dotnet run --project src/MapGit.Cli -- crosscheck \"" +
                map.MapInfo.Path + "\" \"" + g_lastDumpPath + "\"");
        }
    }
}

void RenderMapInfo(CGameCtnChallenge@ map) {
    UI::Text("S1 — live map access");
    UI::Text("  uid     : " + map.MapInfo.MapUid);
    UI::Text("  name    : " + map.MapName);
    UI::Text("  file    : " + map.MapInfo.Path);
    UI::Text("  blocks  : " + map.Blocks.Length + "   items: " + map.AnchoredObjects.Length +
             "   baked: " + map.BakedBlocks.Length);
}

void RenderSpikeButtons(CGameCtnEditorCommon@ editor, CGameCtnChallenge@ map) {
    UI::Text("S2/S4 — enumeration dump (same fields the C# manifest uses)");
    if (UI::Button("Dump blocks & items (CSV)")) {
        DumpCsv(map);
    }

    UI::Text("S3 — quicksave trigger");
    if (UI::Button("Trigger quicksave (ButtonSaveOnClick)")) {
        print("MapGit spike: calling ButtonSaveOnClick()");
        editor.ButtonSaveOnClick();
    }
}

void DumpCsv(CGameCtnChallenge@ map) {
    string path = IO::FromStorageFolder("spike-dump.csv");

    print("MapGit spike: dumping " + map.Blocks.Length + " blocks and " +
          map.AnchoredObjects.Length + " items...");

    IO::File f(path, IO::FileMode::Write);

    // M,uid,blockCount,itemCount,bakedCount,name (name last: commas in it are harmless)
    f.WriteLine("M," + map.MapInfo.MapUid + "," + map.Blocks.Length + "," +
                map.AnchoredObjects.Length + "," + map.BakedBlocks.Length + "," + map.MapName);

    // B,name,x,y,z,dir,ground,ghost,color,lm,variant,hasSkin
    for (uint i = 0; i < map.Blocks.Length; i++) {
        f.WriteLine(BlockLine("B", map.Blocks[i]));
    }

    // B2,... — baked blocks, same format
    for (uint i = 0; i < map.BakedBlocks.Length; i++) {
        f.WriteLine(BlockLine("B2", map.BakedBlocks[i]));
    }

    // I,model,px(mm),py(mm),pz(mm),yaw(hd),pitch(hd),roll(hd),scale(mm),color,lm,hasWaypointProps
    for (uint i = 0; i < map.AnchoredObjects.Length; i++) {
        auto a = map.AnchoredObjects[i];
        f.WriteLine(
            "I," + (a.ItemModel is null ? "?" : a.ItemModel.Id.GetName()) +
            "," + Mm(a.AbsolutePositionInMap.x) + "," + Mm(a.AbsolutePositionInMap.y) + "," + Mm(a.AbsolutePositionInMap.z) +
            "," + Hd(a.Yaw) + "," + Hd(a.Pitch) + "," + Hd(a.Roll) +
            "," + Mm(a.Scale) +
            "," + int(a.MapElemColor) +
            "," + int(a.MapElemLmQuality) +
            "," + (a.WaypointSpecialProperty !is null ? 1 : 0));
    }

    f.Close();
    g_lastDumpPath = path;
    print("MapGit spike: dump written to " + path);
}

string BlockLine(const string&in prefix, CGameCtnBlock@ b) {
    return prefix + "," + b.DescId.GetName() +
        "," + b.Coord.x + "," + b.Coord.y + "," + b.Coord.z +
        "," + int(b.Direction) +
        "," + (b.IsGround ? 1 : 0) +
        "," + (b.IsGhostBlock() ? 1 : 0) +
        "," + int(b.MapElemColor) +
        "," + int(b.MapElemLmQuality) +
        "," + b.BlockInfoVariantIndex +
        "," + (b.Skin !is null ? 1 : 0);
}

// millimeters, rounding away from zero — locale-proof integer formatting
int Mm(float v) {
    return int(Math::Floor(v * 1000.0 + (v >= 0.0 ? 0.5 : -0.5)));
}

// hundredths of a degree
int Hd(float v) {
    return int(Math::Floor(v * 100.0 + (v >= 0.0 ? 0.5 : -0.5)));
}
