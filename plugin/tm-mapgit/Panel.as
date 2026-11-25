// Panel.as — the everyday MapGit panel (normal mode): one shared map, a status
// sentence, Share/Get, a people timeline, and named version stamps.
// Power tools (branches, manifests, raw push/pull) live behind developer mode.
//
// Semantics:
//   Share my changes = save unsaved work as a version + upload to the shared map
//   Get changes      = download the shared map's latest
//   Stamp            = name the current state; restore it any time
//   Restore          = make your working map match a version (history is kept —
//                      your next save becomes a new version on top)

[Setting name="Developer tools (branches, manifests, raw upload/download)"]
bool S_DevTools = false;

array<string> g_mgPanelLogLines;   // timeline cache: "author|message|time|sha"
bool g_mgTimelineLoaded = false;

class MGStamp {
    string name;
    string commit;
    string author;
    int64 time;
}

array<MGStamp@> g_mgStamps;
string g_mgStampName = "";

// ------------------------- helpers -------------------------

string MG_TimeAgo(int64 stamp) {
    int64 delta = Time::Stamp - stamp;
    if (delta < 60) return "just now";
    if (delta < 3600) return "" + (delta / 60) + " min ago";
    if (delta < 86400) return "" + (delta / 3600) + " h ago";
    return "" + (delta / 86400) + " d ago";
}

// ------------------------- timeline -------------------------

void MG_LoadTimeline(const string&in repoDir, const string&in tip) {
    g_mgPanelLogLines.RemoveRange(0, g_mgPanelLogLines.Length);
    string cur = tip;
    for (uint i = 0; i < 12 && cur.Length > 0; i++) {
        string parents, manifest, blob, author, message;
        int64 time;
        if (!MG_ReadCommit(repoDir, cur, parents, manifest, blob, author, message, time)) break;
        g_mgPanelLogLines.InsertLast(author + "|" + message + "|" + time + "|" + cur);
        string[] p = parents.Split(",");
        cur = (p.Length > 0 && p[0].Length > 0) ? p[0] : "";
    }
    g_mgTimelineLoaded = true;
}

// ------------------------- stamps -------------------------

string MG_StampsDir(const string&in repoDir) {
    return repoDir + "/stamps";
}

string MG_SanitizeStampName(const string&in nameIn) {
    return nameIn.Replace(" ", "-").Replace(".", "-").Replace("/", "-").Replace("\\", "-")
                 .Replace(":", "-").Replace("*", "-").Replace("?", "-").Replace("\"", "-")
                 .Replace("<", "-").Replace(">", "-").Replace("|", "-").Replace("#", "-");
}

void MG_LoadStamps(const string&in repoDir) {
    g_mgStamps.RemoveRange(0, g_mgStamps.Length);
    if (!IO::FolderExists(MG_StampsDir(repoDir))) return;
    string[]@ files = IO::IndexFolder(MG_StampsDir(repoDir), false);
    if (files is null) return;
    for (uint i = 0; i < files.Length; i++) {
        string text = MG_ReadTextFile(files[i]);
        if (text.Length == 0) continue;
        try {
            Json::Value@ j = Json::Parse(text);
            if (j is null) continue;
            MGStamp@ s = MGStamp();
            s.name = j["name"];
            s.commit = j["commit"];
            s.author = j["author"];
            s.time = int64(j["time"]);
            g_mgStamps.InsertLast(s);
        } catch { }
    }
}

// Stamp the current state (auto-saves unsaved work as "snapshot" first).
void MG_StampCoro() {
    if (g_mgRepoBusy) return;
    startnew(MG_StampWork);
}

