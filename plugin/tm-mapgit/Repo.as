// Repo.as — local repository for the open map: content-addressed object store,
// commits, refs (Phase B.2). Layout (file-based port of the C# reference design):
//   <Documents>/Trackmania/MapGit/<repoId>/
//     repo.meta.json, HEAD ("ref: refs/heads/main")
//     refs/heads/<branch>            (commit sha)
//     objects/manifests/<sha>.json   (canonical manifest)
//     objects/blobs/<sha>.gbx        (silent-save map snapshot)
//     commits/<sha>.json             (parents csv, manifest, blob, author, message, time)
// Repo identity = deterministic id from the map file path (never the game uid).

[Setting name="MapGit author name"]
string S_MGAuthor = "";

// Name recorded on versions: the chosen name, else the GitHub login.
string MG_AuthorName() {
    if (S_MGAuthor.Length > 0) return S_MGAuthor;
    if (g_ghLogin.Length > 0) return g_ghLogin;
    return "someone";
}

bool g_mgRepoBusy = false;
string g_mgRepoStatusText = "status not loaded yet";
string g_mgRepoBranch = "main";
string g_mgRepoTip = "";
string g_mgRepoId = "";
array<string> g_mgRepoLogLines;
string g_mgCommitMsg = "";

// ------------------------- file helpers -------------------------

string MG_ReadTextFile(const string&in path) {
    if (!IO::FileExists(path)) return "";
    IO::File f(path, IO::FileMode::Read);
    string s = f.ReadToEnd();
    f.Close();
    // trim trailing whitespace (external tools add CRLF; never let it into shas/urls)
    while (s.EndsWith("\r") || s.EndsWith("\n") || s.EndsWith(" ") || s.EndsWith("\t")) {
        s = s.SubStr(0, int(s.Length) - 1);
    }
    return s;
}

void MG_WriteTextFile(const string&in path, const string&in text) {
    IO::File f(path, IO::FileMode::Write);
    f.Write(text);
    f.Close();
}

void MG_CopyFile(const string&in from, const string&in to) {
    IO::File src(from, IO::FileMode::Read);
    MemoryBuffer@ data = src.Read(src.Size());
    src.Close();
    IO::File dst(to, IO::FileMode::Write);
    dst.Write(data);
    dst.Close();
}

string MG_Short(const string&in sha) {
    return (sha.Length >= 10) ? sha.SubStr(0, 10) : sha;
}

// ------------------------- repo identity + layout -------------------------

string MG_ReposRoot() {
    return IO::FromUserGameFolder("MapGit");
}

// ------------------------- hashing (native Crypto) -------------------------

// Openplanet strings carry raw bytes, so ReadToEnd() + Crypto::Sha256 works for
// binary files too (cross-checked against .NET Get-FileHash in the self-test).
string MG_Sha256File(const string&in path) {
    IO::File f(path, IO::FileMode::Read);
    string bytes = f.ReadToEnd();
    f.Close();
    return Crypto::Sha256(bytes);
}

