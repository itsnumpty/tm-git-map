// UI.as — the MapGit window: an Editor++-style collapsible sidebar on the left, the
// selected page on the right, and a GitHub status footer shown under every page.

[Setting hidden]
bool S_SidebarExpanded = true;

[Setting hidden]
int S_Page = 0;

const int MG_PAGE_HOME = 0;
const int MG_PAGE_HISTORY = 1;
const int MG_PAGE_GITHUB = 2;
const int MG_PAGE_SETTINGS = 3;
const int MG_PAGE_STATUS = 4;   // developer tools only
const int MG_PAGE_MANIFEST = 5; // developer tools only
const int MG_PAGE_ADVANCED = 6; // developer tools only
const int MG_PAGE_JOIN = 7;

bool MG_IsDevPage(int page) {
    return page == MG_PAGE_STATUS || page == MG_PAGE_MANIFEST || page == MG_PAGE_ADVANCED;
}

const int MG_WINDOW_W = 820;
const int MG_WINDOW_H = 600;

bool g_mgResetWindow = false;
bool g_mgWasMerging = false;

void MG_RenderMainWindow() {
    // Jump to Home when a combine starts so the difference wizard is in front of the user.
    if (g_mgMergeActive && !g_mgWasMerging) S_Page = MG_PAGE_HOME;
    g_mgWasMerging = g_mgMergeActive;
    if (!S_DevTools && MG_IsDevPage(S_Page)) S_Page = MG_PAGE_HOME;

    UI::Cond cond = g_mgResetWindow ? UI::Cond::Always : UI::Cond::FirstUseEver;
    g_mgResetWindow = false;
    UI::SetNextWindowSize(MG_WINDOW_W, MG_WINDOW_H, cond);
    UI::SetNextWindowPos((Display::GetWidth() - MG_WINDOW_W) / 2, (Display::GetHeight() - MG_WINDOW_H) / 2, cond);

    vec4 collapsedBg = UI::GetStyleColor(UI::Col::TitleBgCollapsed);
    collapsedBg.w = 0.9;
    UI::PushStyleColor(UI::Col::TitleBgCollapsed, collapsedBg);
    // Openplanet's Begin defaults to NoCollapse; passing explicit flags brings back the
    // title-bar collapse arrow. "###" keeps the window identity stable as the title changes.
    string title = Icons::CodeBranch + " MapGit" + MG_WindowTitleStatus() + "###mapgit-window";
    if (UI::Begin(title, g_windowVisible, UI::WindowFlags::None)) {
        float footerH = UI::GetFrameHeight() + 14.0;
        if (g_mgOnbOpen) {
            if (UI::BeginChild("mapgit-onboarding", vec2(0, -footerH))) RenderOnboarding();
            UI::EndChild();
        } else {
            MG_RenderSidebar(footerH);
            UI::SameLine();
            if (UI::BeginChild("mapgit-page", vec2(0, -footerH))) {
                MG_RenderPage(S_Page);
            }
            UI::EndChild();
        }
        MG_RenderFooter();
    }
    UI::End();
    UI::PopStyleColor();
}

// Short status shown in the title bar, so a collapsed window still tells you what's going on.
string MG_WindowTitleStatus() {
    if (g_mgMergeActive && g_mgConflicts.Length > 0) {
        int left = MG_CountUnresolvedConflicts();
        if (left > 0) return "  \\$f80" + left + (left == 1 ? " difference" : " differences") + " to decide";
        return "  \\$8f0ready to apply";
    }
    if (g_mgRepoBusy || g_ghBusy) return "  \\$aaa(working...)";
    return "";
}

// ------------------------- sidebar -------------------------