void MG_StampWork() {
    g_mgRepoBusy = true;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("stamp: no map open"); g_mgRepoBusy = false; return; }
    string name = MG_SanitizeStampName(g_mgStampName);
    if (name.Length == 0) { MG_Log("stamp: enter a name first"); g_mgRepoBusy = false; return; }
    string mapFile = MG_MapFileOf(map);
    string repoId = MG_RepoIdFor(mapFile);
    string repoDir = MG_ReposRoot() + "/" + repoId;
    MG_EnsureRepo(repoDir, repoId, mapFile, map.MapName);
    string branch = MG_CurrentBranch(repoDir);
    string tip = MG_TipSha(repoDir, branch);
    if (tip.Length == 0) { MG_Log("stamp: save a version first"); g_mgRepoBusy = false; return; }

    // unsaved work? snapshot it so the stamp captures what you see
    MG_Log("stamp: checking for unsaved changes...");
    MGManifest@ m = MG_BuildManifest(map);
    string tmp = IO::FromStorageFolder("stamp-manifest.json");
    MG_WriteManifest(m, tmp);
    yield();
    string msha = MG_Sha256File(tmp);
    string parents, tm, tb, author, message;
    int64 time;
    if (!MG_ReadCommit(repoDir, tip, parents, tm, tb, author, message, time)) {
        g_mgRepoBusy = false; return;
    }
    if (tm != msha || MG_MediaChangedSince(map, repoDir, tip)) {
        // snapshot commit so the stamp points at what is on screen right now
        g_mgCommitMsg = "snapshot for stamp '" + name + "'";
        MG_CommitCoro();
        yield();
        tip = MG_TipSha(repoDir, branch);
    }

    if (IO::FolderExists(MG_StampsDir(repoDir) + "/" + name + ".json")) {
        MG_Log("stamp: '" + name + "' already exists (stamps are kept)");
    } else {
        MGStamp@ s = MGStamp();
        s.name = name;
        s.commit = tip;
        s.author = MG_AuthorName();
        s.time = Time::Stamp;
        if (!IO::FolderExists(MG_StampsDir(repoDir))) IO::CreateFolder(MG_StampsDir(repoDir));
        MG_WriteTextFile(MG_StampsDir(repoDir) + "/" + name + ".json",
            "{\"name\":\"" + name + "\",\"commit\":\"" + s.commit +
            "\",\"author\":\"" + s.author + "\",\"time\":" + s.time + "}");
        MG_Log("stamp: '" + name + "' saved (restore it any time from the timeline)");
    }
    g_mgStampName = "";
    MG_LoadStamps(repoDir);
    g_mgRepoBusy = false;
}

// ------------------------- restore (working map <- version, history kept) -------------------------

string g_mgRestoreTarget = "";

void MG_RestoreCoro(const string&in commitSha) {
    if (g_mgRepoBusy) return;
    g_mgRestoreTarget = commitSha;
    startnew(MG_RestoreWork);
}

void MG_RestoreWork() {
    string commitSha = g_mgRestoreTarget;
    g_mgRepoBusy = true;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("restore: no map open"); g_mgRepoBusy = false; return; }
    string mapFile = MG_MapFileOf(map);
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(mapFile);
    string branch = MG_CurrentBranch(repoDir);
    string tip = MG_TipSha(repoDir, branch);

    // refuse while dirty: your unsaved work would be overwritten
    MG_Log("restore: checking for unsaved changes...");
    MGManifest@ m = MG_BuildManifest(map);
    string tmp = IO::FromStorageFolder("restore-manifest.json");
    MG_WriteManifest(m, tmp);
    yield();
    string msha = MG_Sha256File(tmp);
    string parents, tm, tb, author, message;
    int64 time;
    if (!MG_ReadCommit(repoDir, tip, parents, tm, tb, author, message, time)) {
        g_mgRepoBusy = false; return;
    }
    if (tm != msha || MG_MediaChangedSince(map, repoDir, tip, false)) {
        g_mgRepoStatusText = "restore refused: you have unsaved changes (share or undo them first)";
        MG_Log("restore: " + g_mgRepoStatusText);
        g_mgRepoBusy = false;
        return;
    }

    // the version's manifest must match what we restore to (sanity)
    string rParents, rManifest, rBlob, rAuthor, rMessage;
    int64 rTime;
    if (!MG_ReadCommit(repoDir, commitSha, rParents, rManifest, rBlob, rAuthor, rMessage, rTime)) {
        MG_Log("restore: version unreadable"); g_mgRepoBusy = false; return;
    }
    if (rManifest == msha) {
        MG_Log("restore: the map is already at this version");
        g_mgRepoBusy = false;
        return;
    }

    string blobPath = repoDir + "/objects/blobs/" + rBlob + ".gbx";
    if (!IO::FileExists(blobPath)) { MG_Log("restore: snapshot data missing"); g_mgRepoBusy = false; return; }
    CSystemFidFile@ mapFid = map.MapInfo.Fid;
    string mapPath;
    if (mapFid !is null) { mapPath = mapFid.FullFileName; }
    else { mapPath = IO::FromUserGameFolder(mapFile); }
    try {
        MG_CopyFile(blobPath, mapPath);
    } catch {
        MG_Log("restore: failed to write the map file: " + getExceptionInfo());
        g_mgRepoBusy = false;
        return;
    }
    MG_Log("restore: reloading the map at " + MG_Short(commitSha) + " (history is kept — your next save becomes a new version)");

    if (Permissions::OpenAdvancedMapEditor()) {
        auto app = cast<CGameManiaPlanet>(GetApp());
        app.BackToMainMenu();
        while (!app.ManiaTitleControlScriptAPI.IsReady) yield();
        while (app.Switcher.ModuleStack.Length < 1 || cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) yield();
        yield();
        app.ManiaTitleControlScriptAPI.EditMap(mapFile, "", "");
        uint waited = 0;
        while (GetMap() is null && waited < 3000) { yield(); waited++; }
    }
    g_mgRepoStatusText = "restored an older version — share it to make it the shared map";
    MG_RefreshStatusCoro();
}

