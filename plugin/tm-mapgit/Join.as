// Join.as — "Join a shared map": a teammate picks a MapGit repository they were invited to
// (or pastes a link), and MapGit downloads its history into a new local repo, writes the
// latest version into My Maps, links it to GitHub, and opens it in the editor.

class MGJoinCandidate {
    string fullName;    // owner/repo
    string mapName;     // best guess at the map's display name
    string inviter;     // set for pending invitations
    int64 inviteId;

    MGJoinCandidate() {
        inviteId = -1;
    }
}

array<MGJoinCandidate@> g_mgJoinInvites;
array<MGJoinCandidate@> g_mgJoinRepos;
bool g_mgJoinListsLoaded = false;
bool g_mgJoinListsLoading = false;
bool g_mgJoinShowAll = false;
array<bool> g_mgJoinRepoIsMapGit;

string g_mgJoinLink = "";
string g_mgJoinSelected = "";   // owner/repo chosen to join
string g_mgJoinSaveAs = "";     // local map name
int64 g_mgJoinSelectedInvite = -1;
string g_mgJoinStatus = "";
bool g_mgJoinBusy = false;

string GH_JStr(Json::Value@ obj, const string&in key) {
    if (obj is null || obj.GetType() != Json::Type::Object || !obj.HasKey(key)) return "";
    Json::Value@ v = obj[key];
    if (v.GetType() != Json::Type::String) return "";
    string s = v;
    return s;
}

// Map name from the repo description MapGit writes ("Trackmania map 'X' (MapGit)" or the
// older "MapGit repository for X"), else from the repo name without the prefix.
string MG_GuessMapName(const string&in repoName, const string&in description) {
    string marker = "Trackmania map '";
    int a = description.IndexOf(marker);
    if (a >= 0) {
        string rest = description.SubStr(a + marker.Length);
        int b = rest.IndexOf("' (MapGit)");
        if (b > 0) return rest.SubStr(0, b);
    }
    string old = "MapGit repository for ";
    if (description.StartsWith(old)) return description.SubStr(old.Length);
    string n = repoName;
    string prefix = GH_SanitizeRepoName(S_GHRepoPrefix, true) + "-";
    if (prefix.Length > 1 && n.StartsWith(prefix)) n = n.SubStr(prefix.Length);
    return n.Replace("-", " ");
}

bool MG_LooksLikeMapGitRepo(const string&in repoName, const string&in description) {
    string prefix = GH_SanitizeRepoName(S_GHRepoPrefix, true) + "-";
    return description.Contains("MapGit") || (prefix.Length > 1 && repoName.StartsWith(prefix));
}

// ------------------------- lists (invites + accessible repos) -------------------------

void MG_JoinRefreshLists() {
    if (g_mgJoinListsLoading || g_ghToken.Length == 0) return;
    startnew(MG_JoinRefreshListsWork);
}

void MG_JoinRefreshListsWork() {
    g_mgJoinListsLoading = true;
    g_mgJoinInvites.RemoveRange(0, g_mgJoinInvites.Length);
    g_mgJoinRepos.RemoveRange(0, g_mgJoinRepos.Length);
    g_mgJoinRepoIsMapGit.RemoveRange(0, g_mgJoinRepoIsMapGit.Length);

    Json::Value@ inv = GH_Api("GET", "https://api.github.com/user/repository_invitations?per_page=100", "");
    if (inv !is null && inv.GetType() == Json::Type::Array) {
        for (uint i = 0; i < inv.Length; i++) {
            Json::Value@ repo = inv[i]["repository"];
            MGJoinCandidate@ c = MGJoinCandidate();
            c.fullName = GH_JStr(repo, "full_name");
            c.mapName = MG_GuessMapName(GH_JStr(repo, "name"), GH_JStr(repo, "description"));
            c.inviter = GH_JStr(inv[i]["inviter"], "login");
            c.inviteId = int64(inv[i]["id"]);
            if (c.fullName.Length > 0) g_mgJoinInvites.InsertLast(c);
        }
    }

    Json::Value@ repos = GH_Api("GET", "https://api.github.com/user/repos?per_page=100&sort=updated"
                                + "&affiliation=owner,collaborator,organization_member", "");
    if (repos !is null && repos.GetType() == Json::Type::Array) {
        for (uint i = 0; i < repos.Length; i++) {
            string name = GH_JStr(repos[i], "name");
            string desc = GH_JStr(repos[i], "description");
            MGJoinCandidate@ c = MGJoinCandidate();
            c.fullName = GH_JStr(repos[i], "full_name");
            c.mapName = MG_GuessMapName(name, desc);
            if (c.fullName.Length == 0) continue;
            g_mgJoinRepos.InsertLast(c);
            g_mgJoinRepoIsMapGit.InsertLast(MG_LooksLikeMapGitRepo(name, desc));
        }
    }
    MG_Log("join: found " + g_mgJoinInvites.Length + " invitation(s) and " + g_mgJoinRepos.Length + " repositories");
    g_mgJoinListsLoaded = true;
    g_mgJoinListsLoading = false;
}