void MG_RenderSidebar(float footerH) {
    vec2 framePadding = UI::GetStyleVarVec2(UI::StyleVar::FramePadding);
    float width = (S_SidebarExpanded ? 150.0 : 40.0) * UI::GetScale() + framePadding.x * 2.0;
    if (UI::BeginChild("mapgit-sidebar", vec2(width, -footerH), UI::ChildFlags::Border)) {
        if (UI::Button(Icons::Bars + "##mapgit-sidebar-toggle")) S_SidebarExpanded = !S_SidebarExpanded;
        if (UI::IsItemHovered()) UI::SetTooltip(S_SidebarExpanded ? "Collapse sidebar" : "Expand sidebar");

        string homeBadge = "";
        if (g_mgMergeActive) {
            int left = MG_CountUnresolvedConflicts();
            if (left > 0) homeBadge = " \\$f80(" + left + ")";
        }
        MG_SidebarEntry(MG_PAGE_HOME, Icons::Home, "Home", homeBadge);
        MG_SidebarEntry(MG_PAGE_HISTORY, Icons::History, T("History", "History"), "");
        MG_SidebarEntry(MG_PAGE_JOIN, Icons::Download, "Join a map",
                        g_mgJoinInvites.Length > 0 ? " \\$fd0(" + g_mgJoinInvites.Length + ")" : "");
        MG_SidebarEntry(MG_PAGE_GITHUB, Icons::Github, "GitHub", MG_GhStatusIsError() ? " \\$f84!" : "");
        MG_SidebarEntry(MG_PAGE_SETTINGS, Icons::Cog, "Settings", "");
        if (S_DevTools) {
            UI::Separator();
            if (S_SidebarExpanded) UI::TextDisabled("Developer");
            MG_SidebarEntry(MG_PAGE_STATUS, Icons::InfoCircle, "Status", "");
            MG_SidebarEntry(MG_PAGE_MANIFEST, Icons::ListAlt, "Manifest", "");
            MG_SidebarEntry(MG_PAGE_ADVANCED, Icons::CodeBranch, T("Versions", "Repository"), "");
        }
    }
    UI::EndChild();
}

void MG_SidebarEntry(int page, const string&in icon, const string&in name, const string&in badge) {
    string label = S_SidebarExpanded ? (icon + "  " + name + badge) : (icon + badge);
    if (UI::Selectable(label + "##mapgit-page-" + page, S_Page == page)) S_Page = page;
    if (!S_SidebarExpanded && UI::IsItemHovered()) UI::SetTooltip(name);
}

void MG_RenderPage(int page) {
    if (page == MG_PAGE_HOME) RenderMainPanel();
    else if (page == MG_PAGE_HISTORY) RenderHistoryPage();
    else if (page == MG_PAGE_GITHUB) RenderGitHubPage();
    else if (page == MG_PAGE_JOIN) RenderJoinPage();
    else if (page == MG_PAGE_SETTINGS) RenderSettingsPage();
    else if (page == MG_PAGE_STATUS) RenderStatusTab();
    else if (page == MG_PAGE_MANIFEST) RenderManifestTab();
    else if (page == MG_PAGE_ADVANCED) RenderRepoTab();
}

// ------------------------- footer (GitHub status, under every page) -------------------------

string g_mgRemoteCacheDir = "";
string g_mgRemoteCacheValue = "";
uint64 g_mgRemoteCacheAt = 0;

// "owner/repo" the map in repoDir is shared to, or "" — cached so UI doesn't hit the disk every frame.
string MG_CachedRemote(const string&in repoDir) {
    if (repoDir == g_mgRemoteCacheDir && Time::Now - g_mgRemoteCacheAt < 2000) return g_mgRemoteCacheValue;
    g_mgRemoteCacheDir = repoDir;
    g_mgRemoteCacheAt = Time::Now;
    g_mgRemoteCacheValue = GH_ReadRemote(repoDir) ? (g_ghOwner + "/" + g_ghRepo) : "";
    return g_mgRemoteCacheValue;
}

string MG_FooterRepoLabel() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null || !MG_MapIsSaved(map)) return "";
    string remote = MG_CachedRemote(MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map)));
    return remote.Length > 0 ? remote : "not shared yet";
}