// ------------------------- first save of a brand-new map -------------------------

string g_mgSaveName = "";
string g_mgSaveError = "";
bool g_mgSaving = false;

string MG_SafeFileName(const string&in nameIn) {
    string n = Text::StripFormatCodes(nameIn);
    n = n.Replace("\\", "-").Replace("/", "-").Replace(":", "-").Replace("*", "-").Replace("?", "-")
         .Replace("\"", "'").Replace("<", "-").Replace(">", "-").Replace("|", "-");
    while (n.Length > 0 && (n.SubStr(n.Length - 1, 1) == " " || n.SubStr(n.Length - 1, 1) == ".")) n = n.SubStr(0, n.Length - 1);
    while (n.Length > 0 && n.SubStr(0, 1) == " ") n = n.SubStr(1);
    return n;
}

string MG_NewMapRelPath(const string&in name) {
    return "My Maps/" + MG_SafeFileName(name) + ".Map.Gbx";
}

void RenderSaveNewMapCard(CGameCtnChallenge@ map) {
    UI::TextWrapped("This map hasn't been saved yet. MapGit needs a saved file before it can keep versions or share it. "
                    "Type a name and MapGit saves it to My Maps for you.");
    UI::Dummy(vec2(0, 4));
    if (g_mgSaveName.Length == 0) {
        string current = map.MapName;
        current = Text::StripFormatCodes(current);
        if (current != "Unnamed") g_mgSaveName = current;
    }
    bool changed;
    UI::SetNextItemWidth(280);
    g_mgSaveName = UI::InputText("Map name##new-map-name", g_mgSaveName, changed);
    string safe = MG_SafeFileName(g_mgSaveName);
    UI::BeginDisabled(g_mgSaving || safe.Length == 0);
    if (UI::Button(Icons::FloppyO + " Save map")) startnew(MG_SaveNewMapWork);
    UI::EndDisabled();
    if (safe.Length > 0) {
        UI::SameLine();
        UI::TextDisabled("saves as Maps/" + MG_NewMapRelPath(g_mgSaveName));
    }
    if (g_mgSaving) UI::TextDisabled("Saving...");
    if (g_mgSaveError.Length > 0) UI::Text("\\$f84" + g_mgSaveError);
    UI::Dummy(vec2(0, 6));
    UI::TextDisabled("You can also save from the editor's own Save button; MapGit picks it up automatically.");
}

void MG_SaveNewMapWork() {
    if (g_mgSaving) return;
    g_mgSaveError = "";
    CGameCtnEditorFree@ ed = GetEditorFree();
    CGameCtnChallenge@ map = GetMap();
    if (ed is null || map is null) { g_mgSaveError = "Open the map in the editor first."; return; }
    string name = MG_SafeFileName(g_mgSaveName);
    if (name.Length == 0) { g_mgSaveError = "Enter a name first."; return; }
    string rel = MG_NewMapRelPath(name);
    if (IO::FileExists(IO::FromUserGameFolder("Maps/" + rel))) {
        g_mgSaveError = "A map called '" + name + "' already exists in My Maps. Pick another name.";
        return;
    }
    g_mgSaving = true;
    MG_Log("save: saving new map as Maps/" + rel);
    ed.Challenge.MapName = name;
    ed.PluginMapType.SaveMap(rel);
    for (uint i = 0; i < 300 && !MG_MapIsSaved(map); i++) yield();
    ed.Challenge.MapName = name; // the game can reset the title to the file name on save
    g_mgSaving = false;
    if (!MG_MapIsSaved(map)) {
        g_mgSaveError = "The game didn't save the map. Try the editor's Save button instead.";
        MG_Log("save: SaveMap did not produce a file");
        return;
    }
    g_mgSaveName = "";
    g_mgAutoRepoKey = ""; // re-detect the repo for the newly named file
    MG_Log("save: saved — you can Share now");
}

