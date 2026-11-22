// tm-mapgit — git-style version control for Trackmania maps (Phase B).
// Architecture: plugin-only runtime; the C# solution is the conformance harness.

[Setting name="Developer terminology (git terms)"]
bool S_DevTerms = false;

bool g_windowVisible = true;

// UI label helper: friendly term by default, git term when developer mode is on.
string T(const string&in friendly, const string&in gitTerm) {
    return S_DevTerms ? gitTerm : friendly;
}

void Main() {
    GH_LoadToken();
    print("MapGit v0.1.0 loaded. Open the MapGit window from the menu bar.");
}

void RenderMenu() {
    if (UI::MenuItem("\\$0f0" + Icons::CodeBranch + "\\$z MapGit", "", g_windowVisible)) {
        g_windowVisible = !g_windowVisible;
    }
}

void Render() {
    MG_DrawConflictMarkersFrame(); // 3D conflict wireframes (draws even with the window closed)
    if (!g_windowVisible) return;
    UI::SetNextWindowSize(600, 520, UI::Cond::FirstUseEver);
    if (S_DevTools) {
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
        if (UI::BeginTabItem(T("Versions", "Repository"))) {
            RenderRepoTab();
            UI::EndTabItem();
        }
        if (UI::BeginTabItem("GitHub")) {
            RenderGitHubTab();
            UI::EndTabItem();
        }
        UI::EndTabBar();
        UI::End();
    } else {
        // everyday UI: one map, one panel, no git concepts
        UI::Begin(Icons::CodeBranch + " MapGit", g_windowVisible);
        RenderMainPanel();
        UI::End();
    }
}

void RenderStatusTab() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor to use MapGit.");
        return;
    }
    MG_AutoLoadRepoState(map); // instant load + automatic dirty check (once per map per session)
    string file = map.MapInfo.FileName;
    UI::Text("Map    : " + map.MapName);
    UI::Text("File   : " + file);
    UI::Text("Blocks : " + map.Blocks.Length + " + " + map.BakedBlocks.Length + " baked");
    UI::Text("Items  : " + map.AnchoredObjects.Length);
    UI::Separator();
    UI::Text(T("Version line", "Branch") + " : " + g_mgRepoBranch +
             "    " + T("latest version", "HEAD") + ": " + (g_mgRepoTip.Length > 0 ? MG_Short(g_mgRepoTip) : "(none)"));
    UI::Text("State  : " + g_mgRepoStatusText);
    if (g_mgRepoBusy) UI::TextDisabled("  (working...)");
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