void MG_JoinSelect(MGJoinCandidate@ c) {
    g_mgJoinSelected = c.fullName;
    g_mgJoinSaveAs = c.mapName;
    g_mgJoinSelectedInvite = c.inviteId;
    g_mgJoinStatus = "";
}

// "owner/repo" from a pasted link like https://github.com/owner/repo(.git)(/...)
string MG_ParseRepoLink(const string&in raw) {
    string s = raw.Replace("\\", "/").Replace(" ", "");
    if (s.EndsWith(".git")) s = s.SubStr(0, s.Length - 4);
    int gh = s.IndexOf("github.com/");
    if (gh >= 0) s = s.SubStr(gh + 11);
    string[] parts = s.Split("/");
    if (parts.Length < 2 || parts[0].Length == 0 || parts[1].Length == 0) return "";
    return parts[0] + "/" + parts[1];
}

// ------------------------- the join itself -------------------------

string MG_JoinMapFile() {
    return "My Maps/" + MG_SafeFileName(g_mgJoinSaveAs) + ".Map.Gbx";
}

void MG_JoinCoro() {
    if (g_mgJoinBusy || g_ghBusy) return;
    startnew(MG_JoinWork);
}

void MG_JoinFail(const string&in msg) {
    g_mgJoinStatus = "\\$f84" + msg;
    MG_Log("join: " + msg);
    g_ghStatus = "join failed";
    g_mgJoinBusy = false;
    g_ghBusy = false;
}