// ------------------------- panel UI -------------------------

string g_mgRemoteSentence = ""; // set by the remote check (e.g. teammates shared changes)

void RenderNoMapHome() {
    MG_Heading("Open a map to get started");
    UI::TextWrapped("MapGit works inside the map editor. Open an existing map, or create a new one, "
                    "and this window will show you what to do next.");
    UI::Dummy(vec2(0, 8));
    if (g_ghToken.Length == 0) {
        UI::TextDisabled("While you're here: connect GitHub so you can share maps with your collaborators.");
        RenderGitHubAuthSection();
        UI::Dummy(vec2(0, 8));
    }
    if (UI::Button(Icons::Download + " Join a collaborator's map")) S_Page = MG_PAGE_JOIN;
    UI::SameLine();
    if (UI::Button(Icons::QuestionCircle + " Show me how MapGit works")) MG_OnboardingStart();
}

void RenderMainPanel() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        RenderNoMapHome();
        return;
    }
    if (MG_MapIsSaved(map)) MG_AutoLoadRepoState(map);
    if (!g_mgMergeActive && MG_ShouldShowGettingStarted(map)) {
        RenderGettingStarted(map);
        // Until the map has a first version, the checklist is the whole page.
        if (!MG_MapIsSaved(map) || g_mgRepoTip.Length == 0) return;
        UI::Dummy(vec2(0, 6));
    }
    string mapFile = MG_MapFileOf(map);
    string repoId = MG_RepoIdFor(mapFile);
    string repoDir = MG_ReposRoot() + "/" + repoId;

    // ---- header: the map + a plain-language status ----
    UI::Text(map.MapName);
    string sentence;
    if (!IO::FolderExists(repoDir)) {
        sentence = "MapGit isn't watching this map yet.";
    } else if (g_mgRepoBusy) {
        sentence = "Working...";
    } else if (g_mgRemoteSentence.Length > 0) {
        sentence = g_mgRemoteSentence;
    } else if (g_mgRepoStatusText.StartsWith("dirty")) {
        sentence = "You have changes your collaborators can't see yet.";
    } else if (MG_CachedRemote(repoDir).Length == 0 && g_mgRepoTip.Length > 0) {
        sentence = "Versions are kept on this PC only. Share to send the map to your collaborators.";
    } else if (g_mgRepoStatusText.StartsWith("clean")) {
        sentence = "\\$8f0" + "Everyone has the same map.";
    } else if (g_mgRepoTip.Length == 0) {
        sentence = "No versions yet — Share to create the first one.";
    } else {
        sentence = g_mgRepoStatusText;
    }
    UI::TextDisabled(sentence);
    if (g_mgMergeActive && g_mgMergeStatus.Length > 0) {
        UI::Text("\\$ff0" + g_mgMergeStatus);
    }

    UI::Separator();

    if (!IO::FolderExists(repoDir)) {
        // ---- first run ----
        if (UI::Button(T("Start tracking this map", "Init repository"))) {
            MG_EnsureRepo(repoDir, repoId, mapFile, map.MapName);
            MG_LoadTimeline(repoDir, MG_TipSha(repoDir, MG_CurrentBranch(repoDir)));
        }
        UI::SameLine();
        UI::TextDisabled("versions are stored on your PC until you Share");
        if (g_ghToken.Length == 0) {
            UI::Separator();
            RenderGitHubAuthSection();
        }
        return;
    }

    // ---- share / update ----
    bool changed;
    UI::SetNextItemWidth(280);
    g_mgShareNote = UI::InputText("##share-note", g_mgShareNote, changed);
    UI::SameLine();
    UI::TextDisabled("what did you change? (optional)");
    UI::BeginDisabled(g_mgRepoBusy || g_ghBusy);
    if (UI::Button(T("Share", "Share (save + push)"))) MG_ShareCoro();
    UI::EndDisabled();
    UI::SameLine();
    UI::TextDisabled("saves your work and sends it to the shared map");
    UI::BeginDisabled(g_mgRepoBusy || g_ghBusy || g_mgMergeActive);
    if (UI::Button(T("Update", "Download"))) MG_GetCoro();
    UI::EndDisabled();
    UI::SameLine();
    UI::TextDisabled("brings in changes others shared");

    // ---- conflict resolve (everyday) ----
    if (g_mgMergeActive) {
        RenderEverydayConflictPanel();
    }

    // Only nag about GitHub here when it's needed; the connection itself lives on the GitHub page.
    if (g_ghToken.Length == 0 && !g_mgMergeActive) {
        UI::Separator();
        RenderGitHubAuthSection();
    }
}

