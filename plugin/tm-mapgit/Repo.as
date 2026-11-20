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
string S_MGAuthor = "its_numpty";

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
    string refPath = "C:/Users/taneo/AppData/Local/Temp/opencode/engine-manifest-test.json";
    if (IO::FileExists(refPath)) {
        MG_Log("sha256(engine-manifest-test.json) = " + MG_Sha256File(refPath) + "  (compare with Get-FileHash)");
    } else {
        MG_Log("sha256 self-test: reference file missing: " + refPath);
    }
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

// The open map's file path, normalized to forward slashes ("My Maps/Ninconpoop TEST.Map.Gbx").
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
            g_mgRepoStatusText = (tm == msha) ? "clean (manifest matches HEAD)"
                                              : "dirty (manifest differs from HEAD " + MG_Short(g_mgRepoTip) + ")";
            MG_LoadLog(repoDir, g_mgRepoTip);
        } else {
            g_mgRepoStatusText = "HEAD commit unreadable: " + g_mgRepoTip;
        }
    }
    MG_Log("status: branch=" + g_mgRepoBranch + " tip=" + MG_Short(g_mgRepoTip) + " manifest=" + MG_Short(msha));
    g_mgRepoBusy = false;
}

void MG_CommitCoro() {
    g_mgRepoBusy = true;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("commit: no map open"); g_mgRepoBusy = false; return; }
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

    // 4) branch/tip + dirty check
    string branch = MG_CurrentBranch(repoDir);
    string tip = MG_TipSha(repoDir, branch);
    if (tip.Length > 0) {
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

    // 6) commit object (sha = sha256 of the canonical commit json itself)
    string msg = g_mgCommitMsg.Length > 0 ? g_mgCommitMsg : "work in progress";
    string commitJson = "{\"parents\":\"" + tip + "\",\"manifest\":\"" + msha + "\",\"blob\":\"" + bsha +
        "\",\"author\":\"" + S_MGAuthor + "\",\"message\":" + MG_JsonStr(msg) +
        ",\"time\":" + Time::Stamp +
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
    MG_Log("commit: " + csha + "  \"" + msg + "\"");
    g_mgRepoBusy = false;
}

// ------------------------- UI -------------------------

void RenderRepoTab() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor to use MapGit.");
        return;
    }
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
    if (UI::Button("Commit current map")) startnew(MG_CommitCoro);
    UI::SameLine();
    if (UI::Button("Refresh status")) startnew(MG_RefreshStatusCoro);
    UI::SameLine();
    if (UI::Button("Test SHA-256")) MG_Sha256SelfTest();
    UI::EndDisabled();

    UI::Separator();
    UI::Text("History:");
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