void MG_Sha256SelfTest() {
    MG_Log("sha256(\"abc\") = " + Crypto::Sha256("abc") + "  want ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    MG_Log("sha256(\"\") = " + Crypto::Sha256("") + "  want e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}

string MG_RepoIdFor(const string&in mapFileRaw) {
    // MapInfo.FileName uses backslashes — normalize to forward slashes first
    string mapFile = mapFileRaw.Replace("\\", "/");
    string fname = mapFile;
    string[] parts = mapFile.Split("/");
    if (parts.Length > 0) fname = parts[parts.Length - 1];
    string stem = fname;
    string[] bits = fname.Split(".");
    if (bits.Length > 0) stem = bits[0];
    stem = stem.Replace("\\", "-").Replace("/", "-").Replace(":", "-").Replace("*", "-")
               .Replace("?", "-").Replace("\"", "-").Replace("<", "-").Replace(">", "-")
               .Replace("|", "-").Replace(" ", "_");
    return stem + "-" + Crypto::Sha256(mapFile).SubStr(0, 8);
}

// A brand-new map has no file until it's saved once; nothing can be versioned before that.
bool MG_MapIsSaved(CGameCtnChallenge@ map) {
    if (map is null) return false;
    string f = map.MapInfo.FileName;
    return f.Length > 0;
}

// The open map's file path, normalized to forward slashes.
string MG_MapFileOf(CGameCtnChallenge@ map) {
    string f = map.MapInfo.FileName; // wstring -> string (no Replace on wstring)
    return f.Replace("\\", "/");
}

void MG_EnsureRepo(const string&in repoDir, const string&in repoId, const string&in mapFile, const string&in mapName) {
    if (IO::FolderExists(repoDir)) return;
    IO::CreateFolder(MG_ReposRoot());
    IO::CreateFolder(repoDir);
    IO::CreateFolder(repoDir + "/objects");
    IO::CreateFolder(repoDir + "/objects/manifests");
    IO::CreateFolder(repoDir + "/objects/blobs");
    IO::CreateFolder(repoDir + "/commits");
    IO::CreateFolder(repoDir + "/refs");
    IO::CreateFolder(repoDir + "/refs/heads");
    MG_WriteTextFile(repoDir + "/HEAD", "ref: refs/heads/main");
    MG_WriteTextFile(repoDir + "/repo.meta.json",
        "{\"repoId\":" + MG_JsonStr(repoId) +
        ",\"mapFile\":" + MG_JsonStr(mapFile) +
        ",\"mapName\":" + MG_JsonStr(mapName) +
        ",\"createdAt\":" + Time::Stamp +
        ",\"branches\":[\"main\"]}");
    MG_Log("repo created: " + repoDir);
}

string MG_CurrentBranch(const string&in repoDir) {
    string head = MG_ReadTextFile(repoDir + "/HEAD");
    if (head.StartsWith("ref: refs/heads/")) {
        return head.SubStr(16, int(head.Length) - 16);
    }
    return "main";
}

string MG_TipSha(const string&in repoDir, const string&in branch) {
    return MG_ReadTextFile(repoDir + "/refs/heads/" + branch);
}

// Reads a commit json (fields: parents csv, manifest, blob, author, message, time, header).
// Returns false on missing/corrupt commit.
bool MG_ReadCommit(const string&in repoDir, const string&in sha,
                   string&out parents, string&out manifest, string&out blob,
                   string&out author, string&out message, int64&out time) {
    string text = MG_ReadTextFile(repoDir + "/commits/" + sha + ".json");
    if (text.Length == 0) return false;
    try {
        Json::Value@ j = Json::Parse(text);
        if (j is null) return false;
        parents = j["parents"];
        manifest = j["manifest"];
        blob = j["blob"];
        author = j["author"];
        message = j["message"];
        time = int64(j["time"]);
        return true;
    } catch {
        MG_Log("commit parse failed: " + getExceptionInfo());
        return false;
    }
}

// ------------------------- history -------------------------

void MG_LoadLog(const string&in repoDir, const string&in tip) {
    g_mgRepoLogLines.RemoveRange(0, g_mgRepoLogLines.Length);
    string cur = tip;
    for (uint i = 0; i < 20 && cur.Length > 0; i++) {
        string parents, manifest, blob, author, message;
        int64 time;
        if (!MG_ReadCommit(repoDir, cur, parents, manifest, blob, author, message, time)) {
            g_mgRepoLogLines.InsertLast(MG_Short(cur) + "  (commit file unreadable)");
            return;
        }
        g_mgRepoLogLines.InsertLast(MG_Short(cur) + "  " + author + "  " + message);
        string[] p = parents.Split(",");
        cur = (p.Length > 0 && p[0].Length > 0) ? p[0] : "";
    }
}

// ------------------------- status / commit -------------------------

void MG_RefreshStatusCoro() {
    g_mgRepoBusy = true;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { g_mgRepoStatusText = "no map open"; g_mgRepoBusy = false; return; }
    string mapFile = MG_MapFileOf(map);
    g_mgRepoId = MG_RepoIdFor(mapFile);
    string repoDir = MG_ReposRoot() + "/" + g_mgRepoId;
    MG_EnsureRepo(repoDir, g_mgRepoId, mapFile, map.MapName);
    g_mgRepoBranch = MG_CurrentBranch(repoDir);
    g_mgRepoTip = MG_TipSha(repoDir, g_mgRepoBranch);
    MG_LoadBranches(repoDir);

    yield();
    MGManifest@ m = MG_BuildManifest(map);
    string tmp = IO::FromStorageFolder("status-manifest.json");
    MG_WriteManifest(m, tmp);
    yield();
    string msha = MG_Sha256File(tmp);

    if (g_mgRepoTip.Length == 0) {
        g_mgRepoStatusText = "no commits yet (unborn HEAD) — first commit pending";
        g_mgRepoLogLines.RemoveRange(0, g_mgRepoLogLines.Length);
    } else {
        string parents, tm, tb, author, message;
        int64 time;
        if (MG_ReadCommit(repoDir, g_mgRepoTip, parents, tm, tb, author, message, time)) {
            bool same = tm == msha && !MG_MediaChangedSince(map, repoDir, g_mgRepoTip, false);
            g_mgRepoStatusText = same ? "clean (manifest matches HEAD)"
                                              : "dirty (manifest differs from HEAD " + MG_Short(g_mgRepoTip) + ")";
            MG_LoadLog(repoDir, g_mgRepoTip);
        } else {
            g_mgRepoStatusText = "HEAD commit unreadable: " + g_mgRepoTip;
        }
    }
    MG_Log("status: branch=" + g_mgRepoBranch + " tip=" + MG_Short(g_mgRepoTip) + " manifest=" + MG_Short(msha));
    MG_LoadTimeline(repoDir, g_mgRepoTip); // keep the panel timeline fresh
    MG_LoadStamps(repoDir);
    g_mgRepoBusy = false;
}

void MG_CommitCoro() {
    g_mgRepoBusy = true;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("commit: no map open"); g_mgRepoBusy = false; return; }
    if (!MG_MapIsSaved(map)) {
        g_mgRepoStatusText = "save your map with a name first";
        MG_Log("commit: the map has never been saved — save it with a name first");
        g_mgRepoBusy = false;
        return;
    }
    string mapFile = MG_MapFileOf(map);
    string repoId = MG_RepoIdFor(mapFile);
    string repoDir = MG_ReposRoot() + "/" + repoId;
    MG_EnsureRepo(repoDir, repoId, mapFile, map.MapName);

    // 1) silent save (volatile data must be flushed into the blob we snapshot).
    // NOTE: medal times are expected to clear on edits (TM2020 unvalidation) —
    // the manifest honestly records null then; never restore them.
    CGameCtnEditorFree@ ed = GetEditorFree();
    if (ed is null) { MG_Log("commit: editor not open"); g_mgRepoBusy = false; return; }
    bool saved = Editor::SaveMapSameName(ed);
    MG_Log("commit: SaveMapSameName -> " + (saved ? "true" : "false"));
    if (!saved) { g_mgRepoBusy = false; return; }
    yield();

    // 2) manifest snapshot
    MGManifest@ m = MG_BuildManifest(map);
    string tmpManifest = IO::FromStorageFolder("commit-manifest.json");
    MG_WriteManifest(m, tmpManifest);
    yield();
    string msha = MG_Sha256File(tmpManifest);

    // 3) blob snapshot (the saved file) — absolute path via the map's fid
    CSystemFidFile@ mapFid = map.MapInfo.Fid;
    string mapPath;
    if (mapFid !is null) {
        mapPath = mapFid.FullFileName; // wstring -> string (absolute path)
    } else {
        mapPath = IO::FromUserGameFolder(mapFile);
        MG_Log("commit: map fid missing, using " + mapPath);
    }
    yield();
    string bsha = MG_Sha256File(mapPath);
    MG_Log("commit: manifest " + MG_Short(msha) + ", blob " + MG_Short(bsha));

    // 4) branch/tip + dirty check (MediaTracker clips aren't in the manifest)
    string branch = MG_CurrentBranch(repoDir);
    string tip = MG_TipSha(repoDir, branch);
    string mediaFp = MG_MediaFingerprint(map);
    if (tip.Length > 0 && !MG_MediaChangedSince(map, repoDir, tip)) {
        string parents, tm, tb, author, message;
        int64 time;
        if (MG_ReadCommit(repoDir, tip, parents, tm, tb, author, message, time)) {
            if (tm == msha && tb == bsha) {
                g_mgRepoStatusText = "nothing to commit (identical to HEAD " + MG_Short(tip) + ")";
                MG_Log("commit: nothing to commit");
                g_mgRepoBusy = false;
                return;
            }
            if (tm == msha) {
                g_mgRepoStatusText = "nothing to commit (volatile-only save; manifest unchanged)";
                MG_Log("commit: volatile-only save skipped");
                g_mgRepoBusy = false;
                return;
            }
        }
    }

    // 5) store objects
    MG_CopyFile(tmpManifest, repoDir + "/objects/manifests/" + msha + ".json");
    yield();
    MG_CopyFile(mapPath, repoDir + "/objects/blobs/" + bsha + ".gbx");
    string customFiles = MG_SnapshotCustomFiles(m, repoDir);

    // 6) commit object (sha = sha256 of the canonical commit json itself).
    // A merge adds a second parent (set by the merge flow).
    string parentsCsv = tip;
    if (g_mgMergeSecondParent.Length > 0) {
        parentsCsv = (tip.Length > 0 ? tip + "," : "") + g_mgMergeSecondParent;
        g_mgMergeSecondParent = "";
    }
    string msg = g_mgCommitMsg.Length > 0 ? g_mgCommitMsg : "work in progress";
    string commitJson = "{\"parents\":\"" + parentsCsv + "\",\"manifest\":\"" + msha + "\",\"blob\":\"" + bsha +
        "\",\"author\":\"" + MG_AuthorName() + "\",\"message\":" + MG_JsonStr(msg) +
        ",\"time\":" + Time::Stamp +
        ",\"media\":" + MG_JsonStr(mediaFp) + ",\"items\":" + MG_JsonStr(customFiles) +
        ",\"header\":\"mapgit:v1 manifest:" + msha + " blob:" + bsha + "\"}";
    string tmpCommit = IO::FromStorageFolder("commit-tmp.json");
    MG_WriteTextFile(tmpCommit, commitJson);
    yield();
    string csha = MG_Sha256File(tmpCommit);
    MG_CopyFile(tmpCommit, repoDir + "/commits/" + csha + ".json");

    // 7) move the branch ref
    MG_WriteTextFile(repoDir + "/refs/heads/" + branch, csha);
    g_mgCommitMsg = "";
    g_mgRepoTip = csha;
    g_mgRepoBranch = branch;
    g_mgRepoStatusText = "clean (committed " + MG_Short(csha) + ")";
    MG_LoadLog(repoDir, csha);
    MG_LoadTimeline(repoDir, csha); // panel timeline
    MG_Log("commit: " + csha + "  \"" + msg + "\"");
    g_mgRepoBusy = false;
}

// ------------------------- branches + checkout -------------------------

array<string> g_mgBranches;
int g_mgSelBranch = 0;
string g_mgNewBranch = "";

void MG_LoadBranches(const string&in repoDir) {
    g_mgBranches.RemoveRange(0, g_mgBranches.Length);
    string[]@ files = IO::IndexFolder(repoDir + "/refs/heads", false);
    if (files is null) return;
    for (uint i = 0; i < files.Length; i++) {
        string[] parts = files[i].Split("/");
        string name = parts[parts.Length - 1];
        if (name.Length > 0) g_mgBranches.InsertLast(name);
    }
}

string MG_SanitizeBranchName(const string&in nameIn) {
    return nameIn.Replace("\\", "-").Replace("/", "-").Replace(":", "-").Replace(" ", "-")
                 .Replace("*", "-").Replace("?", "-").Replace("\"", "-").Replace("<", "-")
                 .Replace(">", "-").Replace("|", "-");
}

// Create + switch (git checkout -b): the new ref points at the current tip.
void MG_CreateBranchCoro() {
    g_mgRepoBusy = true;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("branch: no map open"); g_mgRepoBusy = false; return; }
    string name = MG_SanitizeBranchName(g_mgNewBranch);
    if (name.Length == 0) { MG_Log("branch: enter a name first"); g_mgRepoBusy = false; return; }
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
    string tip = MG_TipSha(repoDir, MG_CurrentBranch(repoDir));
    if (tip.Length == 0) { MG_Log("branch: no commits yet — commit first"); g_mgRepoBusy = false; return; }
    if (IO::FileExists(repoDir + "/refs/heads/" + name)) {
        MG_Log("branch: '" + name + "' already exists"); g_mgRepoBusy = false; return;
    }
    MG_WriteTextFile(repoDir + "/refs/heads/" + name, tip);
    MG_WriteTextFile(repoDir + "/HEAD", "ref: refs/heads/" + name);
    g_mgNewBranch = "";
    g_mgRepoBranch = name;
    MG_LoadBranches(repoDir);
    // keep the switch/checkout dropdown in sync with the new current line
    for (uint i = 0; i < g_mgBranches.Length; i++) {
        if (g_mgBranches[i] == name) g_mgSelBranch = int(i);
    }
    MG_Log("branch: created + switched to '" + name + "' at " + MG_Short(tip));
    g_mgRepoBusy = false;
}

// Real branch switching: refuse when dirty, restore the target blob to the map
// file, then reopen the map in the editor (verified S9 mechanism).
void MG_CheckoutCoro() {
    g_mgRepoBusy = true;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("checkout: no map open"); g_mgRepoBusy = false; return; }
    if (g_mgSelBranch < 0 || g_mgSelBranch >= int(g_mgBranches.Length)) {
        MG_Log("checkout: pick a branch first"); g_mgRepoBusy = false; return;
    }
    string target = g_mgBranches[g_mgSelBranch];
    string mapFile = MG_MapFileOf(map);
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(mapFile);
    string curBranch = MG_CurrentBranch(repoDir);
    if (target == curBranch) { MG_Log("checkout: already on '" + target + "'"); g_mgRepoBusy = false; return; }
    string tip = MG_TipSha(repoDir, curBranch);
    if (tip.Length == 0) { MG_Log("checkout: current branch has no commits — commit first"); g_mgRepoBusy = false; return; }

    // 1) refuse when dirty (live manifest must match the current tip's manifest)
    MG_Log("checkout: checking for uncommitted changes...");
    MGManifest@ m = MG_BuildManifest(map);
    string tmp = IO::FromStorageFolder("checkout-manifest.json");
    MG_WriteManifest(m, tmp);
    yield();
    string msha = MG_Sha256File(tmp);
    string parents, tm, tb, author, message;
    int64 time;
    if (!MG_ReadCommit(repoDir, tip, parents, tm, tb, author, message, time)) {
        MG_Log("checkout: HEAD commit unreadable"); g_mgRepoBusy = false; return;
    }
    if (tm != msha || MG_MediaChangedSince(map, repoDir, tip, false)) {
        g_mgRepoStatusText = "checkout refused: uncommitted changes (commit or undo them first)";
        MG_Log("checkout: refused — working map differs from HEAD " + MG_Short(tip));
        g_mgRepoBusy = false;
        return;
    }

    // 2) restore the target branch's blob to the map file
    string tTip = MG_TipSha(repoDir, target);
    string tParents, tManifest, tBlob, tAuthor, tMessage;
    int64 tTime;
    if (!MG_ReadCommit(repoDir, tTip, tParents, tManifest, tBlob, tAuthor, tMessage, tTime)) {
        MG_Log("checkout: target branch HEAD unreadable"); g_mgRepoBusy = false; return;
    }
    string blobPath = repoDir + "/objects/blobs/" + tBlob + ".gbx";
    if (!IO::FileExists(blobPath)) { MG_Log("checkout: blob missing: " + blobPath); g_mgRepoBusy = false; return; }
    CSystemFidFile@ mapFid = map.MapInfo.Fid;
    string mapPath;
    if (mapFid !is null) {
        mapPath = mapFid.FullFileName;
    } else {
        mapPath = IO::FromUserGameFolder(mapFile);
    }
    try {
        MG_CopyFile(blobPath, mapPath);
    } catch {
        MG_Log("checkout: failed to write the map file: " + getExceptionInfo());
        g_mgRepoBusy = false;
        return;
    }
    MG_WriteTextFile(repoDir + "/HEAD", "ref: refs/heads/" + target);
    MG_Log("checkout: restored " + MG_Short(tBlob) + " to the map file; reopening editor...");

    // 3) reopen the map (verified S9 pattern: BackToMainMenu + readiness + EditMap)
    if (!Permissions::OpenAdvancedMapEditor()) {
        MG_Log("checkout: no advanced-editor permission — reopen the map manually");
        g_mgRepoBusy = false;
        return;
    }
    auto app = cast<CGameManiaPlanet>(GetApp());
    app.BackToMainMenu();
    while (!app.ManiaTitleControlScriptAPI.IsReady) yield();
    while (app.Switcher.ModuleStack.Length < 1 || cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) yield();
    yield();
    app.ManiaTitleControlScriptAPI.EditMap(mapFile, "", "");
    MG_Log("checkout: EditMap called — waiting for the editor to reload...");

    uint waited = 0;
    while (GetMap() is null && waited < 3000) { yield(); waited++; }
    if (GetMap() is null) {
        MG_Log("checkout: editor did not reopen in time — refresh status manually");
        g_mgRepoBusy = false;
        return;
    }
    g_mgRepoBranch = target;
    MG_LoadBranches(repoDir);
    for (uint i = 0; i < g_mgBranches.Length; i++) {
        if (g_mgBranches[i] == target) g_mgSelBranch = int(i);
    }
    MG_Log("checkout: now on '" + target + "' at " + MG_Short(tTip));
    g_mgRepoBusy = false;
    MG_RefreshStatusCoro();
}

