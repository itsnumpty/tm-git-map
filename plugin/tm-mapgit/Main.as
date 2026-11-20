// tm-mapgit — git-style version control for Trackmania maps (Phase B).
// Architecture: plugin-only runtime; the C# solution is the conformance harness.

bool g_windowVisible = true;

void Main() {
    print("MapGit v0.1.0 loaded (Phase B: ManifestBuilder v1). Open the MapGit window from the menu bar.");
}

void RenderMenu() {
    if (UI::MenuItem("\\$0f0" + Icons::CodeBranch + "\\$z MapGit", "", g_windowVisible)) {
        g_windowVisible = !g_windowVisible;
    }
}

void Render() {
    if (!g_windowVisible) return;
    UI::SetNextWindowSize(600, 520, UI::Cond::FirstUseEver);
    UI::Begin(Icons::CodeBranch + " MapGit", g_windowVisible);
    UI::BeginTabBar("mapgit-tabs");
    if (UI::BeginTabItem("Status")) {
        RenderStatusTab();
        UI::EndTabItem();
    }
    if (UI::BeginTabItem("Manifest")) {
        RenderManifestTab();
        UI::EndTabItem();
    }
    if (UI::BeginTabItem("Repository")) {
        RenderRepoTab();
        UI::EndTabItem();
    }
    UI::EndTabBar();
    UI::End();
}

void RenderStatusTab() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor to use MapGit.");
        return;
    }
    string file = map.MapInfo.FileName;
    UI::Text("Map    : " + map.MapName);
    UI::Text("File   : " + file);
    UI::Text("Blocks : " + map.Blocks.Length + " + " + map.BakedBlocks.Length + " baked");
    UI::Text("Items  : " + map.AnchoredObjects.Length);
    UI::Separator();
    UI::TextDisabled("Repository: not initialized yet (coming in Phase B)");
}

// ------------------------- helpers -------------------------

void MG_Log(const string&in msg) {
    print("MapGit: " + msg);
}

CGameCtnEditorFree@ GetEditorFree() {
    return cast<CGameCtnEditorFree>(GetApp().Editor);
}

CGameCtnChallenge@ GetMap() {
    CGameCtnEditorFree@ editor = GetEditorFree();
    if (editor is null) return null;
    auto pmt = editor.PluginMapType;
    if (pmt is null) return null;
    return pmt.Map;
}