bool MG_GhStatusIsError() {
    string s = g_ghStatus.ToLower();
    return s.Contains("fail") || s.Contains("refused") || s.Contains("expired") || s.Contains("error")
        || s.Contains("missing") || s.Contains("not logged") || s.Contains("don't share") || s.Contains("need ")
        || s.Contains("first");
}

void MG_RenderFooter() {
    UI::Separator();
    UI::AlignTextToFramePadding();
    if (g_ghToken.Length == 0) {
        UI::Text("\\$888" + Icons::Github + " Not connected");
    } else {
        UI::Text("\\$8f0" + Icons::Github + "\\$z " + (g_ghLogin.Length > 0 ? g_ghLogin : "Connected"));
    }

    string repo = MG_FooterRepoLabel();
    if (repo.Length > 0) {
        UI::SameLine();
        UI::Text("\\$555|");
        UI::SameLine();
        UI::Text("\\$bbb" + repo);
    }

    string status = g_ghStatus;
    if (g_ghToken.Length == 0 && status == "not connected") status = "";
    if (status.Length > 0) {
        string col = "\\$bbb";
        if (g_ghBusy) col = "\\$ff0";
        else if (MG_GhStatusIsError()) col = "\\$f84";
        else if (status.StartsWith("pushed") || status.StartsWith("pulled") || status == "up to date") col = "\\$8f0";
        UI::SameLine();
        UI::Text("\\$555|");
        UI::SameLine();
        UI::Text(col + (g_ghBusy ? Icons::Refresh + " " : "") + status);
    }

    UI::SameLine();
    UI::Text("\\$555|");
    UI::SameLine();
    if (UI::Button(Icons::ListAlt + " Activity##footer-activity")) S_Page = MG_PAGE_GITHUB;
    if (UI::IsItemHovered()) UI::SetTooltip("Show the sync activity log");
}

// ------------------------- settings page -------------------------

void RenderSettingsPage() {
    bool changed;

    if (UI::Button(Icons::QuestionCircle + " Run setup & walkthrough again")) MG_OnboardingStart();

    UI::SeparatorText("You");
    UI::SetNextItemWidth(220);
    S_MGAuthor = UI::InputText("Your name##author", S_MGAuthor, changed);
    UI::TextDisabled("Shown next to the versions you save and share.");

    UI::SeparatorText("Collaborator updates");
    UI::SetNextItemWidth(120);
    S_RemoteCheckMinutes = Math::Clamp(UI::InputInt("Check every N minutes##remote-check", S_RemoteCheckMinutes), 0, 120);
    UI::TextDisabled("How often MapGit looks for changes your collaborators shared. 0 turns it off.");

    UI::SeparatorText("New shared repositories");
    UI::SetNextItemWidth(160);
    S_GHRepoPrefix = UI::InputText("Name prefix##repo-prefix", S_GHRepoPrefix, changed);
    CGameCtnChallenge@ map = GetMap();
    if (map !is null && MG_MapIsSaved(map)) {
        UI::TextDisabled("This map would be shared as: " + GH_DefaultRepoName(map));
    } else {
        UI::TextDisabled("Repositories are named <prefix>-<map name>, e.g. tm-map-summer-cup-r3.");
    }

    UI::SeparatorText("Window");
    if (UI::Button("Reset window size and position")) g_mgResetWindow = true;
    UI::SameLine();
    UI::TextDisabled("" + MG_WINDOW_W + " x " + MG_WINDOW_H + ", centred");

    UI::SeparatorText("Advanced");
    S_DevTools = UI::Checkbox("Show developer tools", S_DevTools);
    UI::TextDisabled("Adds version lines (branches), manifests and manual upload/download.");
    S_DevTerms = UI::Checkbox("Use git terms (commit, branch, push...)", S_DevTerms);
    if (S_DevTools) {
        UI::SetNextItemWidth(300);
        S_GHClientId = UI::InputText("GitHub app client id##gh-client", S_GHClientId, changed);
        UI::TextDisabled("Leave empty to use the built-in MapGit app.");
    }

    UI::SeparatorText("Where things are stored");
    UI::TextDisabled("Versions: " + MG_ReposRoot());
    UI::TextDisabled("GitHub login: " + IO::FromStorageFolder("auth.json"));
}