void MG_JoinWork() {
    g_mgJoinBusy = true;
    g_ghBusy = true;
    g_ghStatus = "joining...";
    string full = g_mgJoinSelected;
    string[] parts = full.Split("/");
    if (parts.Length != 2) { MG_JoinFail("Pick a shared map first."); return; }

    // 0) accept the invitation if this came from one
    if (g_mgJoinSelectedInvite >= 0) {
        g_mgJoinStatus = "Accepting the invitation...";
        Json::Value@ ok = GH_Api("PATCH", "https://api.github.com/user/repository_invitations/" + g_mgJoinSelectedInvite, "");
        if (ok is null) { MG_JoinFail("Couldn't accept the invitation. Try accepting it on github.com, then join again."); return; }
        MG_Log("join: accepted invitation to " + full);
        g_mgJoinSelectedInvite = -1;
    }

    g_ghOwner = parts[0];
    g_ghRepo = parts[1];

    // 1) can we see it, and does it have MapGit versions?
    g_mgJoinStatus = "Checking " + full + "...";
    Json::Value@ info = GH_Api("GET", GH_ApiUrl(""), "");
    if (info is null) {
        MG_JoinFail(g_ghLastCode == 404 ? "Can't see " + full + ". Ask the owner to invite you, then accept the invite."
                                        : "Couldn't reach GitHub (HTTP " + g_ghLastCode + ").");
        return;
    }
    string branch = "main";
    Json::Value@ branchRef = GH_Api("GET", GH_ApiUrl("/git/refs/heads/" + branch), "");
    if (branchRef is null) {
        string def = GH_JStr(info, "default_branch");
        if (def.Length > 0 && def != branch) {
            branch = def;
            @branchRef = GH_Api("GET", GH_ApiUrl("/git/refs/heads/" + branch), "");
        }
    }
    if (branchRef is null) { MG_JoinFail(full + " has no shared versions yet."); return; }
    string remoteGit = branchRef["object"]["sha"];

    // 2) where it goes on this PC
    string name = MG_SafeFileName(g_mgJoinSaveAs);
    if (name.Length == 0) { MG_JoinFail("Enter a name for the map."); return; }
    string mapFile = MG_JoinMapFile();
    string absPath = IO::FromUserGameFolder("Maps/" + mapFile);
    string repoId = MG_RepoIdFor(mapFile);
    string repoDir = MG_ReposRoot() + "/" + repoId;
    if (IO::FileExists(absPath)) {
        if (GH_ReadRemote(repoDir) && (g_ghOwner + "/" + g_ghRepo) == full) {
            MG_Log("join: " + full + " is already on this PC as " + mapFile + " — opening it");
            g_mgJoinStatus = "\\$8f0You already have this map. Opening it — press Update to get the latest.";
            g_mgJoinBusy = false;
            g_ghBusy = false;
            g_ghStatus = "";
            MG_OpenMapInEditor(mapFile);
            return;
        }
        MG_JoinFail("You already have a map called '" + name + "' in My Maps. Pick another name.");
        return;
    }
    if (IO::FolderExists(repoDir)) {
        MG_JoinFail("MapGit already has history for a map at " + mapFile + ". Pick another name.");
        return;
    }
    g_ghOwner = parts[0];
    g_ghRepo = parts[1];

    // 3) list every MapGit commit on the branch (newest first, paged)
    g_mgJoinStatus = "Reading the map's history...";
    array<string> shas;
    for (int page = 1; page <= 10; page++) {
        Json::Value@ list = GH_Api("GET", GH_ApiUrl("/commits?sha=" + branch + "&per_page=100&page=" + page), "");
        if (list is null) { MG_JoinFail("Couldn't read the history of " + full + "."); return; }
        for (uint i = 0; i < list.Length; i++) {
            string sha = list[i]["sha"];
            shas.InsertLast(sha);
        }
        if (list.Length < 100) break;
    }

    // 4) import oldest-first into a fresh local repo
    MG_EnsureRepo(repoDir, repoId, mapFile, name);
    if (branch != "main") MG_WriteTextFile(repoDir + "/HEAD", "ref: refs/heads/" + branch);
    string prevLocal = "";
    int imported = 0;
    for (int i = int(shas.Length) - 1; i >= 0; i--) {
        g_ghCurImportSha = shas[i];
        Json::Value@ e = GH_Api("GET", GH_ApiUrl("/git/commits/" + g_ghCurImportSha), "");
        if (e is null) { MG_JoinFail("Download interrupted. Try again."); return; }
        string msg = e["message"];
        if (!msg.StartsWith("mapgit:v1")) continue; // repo bootstrap / README commits
        string authorName = GH_JStr(e["author"], "name");
        string isoTime = GH_JStr(e["committer"], "date");
        string newLocal = GH_ImportRemoteCommit(repoDir, msg, authorName, isoTime, prevLocal);
        if (newLocal.Length == 0) { MG_JoinFail("A version failed to download or verify. Try again."); return; }
        prevLocal = newLocal;
        imported++;
        g_mgJoinStatus = "Downloading versions... " + imported;
        yield();
    }
    if (prevLocal.Length == 0) { MG_JoinFail(full + " doesn't contain any MapGit versions."); return; }

    MG_WriteTextFile(repoDir + "/refs/heads/" + branch, prevLocal);
    g_ghOwner = parts[0];
    g_ghRepo = parts[1];
    GH_WriteRemote(repoDir);
    GH_WriteRemoteState(repoDir, branch, prevLocal, remoteGit);

    // 5) write the latest version into My Maps
    string cParents, cManifest, cBlob, cAuthor, cMessage;
    int64 cTime;
    if (!MG_ReadCommit(repoDir, prevLocal, cParents, cManifest, cBlob, cAuthor, cMessage, cTime)) {
        MG_JoinFail("The downloaded history is unreadable.");
        return;
    }
    string myMaps = IO::FromUserGameFolder("Maps/My Maps");
    if (!IO::FolderExists(myMaps)) IO::CreateFolder(myMaps);
    try {
        MG_CopyFile(repoDir + "/objects/blobs/" + cBlob + ".gbx", absPath);
    } catch {
        MG_JoinFail("Couldn't write the map file: " + getExceptionInfo());
        return;
    }
    MG_InstallCustomFilesFor(repoDir, prevLocal); // the editor loads them when the map opens
    MG_Log("join: joined " + full + " (" + imported + " versions) as Maps/" + mapFile);
    g_mgJoinStatus = "\\$8f0Joined! Opening " + name + "...";
    g_ghStatus = "joined " + full;
    g_mgJoinSelected = "";
    g_mgJoinBusy = false;
    g_ghBusy = false;
    MG_OpenMapInEditor(mapFile);
    S_Page = MG_PAGE_HOME;
}

// Leaves whatever is open and opens mapFile (relative to the Maps folder) in the editor.
void MG_OpenMapInEditor(const string&in mapFile) {
    if (!Permissions::OpenAdvancedMapEditor()) {
        g_mgJoinStatus = "\\$f84Your account can't open the advanced editor. The map is in My Maps.";
        return;
    }
    auto app = cast<CGameManiaPlanet>(GetApp());
    app.BackToMainMenu();
    while (!app.ManiaTitleControlScriptAPI.IsReady) yield();
    while (app.Switcher.ModuleStack.Length < 1 || cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) yield();
    yield();
    app.ManiaTitleControlScriptAPI.EditMap(mapFile, "", "");
}

// ------------------------- UI -------------------------