void RenderHistoryPage() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor to use MapGit.");
        return;
    }
    MG_AutoLoadRepoState(map);
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
    if (!IO::FolderExists(repoDir)) {
        UI::TextDisabled("MapGit isn't watching this map yet. Start tracking it from Home.");
        return;
    }

    // ---- stamps ----
    UI::SeparatorText("Checkpoints");
    bool changed;
    UI::SetNextItemWidth(200);
    g_mgStampName = UI::InputText("##stamp-name", g_mgStampName, changed);
    UI::SameLine();
    UI::BeginDisabled(g_mgRepoBusy || g_mgStampName.Length == 0);
    if (UI::Button(T("Stamp", "Stamp (tag)"))) MG_StampCoro();
    UI::EndDisabled();
    UI::SameLine();
    UI::TextDisabled("name a checkpoint you can return to");

    if (g_mgStamps.Length > 0) {
        for (uint i = 0; i < g_mgStamps.Length; i++) {
            MGStamp@ s = g_mgStamps[i];
            UI::Text("\\$fd0" + "\\$i" + s.name);
            UI::SameLine();
            UI::TextDisabled("by " + s.author + ", " + MG_TimeAgo(s.time));
            UI::SameLine();
            UI::BeginDisabled(g_mgRepoBusy);
            if (UI::Button("go back to this##stamp" + i)) MG_RestoreCoro(s.commit);
            UI::EndDisabled();
        }
    }

    // ---- timeline ----
    UI::SeparatorText(T("Recent versions", "History"));
    if (g_mgPanelLogLines.Length == 0) {
        UI::TextDisabled("  nothing yet — Share to create the first version");
    } else {
        for (uint i = 0; i < g_mgPanelLogLines.Length; i++) {
            string[] parts = g_mgPanelLogLines[i].Split("|");
            if (parts.Length < 4) continue;
            string author = parts[0];
            string message = parts[1];
            string timeStr = parts[2];
            UI::Text("  " + author + "  —  " + (message.Length > 0 ? message : "(no note)") +
                     "   (" + MG_TimeAgo(int64(Text::ParseInt(timeStr))) + ")");
            UI::SameLine();
            UI::BeginDisabled(g_mgRepoBusy);
            if (UI::Button(T("go back to this", "restore") + "##v" + i)) MG_RestoreCoro(parts[3]);
            UI::EndDisabled();
        }
    }
}

// Checks the shared map's remote for collaborator changes (cheap: one GET).
// Called automatically every few minutes (see MG_RemoteCheckTick) and on panel load.
string g_mgNotifiedRemoteGit = ""; // last remote tip we notified about (dedupe)

void MG_CheckRemoteCoro() {
    if (g_ghBusy) return;
    startnew(MG_CheckRemoteWork);
}

void MG_CheckRemoteWork() {
    g_ghBusy = true;
    try {
        CGameCtnChallenge@ map = GetMap();
        if (map is null || g_ghToken.Length == 0) { g_ghBusy = false; return; }
        string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
        if (!GH_ReadRemote(repoDir)) { g_ghBusy = false; return; } // not shared yet
        string branch = MG_CurrentBranch(repoDir);
        string localTip = MG_TipSha(repoDir, branch);
        string lastLocal, lastGit;
        GH_ReadRemoteState(repoDir, branch, lastLocal, lastGit);
        string originTip = GH_OriginTipSha(repoDir, branch);
        // Local has unpushed work and a fetched remote tip waiting → combine needed
        if (originTip.Length > 0 && localTip.Length > 0 && originTip != localTip && localTip != lastLocal) {
            g_mgRemoteSentence = "\\$ff0" + "Your changes and your collaborators' both need combining — Update to resolve.";
            g_ghBusy = false;
            return;
        }
        Json::Value@ remoteRef = GH_Api("GET", GH_ApiUrl("/git/refs/heads/" + branch), "");
        if (remoteRef is null && g_ghLastCode == 404) { g_ghBusy = false; return; } // never pushed
        if (remoteRef is null) {
            // keep prior sentence on transient network fail
            g_ghBusy = false;
            return;
        }
        string remoteGit = remoteRef["object"]["sha"];
        if (remoteGit != lastGit) {
            if (localTip.Length > 0 && lastLocal.Length > 0 && localTip != lastLocal) {
                g_mgRemoteSentence = "\\$ff0" + "Your collaborators shared new changes — Update to combine them with yours.";
            } else {
                g_mgRemoteSentence = "\\$ff0" + "Your collaborators shared new changes — Update to see them.";
            }
            if (remoteGit != g_mgNotifiedRemoteGit) {
                g_mgNotifiedRemoteGit = remoteGit; // notify once per remote tip
                string mapName = map.MapName;
                UI::ShowNotification("MapGit", "'" + mapName + "' — your collaborators shared new changes. Open MapGit and Update.");
                MG_Log("remote check: new shared changes waiting (" + MG_Short(remoteGit) + ")");
            }
        } else if (g_mgRemoteSentence.Length > 0 && !g_mgMergeActive) {
            // still in sync — clear only when we are actually caught up
            g_mgRemoteSentence = "";
        }
    } catch {
        // never block the panel on a network hiccup; keep prior sentence
    }
    g_ghBusy = false;
}