// ------------------------- activity log -------------------------

const uint MG_ACTIVITY_MAX = 500;
array<string> g_mgActivity;
uint g_mgActivityDrawn = 0;
int g_mgActivityStick = 0;
bool g_mgActivitySyncOnly = true;

void MG_ActivityAdd(const string&in msg) {
    g_mgActivity.InsertLast(Time::FormatString("%H:%M:%S") + "  " + msg);
    if (g_mgActivity.Length > MG_ACTIVITY_MAX) g_mgActivity.RemoveRange(0, g_mgActivity.Length - MG_ACTIVITY_MAX);
}

bool MG_ActivityIsSync(const string&in line) {
    return line.Contains("push:") || line.Contains("pull:") || line.Contains("share:") || line.Contains("get:")
        || line.Contains("join:")
        || line.Contains("GitHub") || line.Contains("remote check") || line.Contains("bind")
        || line.Contains("merge:") || line.Contains("auth");
}

string MG_ActivityColor(const string&in line) {
    string l = line.ToLower();
    if (l.Contains("fail") || l.Contains("exception") || l.Contains("refused") || l.Contains("error")) return "\\$f84";
    if (l.Contains("done") || l.Contains("pushed") || l.Contains("pulled") || l.Contains("up to date")) return "\\$8f0";
    if (l.Contains("merge:") || l.Contains("conflict")) return "\\$fd6";
    if (l.Contains("push:") || l.Contains("pull:")) return "\\$8cf";
    return "\\$ccc";
}

void RenderActivityLog() {
    g_mgActivitySyncOnly = UI::Checkbox("Only GitHub sync", g_mgActivitySyncOnly);
    UI::SameLine();
    if (UI::Button(Icons::Clipboard + " Copy")) IO::SetClipboard(MG_ActivityJoined());
    UI::SameLine();
    if (UI::Button(Icons::Trash + " Clear")) {
        g_mgActivity.RemoveRange(0, g_mgActivity.Length);
        g_mgActivityDrawn = 0;
    }

    if (UI::BeginChild("mapgit-activity", vec2(0, 0), UI::ChildFlags::Border)) {
        // Follow new lines only while the user is already looking at the bottom.
        bool atBottom = UI::GetScrollY() >= UI::GetScrollMaxY() - 4.0;
        uint shown = 0;
        for (uint i = 0; i < g_mgActivity.Length; i++) {
            string line = g_mgActivity[i];
            if (g_mgActivitySyncOnly && !MG_ActivityIsSync(line)) continue;
            UI::Text(MG_ActivityColor(line) + line);
            shown++;
        }
        if (shown == 0) {
            UI::TextDisabled(g_mgActivitySyncOnly ? "No sync activity yet. Share or Update to see it here." : "Nothing logged yet.");
        }
        if (g_mgActivity.Length != g_mgActivityDrawn) {
            if (atBottom) g_mgActivityStick = 2; // max scroll lags a frame behind new content
            g_mgActivityDrawn = g_mgActivity.Length;
        }
        if (g_mgActivityStick > 0) {
            UI::SetScrollY(UI::GetScrollMaxY());
            g_mgActivityStick--;
        }
    }
    UI::EndChild();
}

string MG_ActivityJoined() {
    string res = "";
    for (uint i = 0; i < g_mgActivity.Length; i++) {
        if (g_mgActivitySyncOnly && !MG_ActivityIsSync(g_mgActivity[i])) continue;
        res += g_mgActivity[i] + "\n";
    }
    return res;
}
