// tm-mapgit — git-style version control for Trackmania maps.

[Setting name="Developer terminology (git terms)"]
bool S_DevTerms = false;

bool g_windowVisible = true;

// UI label helper: friendly term by default, git term when developer mode is on.
string T(const string&in friendly, const string&in gitTerm) {
    return S_DevTerms ? gitTerm : friendly;
}

void Main() {
    MG_LoadFonts();
    GH_LoadToken();
    if (!S_OnboardingDone) MG_OnboardingStart();
    print("MapGit v0.2.4 loaded. Open the MapGit window from the menu bar.");
    GH_FetchLoginCoro();
    if (g_ghToken.Length > 0) {
        MG_JoinRefreshListsWork();
        if (g_mgJoinInvites.Length > 0) {
            UI::ShowNotification("MapGit", "You've been invited to " + g_mgJoinInvites.Length
                + (g_mgJoinInvites.Length == 1 ? " map" : " maps") + ". Open MapGit > Join a map.");
        }
    }
}

void RenderMenu() {
    if (UI::BeginMenu("\\$0f0" + Icons::CodeBranch + "\\$z MapGit")) {
        if (UI::MenuItem(Icons::Home + " Show window", "", g_windowVisible)) g_windowVisible = !g_windowVisible;
        if (UI::MenuItem(Icons::QuestionCircle + " Setup & walkthrough")) MG_OnboardingStart();
        if (UI::MenuItem(Icons::Download + " Join a shared map")) {
            g_windowVisible = true;
            g_mgOnbOpen = false;
            S_Page = MG_PAGE_JOIN;
        }
        if (UI::MenuItem(Icons::Github + " GitHub & activity")) {
            g_windowVisible = true;
            g_mgOnbOpen = false;
            S_Page = MG_PAGE_GITHUB;
        }
        if (UI::MenuItem(Icons::Cog + " Settings")) {
            g_windowVisible = true;
            g_mgOnbOpen = false;
            S_Page = MG_PAGE_SETTINGS;
        }
        UI::EndMenu();
    }
}

void Render() {
    MG_DrawConflictMarkersFrame(); // 3D conflict wireframes (draws even with the window closed)
    MG_RemoteCheckTick();         // periodic collaborator-changes check + notification
    if (!g_windowVisible) return;
    MG_RenderMainWindow();
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
    MG_ActivityAdd(msg);
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