// Per-frame scheduler gate: cheap timestamp check, real work runs in the coroutine.
[Setting name="Check for collaborator changes every N minutes (0 = off)"]
int S_RemoteCheckMinutes = 3;

int64 g_mgLastRemoteCheck = 0;

void MG_RemoteCheckTick() {
    if (S_RemoteCheckMinutes <= 0) return;
    if (g_ghToken.Length == 0) return;
    if (g_mgRepoBusy || g_ghBusy || g_mgMergeActive) return;
    if (Time::Stamp - g_mgLastRemoteCheck < int64(S_RemoteCheckMinutes) * 60) return;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) return;
    g_mgLastRemoteCheck = Time::Stamp;
    MG_CheckRemoteCoro();
}

string g_mgShareNote = "";

// ------------------------- share / get -------------------------

// Share: save unsaved work as a version, then upload to the shared map.
void MG_ShareCoro() {
    if (g_mgRepoBusy || g_ghBusy) return;
    startnew(MG_ShareWork);
}

void MG_ShareWork() {
    g_mgRepoBusy = true;
    try {
        CGameCtnChallenge@ map = GetMap();
        if (map is null) { MG_Log("share: no map open"); g_mgRepoBusy = false; return; }
        if (!MG_MapIsSaved(map)) {
            g_mgRepoStatusText = "save your map with a name first";
            MG_Log("share: the map has never been saved — save it with a name first");
            g_mgRepoBusy = false;
            return;
        }
        string mapFile = MG_MapFileOf(map);
        string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(mapFile);
        string branch = MG_CurrentBranch(repoDir);
        string tip = MG_TipSha(repoDir, branch);

        if (tip.Length == 0) {
            // no versions yet: the share IS the first version — then push
            g_mgCommitMsg = g_mgShareNote.Length > 0 ? g_mgShareNote : "first version";
            g_mgShareNote = "";
            MG_CommitCoro();
        } else {
            // unsaved work? save it as a version first (the share includes it)
            MG_Log("share: checking for unsaved changes...");
            MGManifest@ m = MG_BuildManifest(map);
            string tmp = IO::FromStorageFolder("share-manifest.json");
            MG_WriteManifest(m, tmp);
            yield();
            string msha = MG_Sha256File(tmp);
            string parents, tm, tb, author, message;
            int64 time;
            if (!MG_ReadCommit(repoDir, tip, parents, tm, tb, author, message, time)) {
                g_mgRepoBusy = false; return;
            }
            if (tm != msha || MG_MediaChangedSince(map, repoDir, tip)) {
                g_mgCommitMsg = g_mgShareNote.Length > 0 ? g_mgShareNote : "shared changes";
                g_mgShareNote = "";
                MG_Log("share: saving your unsaved work as a version...");
                MG_CommitCoro();
            } else {
                MG_Log("share: nothing new to save locally");
                g_mgCommitMsg = g_mgShareNote;
            }
        }

        g_mgRepoBusy = false;
        if (g_ghToken.Length == 0) {
            g_mgRepoStatusText = "connect to GitHub below to share with your collaborators";
            g_ghStatus = g_mgRepoStatusText;
            MG_Log("share: " + g_mgRepoStatusText);
            return;
        }

        // If the remote moved since last sync, merge first instead of force-pushing.
        if (GH_ReadRemote(repoDir)) {
            string lastLocal, lastGit;
            GH_ReadRemoteState(repoDir, branch, lastLocal, lastGit);
            Json::Value@ remoteRef = GH_Api("GET", GH_ApiUrl("/git/refs/heads/" + branch), "");
            if (remoteRef !is null) {
                string remoteGit = remoteRef["object"]["sha"];
                if (lastGit.Length > 0 && remoteGit != lastGit) {
                    MG_Log("share: remote has new changes — updating/combining before share");
                    g_mgRepoStatusText = "combining with your collaborators' changes before sharing...";
                    g_ghStatus = g_mgRepoStatusText;
                    g_mgMergePushAfter = true;
                    GH_PullWork(); // may FF, or start merge (leaves merge active)
                    if (g_mgMergeActive) {
                        MG_Log("share: conflicts need resolving before share can finish");
                        return;
                    }
                    // clean merge or FF already pushed if requested; otherwise push below
                }
            }
        }

        GH_PushCoro();
    } catch {
        MG_Log("share: EXCEPTION - " + getExceptionInfo());
        g_ghStatus = "share failed — see log";
        g_mgRepoBusy = false;
    }
}