// ------------------------- UI -------------------------

string g_mgAutoRepoKey = ""; // last repo the tab auto-loaded (fast, no manifest build)

// One-time adoption for the one-shared-map model: if the repo's current line
// isn't 'main' (left over from branch-era testing), adopt its content as 'main'
// — but only when nothing on the existing main line would be orphaned.
bool MG_IsAncestor(const string&in repoDir, const string&in maybeAncestor, const string&in tip) {
    string cur = tip;
    for (uint i = 0; i < 1000 && cur.Length > 0; i++) {
        if (cur == maybeAncestor) return true;
        string parents, manifest, blob, author, message;
        int64 time;
        if (!MG_ReadCommit(repoDir, cur, parents, manifest, blob, author, message, time)) break;
        string[] p = parents.Split(",");
        cur = (p.Length > 0 && p[0].Length > 0) ? p[0] : "";
    }
    return false;
}

// Returns the branch to use (adopts the current line as 'main' when safe).
string MG_NormalizeToMainLine(const string&in repoDir, const string&in currentBranch) {
    if (currentBranch == "main") return currentBranch;
    string tip = MG_TipSha(repoDir, currentBranch);
    string mainTip = MG_TipSha(repoDir, "main");
    if (tip.Length == 0) return currentBranch; // nothing on the current line — leave as is
    bool adopt = (mainTip.Length == 0) || MG_IsAncestor(repoDir, mainTip, tip);
    if (!adopt) {
        MG_Log("NOTE: local '" + currentBranch + "' and 'main' have separate histories — "
               "sort them out with the Developer tools");
        return currentBranch;
    }
    MG_WriteTextFile(repoDir + "/refs/heads/main", tip);
    MG_WriteTextFile(repoDir + "/HEAD", "ref: refs/heads/main");
    MG_Log("adopted version line '" + currentBranch + "' as the shared 'main' line (" + MG_Short(tip) + ")");
    return "main";
}
void MG_AutoLoadRepoState(CGameCtnChallenge@ map) {
    string mapFile = MG_MapFileOf(map);
    string repoId = MG_RepoIdFor(mapFile);
    if (repoId == g_mgAutoRepoKey) return;
    g_mgAutoRepoKey = repoId;
    g_mgRepoId = repoId;
    string repoDir = MG_ReposRoot() + "/" + repoId;
    if (IO::FolderExists(repoDir)) {
        string currentBranch = MG_CurrentBranch(repoDir);
        g_mgRepoBranch = MG_NormalizeToMainLine(repoDir, currentBranch);
        g_mgRepoTip = MG_TipSha(repoDir, g_mgRepoBranch);
        MG_LoadBranches(repoDir);
        MG_LoadTimeline(repoDir, g_mgRepoTip);
        MG_LoadStamps(repoDir);
        for (uint i = 0; i < g_mgBranches.Length; i++) {
            if (g_mgBranches[i] == g_mgRepoBranch) g_mgSelBranch = int(i);
        }
        // automatic dirty check (runs in a coroutine; the UI stays responsive)
        if (!g_mgRepoBusy) startnew(MG_RefreshStatusCoro);
        // check the shared map for teammate changes (one cheap GET)
        g_mgRemoteSentence = "";
        if (g_ghToken.Length > 0) MG_CheckRemoteCoro();
    } else {
        g_mgRepoBranch = "main";
        g_mgRepoTip = "";
        g_mgBranches.RemoveRange(0, g_mgBranches.Length);
        g_mgRepoStatusText = "no versions yet — " + T("Save version", "Commit") + " to start tracking this map";
    }
}

