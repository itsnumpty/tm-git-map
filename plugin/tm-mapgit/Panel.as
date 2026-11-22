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
    if (tm != msha) {
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
        s.author = S_MGAuthor;
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

void MG_RestoreCoro(string commitSha) {
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
    if (tm != msha) {
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

// ------------------------- panel UI -------------------------

string g_mgRemoteSentence = ""; // set by the remote check (e.g. teammates shared changes)

void RenderMainPanel() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor to use MapGit.");
        return;
    }
    MG_AutoLoadRepoState(map);
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
        sentence = "You have changes your team can't see yet.";
    } else if (g_mgRepoStatusText.StartsWith("clean")) {
        sentence = "\\$8f0" + "Everyone has the same map.";
    } else if (g_mgRepoTip.Length == 0) {
        sentence = "No versions yet — Share to create the first one.";
    } else {
        sentence = g_mgRepoStatusText;
    }
    UI::TextDisabled(sentence);

    UI::Separator();

    if (!IO::FolderExists(repoDir)) {
        // ---- first run ----
        if (UI::Button(T("Start tracking this map", "Init repository"))) {
            MG_EnsureRepo(repoDir, repoId, mapFile, map.MapName);
            MG_LoadTimeline(repoDir, MG_TipSha(repoDir, MG_CurrentBranch(repoDir)));
        }
        UI::SameLine();
        UI::TextDisabled("versions are stored on your PC until you Share");
        UI::Separator();
        RenderGitHubAuthSection();
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
    UI::BeginDisabled(g_mgRepoBusy || g_ghBusy);
    if (UI::Button(T("Update", "Download"))) MG_GetCoro();
    UI::EndDisabled();
    UI::SameLine();
    UI::TextDisabled("brings in changes others shared");

    // ---- github connection ----
    RenderGitHubAuthSection();

    // ---- stamps ----
    UI::Separator();
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
    UI::Separator();
    UI::Text(T("Recent versions", "History") + ":");
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

// Checks the shared map's remote for changes teammates made (cheap: one GET).
// Called automatically every few minutes (see MG_RemoteCheckTick) and on panel load.
string g_mgNotifiedRemoteGit = ""; // last remote tip we notified about (dedupe)

void MG_CheckRemoteCoro() {
    if (g_ghBusy) return;
    startnew(MG_CheckRemoteWork);
}

void MG_CheckRemoteWork() {
    g_ghBusy = true;
    try {
        g_mgRemoteSentence = "";
        CGameCtnChallenge@ map = GetMap();
        if (map is null || g_ghToken.Length == 0) { g_ghBusy = false; return; }
        string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
        if (!GH_ReadRemote(repoDir)) { g_ghBusy = false; return; } // not shared yet
        string branch = MG_CurrentBranch(repoDir);
        Json::Value@ remoteRef = GH_Api("GET", GH_ApiUrl("/git/refs/heads/" + branch), "");
        if (remoteRef is null && g_ghLastCode == 404) { g_ghBusy = false; return; } // never pushed
        if (remoteRef is null) { g_ghBusy = false; return; }
        string remoteGit = remoteRef["object"]["sha"];
        string lastLocal, lastGit;
        GH_ReadRemoteState(repoDir, branch, lastLocal, lastGit);
        if (remoteGit != lastGit) {
            g_mgRemoteSentence = "\\$ff0" + "Your team shared new changes — Update to see them.";
            if (remoteGit != g_mgNotifiedRemoteGit) {
                g_mgNotifiedRemoteGit = remoteGit; // notify once per remote tip
                string mapName = map.MapName;
                UI::ShowNotification("MapGit", "'" + mapName + "' — your team shared new changes. Open MapGit and Update.");
                MG_Log("remote check: new shared changes waiting (" + MG_Short(remoteGit) + ")");
            }
        }
    } catch {
        // never block the panel on a network hiccup
    }
    g_ghBusy = false;
}

// Per-frame scheduler gate: cheap timestamp check, real work runs in the coroutine.
[Setting name="Check for teammate changes every N minutes (0 = off)"]
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

// ------------------------- share / get (stage 1: commit+push / pull) -------------------------

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
        string mapFile = MG_MapFileOf(map);
        string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(mapFile);
        string branch = MG_CurrentBranch(repoDir);
        string tip = MG_TipSha(repoDir, branch);
        if (tip.Length == 0) {
            // no versions yet: the share IS the first version
            g_mgCommitMsg = g_mgShareNote.Length > 0 ? g_mgShareNote : "first version";
            g_mgShareNote = "";
            MG_CommitCoro();
            g_mgRepoBusy = false;
            return;
        }

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
        if (tm != msha) {
            g_mgCommitMsg = g_mgShareNote.Length > 0 ? g_mgShareNote : "shared changes";
            g_mgShareNote = "";
            MG_Log("share: saving your unsaved work as a version...");
            MG_CommitCoro();
        } else {
            MG_Log("share: nothing new to save locally");
            g_mgCommitMsg = g_mgShareNote; // kept for the remote sync note below
        }

        // upload to the shared map (creates the remote on first share)
        g_mgRepoBusy = false;
        if (g_ghToken.Length == 0) {
            g_mgRepoStatusText = "connect to GitHub below to share with your team";
            MG_Log("share: " + g_mgRepoStatusText);
            return;
        }
        GH_PushCoro();
    } catch {
        MG_Log("share: EXCEPTION - " + getExceptionInfo());
        g_mgRepoBusy = false;
    }
}

// Get: download the shared map's latest.
void MG_GetCoro() {
    if (g_mgRepoBusy || g_ghBusy) return;
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
            MG_Log("get: " + g_mgRepoStatusText);
            g_mgRepoBusy = false;
            return;
        }
        g_mgRepoBusy = false;
        GH_PullCoro();
    } catch {
        MG_Log("get: EXCEPTION - " + getExceptionInfo());
        g_mgRepoBusy = false;
    }
}