// Get: download the shared map's latest (FF or merge when both sides moved).
void MG_GetCoro() {
    if (g_mgRepoBusy || g_ghBusy || g_mgMergeActive) return;
    startnew(MG_GetWork);
}

void MG_GetWork() {
    g_mgRepoBusy = true;
    try {
        CGameCtnChallenge@ map = GetMap();
        if (map is null) { MG_Log("get: no map open"); g_mgRepoBusy = false; return; }
        string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
        if (!GH_ReadRemote(repoDir)) {
            g_mgRepoStatusText = "no shared map yet — Share first to create it";
            g_ghStatus = g_mgRepoStatusText;
            MG_Log("get: " + g_mgRepoStatusText);
            g_mgRepoBusy = false;
            return;
        }
        g_mgRepoBusy = false;
        g_mgMergePushAfter = !S_DevTools; // everyday Update that merges should share the result
        GH_PullCoro();
    } catch {
        MG_Log("get: EXCEPTION - " + getExceptionInfo());
        g_ghStatus = "update failed — see log";
        g_mgRepoBusy = false;
    }
}

// Everyday conflict wizard — one difference at a time, plain language, no git jargon.
void RenderEverydayConflictPanel() {
    UI::Separator();
    int unresolved = MG_CountUnresolvedConflicts();
    int total = int(g_mgConflicts.Length);
    int done = total - unresolved;

    if (unresolved == 0) {
        UI::Text("\\$8f0" + "All differences decided (" + total + ")");
        UI::TextDisabled("Apply saves the combined map and shares it with your collaborators.");
        UI::BeginDisabled(g_mgRepoBusy);
        if (UI::Button("Apply & Share")) {
            g_mgMergePushAfter = true;
            MG_ApplyMergeCoro();
        }
        UI::EndDisabled();
        UI::SameLine();
        if (UI::Button("Cancel") && !g_mgRepoBusy) {
            MG_ClearConflictPreviews();
            MG_ClearMergeState();
            g_mgMergePushAfter = false;
        }
        return;
    }

    // Keep focus on an unresolved conflict
    if (g_mgConflictFocus < 0 || g_mgConflictFocus >= total ||
        g_mgConflicts[g_mgConflictFocus].resolution != 0) {
        int next = MG_NextUnresolvedConflict(g_mgConflictFocus < 0 ? -1 : g_mgConflictFocus);
        MG_SetConflictFocus(next < 0 ? 0 : next);
    }

    MGMergeConflict@ c = g_mgConflicts[g_mgConflictFocus];

    UI::Text("\\$ff0" + "Difference #" + (g_mgConflictFocus + 1) + "  \\$aaa(" + unresolved + " of " + total + " left)");
    UI::Text(MG_FriendlyConflictTitle(c));
    UI::BeginDisabled(unresolved < 2);
    if (UI::Button("< Previous##prev")) MG_SetConflictFocus(MG_PrevUnresolvedConflict(g_mgConflictFocus));
    UI::SameLine();
    if (UI::Button("Next >##next")) MG_SetConflictFocus(MG_NextUnresolvedConflict(g_mgConflictFocus));
    UI::EndDisabled();
    UI::SameLine();
    if (UI::Button("Look at it##look")) MG_FocusConflictCamera(g_mgConflictFocus);
    UI::Dummy(vec2(0, 4));

    // Side-by-side plain cards: title + up to two wrapped name lines + a button
    float cardH = UI::GetTextLineHeightWithSpacing() * 3.0 + UI::GetFrameHeightWithSpacing() + 16.0 * UI::GetScale();
    int cardFlags = UI::WindowFlags::NoScrollbar | UI::WindowFlags::NoScrollWithMouse;
    UI::BeginChild("mg-yours", vec2(UI::GetWindowSize().x * 0.45, cardH), UI::ChildFlags::Borders, cardFlags);
    UI::Text("\\$0f2" + "Yours (green)");
    UI::TextWrapped(c.hasOursPos ? MG_PrettyName(c.oursSummary) : MG_FriendlySideLabel(c.oursSummary, true));
    if (c.hasOursPos) {
        if (UI::Button("Show only yours##showo")) {
            MG_SetConflictViewMode(1);
            g_mgLastCamTarget = vec3(-99999, -99999, -99999);
            MG_JumpCamera(c.oursPos);
        }
    }
    UI::EndChild();
    UI::SameLine();
    UI::BeginChild("mg-theirs", vec2(0, cardH), UI::ChildFlags::Borders, cardFlags);
    UI::Text("\\$f42" + "Theirs (red)");
    UI::TextWrapped(c.hasTheirsPos ? MG_PrettyName(c.theirsSummary) : MG_FriendlySideLabel(c.theirsSummary, false));
    if (c.hasTheirsPos) {
        if (UI::Button("Show only theirs##showt")) {
            MG_SetConflictViewMode(2);
            g_mgLastCamTarget = vec3(-99999, -99999, -99999);
            MG_JumpCamera(c.theirsPos);
        }
    } else {
        UI::TextDisabled("(not in the world)");
    }
    UI::EndChild();

    UI::Dummy(vec2(0, 4));
    RenderConflictViewModeButtons();
    UI::TextDisabled(g_mgViewMode == 2
        ? "Your block is set aside while you look — it comes back when you switch view or decide."
        : "Their version appears as a see-through ghost. Your real block stays in place.");

    // Big choice buttons
    float bw = (UI::GetWindowSize().x - 48) / 2.0;
    if (bw < 120) bw = 120;
    if (UI::Button("Keep yours##ky", vec2(bw, 0))) {
        c.resolution = 1;
        MG_OnEverydayChoiceMade();
    }
    UI::SameLine();
    if (UI::Button("Use theirs##ut", vec2(bw, 0))) {
        c.resolution = 2;
        MG_OnEverydayChoiceMade();
    }
    if (c.kind == 6) {
        UI::TextDisabled("Pick the start you want to keep — the other one is left out.");
    } else if (c.kind == 7) {
        UI::TextDisabled("Clips can't be shown in the world — open MediaTracker after combining to check them.");
    } else if ((c.kind == 0 || c.kind == 1) && !MG_ConflictHasStart(c)) {
        if (UI::Button("Keep both##kb", vec2(bw, 0))) {
            c.resolution = 3;
            MG_OnEverydayChoiceMade();
        }
        UI::SameLine();
        if (UI::Button("Remove both##rb", vec2(bw, 0))) {
            c.resolution = 4;
            MG_OnEverydayChoiceMade();
        }
    } else if (!MG_ConflictHasStart(c)) {
        if (UI::Button("Remove it##ri", vec2(bw, 0))) {
            c.resolution = 4;
            MG_OnEverydayChoiceMade();
        }
    }

    UI::Dummy(vec2(0, 8));
    UI::TextDisabled(done + " decided · " + unresolved + " left");
    if (UI::Button("Cancel") && !g_mgRepoBusy) {
        MG_ClearConflictPreviews();
        MG_ClearMergeState();
        g_mgMergePushAfter = false;
    }
}

void RenderConflictViewModeButtons() {
    UI::Text("Show:");
    UI::SameLine();
    if (UI::Button((g_mgViewMode == 0 ? "\\$ff0" : "") + "Both##vm0")) MG_SetConflictViewMode(0);
    UI::SameLine();
    if (UI::Button((g_mgViewMode == 1 ? "\\$ff0" : "") + "Only yours##vm1")) MG_SetConflictViewMode(1);
    UI::SameLine();
    if (UI::Button((g_mgViewMode == 2 ? "\\$ff0" : "") + "Only theirs##vm2")) MG_SetConflictViewMode(2);
}

void MG_OnEverydayChoiceMade() {
    int next = MG_NextUnresolvedConflict(g_mgConflictFocus);
    if (next >= 0) {
        MG_SetConflictFocus(next);
    } else {
        MG_ClearConflictPreviews();
        g_mgConflictFocus = 0;
    }
}