void RenderRepoTab() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor to use MapGit.");
        return;
    }
    MG_AutoLoadRepoState(map);
    if (g_mgRepoId.Length == 0) {
        g_mgRepoId = MG_RepoIdFor(MG_MapFileOf(map));
    }
    UI::Text("Repository : " + g_mgRepoId);
    UI::Text("Branch     : " + g_mgRepoBranch + "   HEAD: " + (g_mgRepoTip.Length > 0 ? MG_Short(g_mgRepoTip) : "(none)"));
    UI::Text("State      : " + g_mgRepoStatusText);
    UI::Separator();

    bool changed;
    UI::SetNextItemWidth(440);
    g_mgCommitMsg = UI::InputText("##commit-msg", g_mgCommitMsg, changed);
    UI::BeginDisabled(g_mgRepoBusy);
    if (UI::Button(T("Save version", "Commit current map"))) startnew(MG_CommitCoro);
    UI::SameLine();
    if (UI::Button("Refresh status")) startnew(MG_RefreshStatusCoro);
    UI::SameLine();
    if (UI::Button("Test SHA-256")) MG_Sha256SelfTest();
    UI::EndDisabled();

    UI::Separator();
    UI::Text(T("Version lines", "Branches") + ":");
    if (g_mgBranches.Length == 0) {
        UI::TextDisabled("  (refresh status to load)");
    } else {
        if (g_mgSelBranch < 0 || g_mgSelBranch >= int(g_mgBranches.Length)) g_mgSelBranch = 0;
        if (UI::BeginCombo("##mg-branch", g_mgBranches[g_mgSelBranch])) {
            for (uint i = 0; i < g_mgBranches.Length; i++) {
                if (UI::Selectable(g_mgBranches[i], int(i) == g_mgSelBranch)) {
                    g_mgSelBranch = int(i);
                }
            }
            UI::EndCombo();
        }
        UI::BeginDisabled(g_mgRepoBusy);
        UI::SameLine();
        if (UI::Button(T("Switch", "Checkout"))) startnew(MG_CheckoutCoro);
        UI::EndDisabled();
    }
    UI::SetNextItemWidth(220);
    g_mgNewBranch = UI::InputText("##mg-new-branch", g_mgNewBranch, changed);
    UI::BeginDisabled(g_mgRepoBusy);
    UI::SameLine();
    if (UI::Button(T("New version line", "Create branch"))) startnew(MG_CreateBranchCoro);
    UI::EndDisabled();

    RenderMergeSection();

    UI::Separator();
    UI::Text(T("Version history", "History") + ":");
    if (g_mgRepoLogLines.Length == 0) {
        UI::TextDisabled("  (no commits yet)");
    } else {
        for (uint i = 0; i < g_mgRepoLogLines.Length; i++) {
            UI::Text("  " + g_mgRepoLogLines[i]);
        }
    }
    UI::Separator();
    UI::TextDisabled("Store: <Documents>/Trackmania/MapGit/<repoId>/ (content-addressed blobs, manifests, commits)");
}