void RenderJoinPage() {
    MG_Heading("Join a shared map");
    UI::TextWrapped("Got invited to work on someone's map? Pick it here and MapGit downloads it into My Maps, "
                    "links it to the shared repository and opens it in the editor.");
    UI::Dummy(vec2(0, 6));

    if (g_ghToken.Length == 0) {
        UI::TextDisabled("First, connect GitHub (use the same account your collaborator invited):");
        RenderGitHubAuthSection();
        return;
    }
    if (!g_mgJoinListsLoaded && !g_mgJoinListsLoading) MG_JoinRefreshLists();

    if (g_mgJoinSelected.Length > 0) {
        RenderJoinConfirm();
        return;
    }

    // invitations
    UI::SeparatorText("Invitations");
    if (g_mgJoinListsLoading) {
        UI::TextDisabled(Icons::Refresh + " Looking for invitations...");
    } else if (g_mgJoinInvites.Length == 0) {
        UI::TextDisabled("No pending invitations.");
    } else {
        for (uint i = 0; i < g_mgJoinInvites.Length; i++) {
            MGJoinCandidate@ c = g_mgJoinInvites[i];
            UI::AlignTextToFramePadding();
            UI::Text("\\$fd0" + Icons::Star + "\\$z " + c.mapName + "  \\$888from " + c.inviter + " (" + c.fullName + ")");
            UI::SameLine();
            if (UI::Button("Accept & join##inv" + i)) MG_JoinSelect(c);
        }
    }

    // repos you can already access
    UI::SeparatorText("Maps you have access to");
    if (g_mgJoinListsLoading) {
        UI::TextDisabled(Icons::Refresh + " Loading...");
    } else {
        uint shown = 0;
        for (uint i = 0; i < g_mgJoinRepos.Length; i++) {
            if (!g_mgJoinShowAll && !g_mgJoinRepoIsMapGit[i]) continue;
            MGJoinCandidate@ c = g_mgJoinRepos[i];
            UI::AlignTextToFramePadding();
            UI::Text(Icons::MapO + " " + c.mapName + "  \\$888" + c.fullName);
            UI::SameLine();
            if (UI::Button("Join##repo" + i)) MG_JoinSelect(c);
            shown++;
        }
        if (shown == 0) UI::TextDisabled("None found. If someone invited you, accept the invite above or check your email.");
        g_mgJoinShowAll = UI::Checkbox("Show all my repositories", g_mgJoinShowAll);
    }
    UI::SameLine();
    UI::BeginDisabled(g_mgJoinListsLoading);
    if (UI::Button(Icons::Refresh + " Refresh")) MG_JoinRefreshLists();
    UI::EndDisabled();

    // paste a link
    UI::SeparatorText("Or paste a link");
    bool changed;
    UI::SetNextItemWidth(340);
    g_mgJoinLink = UI::InputText("##join-link", g_mgJoinLink, changed);
    UI::SameLine();
    string parsed = MG_ParseRepoLink(g_mgJoinLink);
    UI::BeginDisabled(parsed.Length == 0);
    if (UI::Button("Continue")) {
        MGJoinCandidate@ c = MGJoinCandidate();
        c.fullName = parsed;
        string[] p = parsed.Split("/");
        c.mapName = MG_GuessMapName(p[1], "");
        MG_JoinSelect(c);
    }
    UI::EndDisabled();
    UI::TextDisabled("e.g. https://github.com/collaborator/tm-map-summer-cup");
}

void RenderJoinConfirm() {
    UI::SeparatorText("Join " + g_mgJoinSelected);
    bool changed;
    UI::SetNextItemWidth(280);
    g_mgJoinSaveAs = UI::InputText("Save as##join-name", g_mgJoinSaveAs, changed);
    string safe = MG_SafeFileName(g_mgJoinSaveAs);
    if (safe.Length > 0) UI::TextDisabled("Saved to Maps/" + MG_JoinMapFile());
    UI::Dummy(vec2(0, 4));
    if (GetMap() !is null) {
        UI::TextWrapped("\\$fd0" + Icons::ExclamationTriangle + "\\$z This closes the map you have open. Save it first if you've changed anything.");
    }
    UI::BeginDisabled(g_mgJoinBusy || g_ghBusy || safe.Length == 0);
    if (UI::Button(Icons::Download + " Download & open")) MG_JoinCoro();
    UI::EndDisabled();
    UI::SameLine();
    UI::BeginDisabled(g_mgJoinBusy);
    if (UI::Button("Back")) {
        g_mgJoinSelected = "";
        g_mgJoinStatus = "";
    }
    UI::EndDisabled();
    if (g_mgJoinStatus.Length > 0) UI::TextWrapped(g_mgJoinStatus);
}
