// GitHub.as — Phase C.1: device-flow auth + push to a real GitHub repository via
// the git database REST API (blobs/trees/commits/refs). Remotes are genuine,
// cloneable git repos. Port of the S12-verified spike flow.
//
// Remote layout per repo:
//   map.Map.Gbx      — the blob snapshot (base64 git blob)
//   manifest.json    — the canonical manifest
//   commits map 1:1  — message carries the mapgit header line
// Remote binding:   <repoDir>/remote.json  {owner, repo}
// Remote state:     <repoDir>/refs/remotes/origin/<branch>  "<localSha> <gitSha>"

// Production client id (the "Trackmania MapGit" OAuth app). Not a secret — OAuth
// client ids are public identifiers; only the user's own token grants access.
const string MG_GH_DEFAULT_CLIENT_ID = "Ov23likjqw7qR9j0rIH6";

[Setting name="GitHub OAuth client id override (empty = built-in)"]
string S_GHClientId = "";

// Legacy setting, kept only to migrate tokens out of the SHARED Settings.ini
// (where any plugin could read it by declaring the same setting name).
[Setting name="GitHub token (device flow)" hidden]
string S_GHToken = "";

// The token lives in PluginStorage/tm-mapgit/auth.json (this plugin's own folder).
// NOTE: Openplanet has no secret storage — the file is plaintext and any plugin can
// read arbitrary files; this only removes the trivial settings-name exfiltration.
// Revocation: github.com/settings/applications (one click), or Log out below.
string g_ghToken = "";
string g_ghUserCode = "";
string g_ghUri = "";
string g_ghUriComplete = "";
string g_ghLogin = "";
string g_ghStatus = "not connected";
bool g_ghBusy = false;
string g_ghRepoName = "";
bool g_ghPrivate = true;
string g_ghExistingRepo = ""; // "owner/name" to bind without creating
int g_ghLastCode = 0;

string GH_ClientId() {
    return (S_GHClientId.Length > 0) ? S_GHClientId : MG_GH_DEFAULT_CLIENT_ID;
}

string GH_TokenPath() {
    return IO::FromStorageFolder("auth.json");
}

void GH_SaveToken() {
    MG_WriteTextFile(GH_TokenPath(), "{\"token\":\"" + g_ghToken + "\",\"login\":\"" + g_ghLogin + "\"}");
}

void GH_LoadToken() {
    string text = MG_ReadTextFile(GH_TokenPath());
    if (text.Length > 0) {
        try {
            Json::Value@ j = Json::Parse(text);
            if (j !is null) {
                g_ghToken = j["token"];
                if (j.HasKey("login") && g_ghLogin.Length == 0) g_ghLogin = j["login"];
                return;
            }
        } catch { }
    }
    // one-time migration from the shared settings file
    if (S_GHToken.Length > 0) {
        g_ghToken = S_GHToken;
        S_GHToken = "";
        GH_SaveToken();
        MG_Log("GitHub: token migrated from Settings.ini to plugin storage");
    }
}

// ------------------------- device flow (S12-verified pattern) -------------------------

void GH_StartDeviceFlow() {
    if (GH_ClientId().Length == 0) {
        MG_Log("GitHub: no client id available");
        return;
    }
    startnew(GH_DeviceFlowCoro);
}

void GH_DeviceFlowCoro() {
    g_ghBusy = true;
    auto req = Net::HttpRequest(
        "https://github.com/login/device/code",
        "client_id=" + GH_ClientId() + "&scope=repo");
    req.Headers["Accept"] = "application/json";
    req.Start();
    while (!req.Finished()) yield();

    if (req.Error() != "" || req.ResponseCode() != 200) {
        MG_Log("GitHub: device/code failed: HTTP " + req.ResponseCode() + " " + req.Error() +
               " body: " + req.String().SubStr(0, 200));
        g_ghBusy = false;
        return;
    }

    Json::Value@ j = req.Json();
    if (j is null || !j.HasKey("device_code")) {
        MG_Log("GitHub: no device_code in response: " + req.String().SubStr(0, 200));
        g_ghBusy = false;
        return;
    }

    string deviceCode = j["device_code"];
    g_ghUserCode = j["user_code"];
    g_ghUri = j["verification_uri"];
    g_ghUriComplete = "";
    if (j.HasKey("verification_uri_complete")) {
        g_ghUriComplete = j["verification_uri_complete"]; // link with the code pre-filled
    }
    int interval = j.HasKey("interval") ? int(j["interval"]) : 5;
    int expires = j.HasKey("expires_in") ? int(j["expires_in"]) : 900;

    IO::SetClipboard(g_ghUserCode);
    UI::ShowNotification("MapGit", "Code copied: " + g_ghUserCode + " — visit " + g_ghUri);
    MG_Log("GitHub: visit " + g_ghUri + " and enter " + g_ghUserCode +
           " (copied to clipboard). Polling every " + interval + "s...");

    int64 deadline = Time::Stamp + expires;
    while (Time::Stamp < deadline) {
        sleep(interval * 1000);

        auto tokReq = Net::HttpRequest(
            "https://github.com/login/oauth/access_token",
            "client_id=" + GH_ClientId() +
            "&device_code=" + deviceCode +
            "&grant_type=urn:ietf:params:oauth:grant-type:device_code");
        tokReq.Headers["Accept"] = "application/json";
        tokReq.Start();
        while (!tokReq.Finished()) yield();

        Json::Value@ tj = tokReq.Json();
        if (tj !is null && tj.HasKey("access_token")) {
            g_ghToken = tj["access_token"];
            g_ghUserCode = "";
            GH_SaveToken();
            MG_Log("GitHub: token acquired (" + g_ghToken.Length + " chars, stored in plugin storage)");
            UI::ShowNotification("MapGit", "GitHub linked!");
            g_ghBusy = false;
            return;
        }

        string err = "?";
        if (tj !is null && tj.HasKey("error")) err = tj["error"];
        if (err == "authorization_pending") continue;
        if (err == "slow_down") { interval += 5; continue; }
        MG_Log("GitHub: device flow error: " + err);
        g_ghBusy = false;
        return;
    }
    MG_Log("GitHub: device flow expired");
    g_ghBusy = false;
}

// ------------------------- API helpers -------------------------

// Performs a GET/POST/PATCH with auth; returns parsed Json (null on failure).
// Sets g_ghLastCode for callers that expect e.g. 404.
Json::Value@ GH_Api(const string&in method, const string&in url, const string&in body) {
    if (g_ghToken.Length == 0) {
        MG_Log("GitHub: no token — log in first");
        return null;
    }
    Net::HttpRequest@ req = Net::HttpRequest();
    req.Url = url;
    if (body.Length > 0) req.Body = body;
    if (method == "GET") req.Method = Net::HttpMethod::Get;
    else if (method == "POST") req.Method = Net::HttpMethod::Post;
    else if (method == "PUT") req.Method = Net::HttpMethod::Put;
    else if (method == "PATCH") req.Method = Net::HttpMethod::Patch;
    else { MG_Log("GitHub: unsupported method " + method); return null; }
    req.Headers["Authorization"] = "token " + g_ghToken;
    req.Headers["Accept"] = "application/vnd.github+json";
    if (body.Length > 0) req.Headers["Content-Type"] = "application/json";
    req.Start();
    while (!req.Finished()) yield();

    g_ghLastCode = req.ResponseCode();
    if (req.Error() != "" || (g_ghLastCode != 200 && g_ghLastCode != 201)) {
        if (g_ghLastCode == 401) {
            // the stored token is dead (revoked/expired) — clear it so the panel
            // offers reconnection and we stop retrying with it
            MG_Log("GitHub: login rejected (401 Bad credentials) — token cleared; reconnect from the panel");
            UI::ShowNotification("MapGit", "GitHub login expired — please reconnect from the MapGit panel.");
            g_ghToken = "";
            g_ghLogin = "";
            GH_SaveToken();
            g_ghStatus = "login expired — reconnect";
        }
        MG_Log("GitHub: " + method + " " + url + " -> HTTP " + g_ghLastCode + " " + req.Error() +
               " body: " + req.String().SubStr(0, 300));
        return null;
    }
    return req.Json();
}

string GH_ApiUrl(const string&in suffix) {
    return "https://api.github.com/repos/" + g_ghOwner + "/" + g_ghRepo + suffix;
}

string g_ghOwner = "";
string g_ghRepo = "";

// ------------------------- remote binding / state -------------------------

string MG_RemoteCfgPath(const string&in repoDir) {
    return repoDir + "/remote.json";
}

bool GH_ReadRemote(const string&in repoDir) {
    string text = MG_ReadTextFile(MG_RemoteCfgPath(repoDir));
    if (text.Length == 0) return false;
    try {
        Json::Value@ j = Json::Parse(text);
        if (j is null) return false;
        g_ghOwner = j["owner"];
        g_ghRepo = j["repo"];
        return g_ghOwner.Length > 0 && g_ghRepo.Length > 0;
    } catch {
        return false;
    }
}

void GH_WriteRemote(const string&in repoDir) {
    MG_WriteTextFile(MG_RemoteCfgPath(repoDir),
        "{\"owner\":\"" + g_ghOwner + "\",\"repo\":\"" + g_ghRepo + "\"}");
}

string GH_RemoteStatePath(const string&in repoDir, const string&in branch) {
    return repoDir + "/refs/remotes/origin/" + branch;
}

// content: "<localSha> <gitSha>"
void GH_WriteRemoteState(const string&in repoDir, const string&in branch,
                         const string&in localSha, const string&in gitSha) {
    string dir = repoDir + "/refs/remotes";
    if (!IO::FolderExists(dir)) IO::CreateFolder(dir);
    if (!IO::FolderExists(dir + "/origin")) IO::CreateFolder(dir + "/origin");
    MG_WriteTextFile(GH_RemoteStatePath(repoDir, branch), localSha + " " + gitSha);
}

void GH_ReadRemoteState(const string&in repoDir, const string&in branch,
                        string&out localSha, string&out gitSha) {
    localSha = "";
    gitSha = "";
    string text = MG_ReadTextFile(GH_RemoteStatePath(repoDir, branch));
    if (text.Length == 0) return;
    string[] parts = text.Split(" ");
    if (parts.Length >= 2) {
        localSha = parts[0];
        gitSha = parts[1];
    }
}

string GH_SanitizeRepoName(const string&in nameIn) {
    string n = nameIn.Replace(" ", "-").Replace(".", "-").Replace("/", "-").Replace("\\", "-")
                     .Replace(":", "-").Replace("*", "-").Replace("?", "-").Replace("\"", "-")
                     .Replace("<", "-").Replace(">", "-").Replace("|", "-").Replace("#", "-");
    return n;
}

// ------------------------- push -------------------------

void GH_PushCoro() {
    if (g_ghBusy) return;
    startnew(GH_PushWork);
}

void GH_PushWork() {
    g_ghBusy = true;
    g_ghStatus = "pushing...";
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("push: no map open"); g_ghBusy = false; g_ghStatus = "no map"; return; }
    if (g_ghToken.Length == 0) { MG_Log("push: log in first"); g_ghBusy = false; g_ghStatus = "not logged in"; return; }

    // login (cached)
    if (g_ghLogin.Length == 0) {
        Json::Value@ me = GH_Api("GET", "https://api.github.com/user", "");
        if (me is null) { g_ghBusy = false; g_ghStatus = "auth failed"; return; }
        g_ghLogin = me["login"];
        MG_Log("push: logged in as " + g_ghLogin);
    }

    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
    string branch = MG_CurrentBranch(repoDir);
    string tip = MG_TipSha(repoDir, branch);
    if (tip.Length == 0) { MG_Log("push: no commits on '" + branch + "' — commit first"); g_ghBusy = false; g_ghStatus = "no commits"; return; }

    // remote binding: create the repo on first push, or bind to an existing one
    if (!GH_ReadRemote(repoDir)) {
        if (g_ghOwner.Length > 0 && g_ghRepo.Length > 0) {
            // pre-bound via the "existing repository" input
            GH_WriteRemote(repoDir);
            MG_Log("push: bound to existing " + g_ghOwner + "/" + g_ghRepo);
        } else {
            if (GH_ClientId().SubStr(0, 2) == "Iv") {
                MG_Log("push: client id is a GitHub App (Iv...) — its tokens cannot create repositories; "
                       "use a classic OAuth App or the existing-repository option");
            }
            string name = GH_SanitizeRepoName(g_ghRepoName);
            if (name.Length == 0) { MG_Log("push: enter a repository name first"); g_ghBusy = false; g_ghStatus = "need repo name"; return; }
            MG_Log("push: creating repository '" + name + "' (" + (g_ghPrivate ? "private" : "public") + ")...");
            string mapName = map.MapName; // wstring -> string (no Replace on wstring)
            string body = "{\"name\":\"" + name + "\",\"private\":" + (g_ghPrivate ? "true" : "false") +
                ",\"description\":\"MapGit repository for " + mapName.Replace("\"", "'") +
                "\",\"has_issues\":false,\"has_wiki\":false}";
            Json::Value@ created = GH_Api("POST", "https://api.github.com/user/repos", body);
            if (created is null) {
                g_ghStatus = "repo creation failed (name taken?)";
                g_ghBusy = false;
                return;
            }
            g_ghOwner = g_ghLogin;
            g_ghRepo = name;
            GH_WriteRemote(repoDir);
            MG_Log("push: created " + g_ghOwner + "/" + g_ghRepo);
        }
    }

    // remote state for this branch
    string lastLocal, lastGit;
    GH_ReadRemoteState(repoDir, branch, lastLocal, lastGit);
    if (lastLocal == tip) {
        MG_Log("push: already up to date (" + branch + " at " + MG_Short(tip) + ")");
        g_ghStatus = "up to date";
        g_ghBusy = false;
        return;
    }

    // walk the local chain tip -> root, stopping at the last pushed commit
    array<string> chain;
    string cur = tip;
    bool incremental = false;
    while (cur.Length > 0) {
        if (cur == lastLocal) { incremental = true; break; }
        chain.InsertLast(cur);
        string parents, manifest, blob, author, message;
        int64 time;
        if (!MG_ReadCommit(repoDir, cur, parents, manifest, blob, author, message, time)) {
            MG_Log("push: local commit unreadable: " + cur); g_ghBusy = false; g_ghStatus = "local store error"; return;
        }
        string[] p = parents.Split(",");
        cur = (p.Length > 0 && p[0].Length > 0) ? p[0] : "";
    }
    if (lastLocal.Length > 0 && !incremental) {
        MG_Log("push: WARNING - remote tip " + MG_Short(lastLocal) + " not in local history; full re-push (remote ref will be forced)");
    }

    // push chain root -> tip
    string prevGit = (incremental && lastGit.Length > 0) ? lastGit : "";
    if (!incremental && chain.Length > 0) {
        // full re-push: fresh roots, no parents for the first commit
        prevGit = "";
    }

    string gitTip = "";
    for (int i = int(chain.Length) - 1; i >= 0; i--) {
        string localSha = chain[i];
        string parents, manifest, blob, author, message;
        int64 time;
        if (!MG_ReadCommit(repoDir, localSha, parents, manifest, blob, author, message, time)) {
            MG_Log("push: commit unreadable during push"); g_ghBusy = false; g_ghStatus = "local store error"; return;
        }
        yield();

        // git blob: the map snapshot
        string gitBlobSha = GH_UploadFileBlob(repoDir + "/objects/blobs/" + blob + ".gbx");
        if (gitBlobSha.Length == 0 && g_ghLastCode == 409) {
            MG_Log("push: empty repository — bootstrapping the initial commit via the Contents API...");
            if (!GH_BootstrapRepo()) { g_ghBusy = false; g_ghStatus = "bootstrap failed"; return; }
            gitBlobSha = GH_UploadFileBlob(repoDir + "/objects/blobs/" + blob + ".gbx");
        }
        if (gitBlobSha.Length == 0) { g_ghBusy = false; g_ghStatus = "blob upload failed"; return; }
        yield();

        // git blob: the manifest
        string gitManSha = GH_UploadFileBlob(repoDir + "/objects/manifests/" + manifest + ".json");
        if (gitManSha.Length == 0) { g_ghBusy = false; g_ghStatus = "manifest upload failed"; return; }
        yield();

        // tree
        string treeBody = "{\"tree\":[" +
            "{\"path\":\"map.Map.Gbx\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"" + gitBlobSha + "\"}," +
            "{\"path\":\"manifest.json\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"" + gitManSha + "\"}]}";
        Json::Value@ tree = GH_Api("POST", GH_ApiUrl("/git/trees"), treeBody);
        if (tree is null) { g_ghBusy = false; g_ghStatus = "tree creation failed"; return; }
        string gitTree = tree["sha"];

        // commit (message = mapgit header + user message, like the C# engine)
        string msg = "mapgit:v1 manifest:" + manifest + " blob:" + blob + "\n\n" + message +
                     " (MapGit commit " + localSha.SubStr(0, 10) + ")";
        string commitBody = "{\"message\":\"" + msg.Replace("\"", "'").Replace("\n", "\\n") +
            "\",\"tree\":\"" + gitTree + "\"" +
            (prevGit.Length > 0 ? ",\"parents\":[\"" + prevGit + "\"]" : "") + "}";
        Json::Value@ commit = GH_Api("POST", GH_ApiUrl("/git/commits"), commitBody);
        if (commit is null) { g_ghBusy = false; g_ghStatus = "commit creation failed"; return; }
        prevGit = commit["sha"];
        gitTip = prevGit;
        MG_Log("push: " + MG_Short(localSha) + " -> git " + MG_Short(gitTip));
    }

    // ref update (create on 404, else force-move)
    Json::Value@ existing = GH_Api("GET", GH_ApiUrl("/git/refs/heads/" + branch), "");
    if (g_ghLastCode == 404) {
        string refBody = "{\"ref\":\"refs/heads/" + branch + "\",\"sha\":\"" + gitTip + "\"}";
        Json::Value@ made = GH_Api("POST", GH_ApiUrl("/git/refs"), refBody);
        if (made is null) { g_ghBusy = false; g_ghStatus = "ref creation failed"; return; }
    } else if (existing !is null) {
        string refBody = "{\"sha\":\"" + gitTip + "\",\"force\":true}";
        Json::Value@ moved = GH_Api("PATCH", GH_ApiUrl("/git/refs/heads/" + branch), refBody);
        if (moved is null) { g_ghBusy = false; g_ghStatus = "ref update failed"; return; }
    } else {
        g_ghBusy = false;
        g_ghStatus = "ref check failed";
        return;
    }

    GH_WriteRemoteState(repoDir, branch, tip, gitTip);
    g_mgRemoteSentence = ""; // we just shared — the team state is now ours
    g_mgNotifiedRemoteGit = "";
    g_ghStatus = "pushed " + branch + " (" + chain.Length + " commits) to " + g_ghOwner + "/" + g_ghRepo;
    MG_Log("push: done — " + g_ghStatus);
    g_ghBusy = false;
}

// Bootstraps a fresh repo: PUT /contents works on empty repositories and creates
// the default branch, after which the git database API (blobs/trees/commits) works.
bool GH_BootstrapRepo() {
    string readme = "MapGit repository for this map - managed by the MapGit Openplanet plugin.\n\n"
                    "Each commit contains map.Map.Gbx (snapshot) + manifest.json (canonical manifest).\n";
    MemoryBuffer@ b = MemoryBuffer(readme.Length);
    b.Write(readme);
    b.Seek(0);
    string b64 = b.ReadToBase64(b.GetSize());
    string body = "{\"message\":\"MapGit init\",\"content\":\"" + b64 + "\"}";
    Json::Value@ res = GH_Api("PUT", GH_ApiUrl("/contents/README.md"), body);
    return res !is null;
}

// Uploads one file as a base64 git blob; returns the git blob sha ("" on failure).
// In-memory cache dedupes repeated uploads within a push.
dictionary g_ghBlobCache;

string GH_UploadFileBlob(const string&in path) {
    if (g_ghBlobCache.Exists(path)) {
        string cached;
        g_ghBlobCache.Get(path, cached);
        return cached;
    }
    IO::File f(path, IO::FileMode::Read);
    uint len = f.Size();
    MemoryBuffer@ data = f.Read(len);
    f.Close();
    if (data is null) return "";
    data.Seek(0);
    string b64 = data.ReadToBase64(data.GetSize());
    string body = "{\"content\":\"" + b64 + "\",\"encoding\":\"base64\"}";
    Json::Value@ blob = GH_Api("POST", GH_ApiUrl("/git/blobs"), body);
    if (blob is null) return "";
    string sha = blob["sha"];
    g_ghBlobCache.Set(path, sha);
    return sha;
}

// Bind to an existing "owner/name" repository (no creation), then push.
void GH_BindExistingCoro() {
    g_ghBusy = true;
    string input = g_ghExistingRepo.Replace("\\", "/").Replace("https://github.com/", "").Replace(" ", "");
    // accept "owner/name", "github.com/owner/name", or a full URL tail
    string[] parts = input.Split("/");
    if (parts.Length >= 2) {
        g_ghOwner = parts[parts.Length - 2];
        g_ghRepo = parts[parts.Length - 1];
    }
    if (g_ghOwner.Length == 0 || g_ghRepo.Length == 0 || g_ghOwner == "github.com") {
        MG_Log("push: enter the repository as owner/name (e.g. yourname/your-map)");
        g_ghBusy = false;
        return;
    }
    MG_Log("push: using existing repository " + g_ghOwner + "/" + g_ghRepo);
    g_ghBusy = false;
    GH_PushWork();
}

// ------------------------- pull -------------------------

// Days-from-civil (Howard Hinnant) for ISO "2026-11-20T14:50:49Z" -> unix seconds.
int64 GH_ParseIsoTime(const string&in iso) {
    try {
        string[] a = iso.Split("T");
        string[] d = a[0].Split("-");
        string[] t = a[1].Split(":");
        string sec = t[2];
        sec = sec.Replace("Z", "");
        int y = Text::ParseInt(d[0]);
        int mo = Text::ParseInt(d[1]);
        int da = Text::ParseInt(d[2]);
        int h = Text::ParseInt(t[0]);
        int mi = Text::ParseInt(t[1]);
        int s = Text::ParseInt(sec);
        int64 yy = int64(y) - ((mo <= 2) ? 1 : 0);
        int64 era = (yy >= 0 ? yy : yy - 399) / 400;
        int64 yoe = yy - era * 400;
        int64 doy = (153 * int64(mo + ((mo > 2) ? -3 : 9)) + 2) / 5 + int64(da) - 1;
        int64 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        int64 days = era * 146097 + doe - 719468;
        return days * 86400 + int64(h) * 3600 + int64(mi) * 60 + int64(s);
    } catch {
        return Time::Stamp;
    }
}

// Downloads a git blob, verifies its sha256 against the expected content hash,
// and writes it to the given local object path. Returns false on mismatch/failure.
bool GH_DownloadBlob(const string&in gitBlobSha, const string&in expectedSha256, const string&in destPath) {
    Json::Value@ b = GH_Api("GET", GH_ApiUrl("/git/blobs/" + gitBlobSha), "");
    if (b is null) return false;
    string content = b["content"];
    content = content.Replace("\n", ""); // contents-style wrapping, just in case
    MemoryBuffer@ buf = MemoryBuffer();
    buf.WriteFromBase64(content);
    buf.Seek(0);
    string bytes = buf.ReadString(buf.GetSize());
    string sha = Crypto::Sha256(bytes);
    if (sha != expectedSha256) {
        MG_Log("pull: VERIFICATION FAILED for " + destPath + " (got " + sha + ", want " + expectedSha256 + ")");
        return false;
    }
    buf.Seek(0);
    IO::File f(destPath, IO::FileMode::Write);
    f.Write(buf);
    f.Close();
    return true;
}

// Imports one remote commit into the local store. Returns the new local sha ("" to skip).
// Message format (fixed slices): "mapgit:v1 manifest:<64> blob:<64>\n\n<orig> (MapGit commit <10>)"
string GH_ImportRemoteCommit(const string&in msg, const string&in authorName, const string&in isoTime,
                             const string&in parentLocal) {
    if (!msg.StartsWith("mapgit:v1 manifest:")) return ""; // bootstrap/foreign commit — skip
    // "mapgit:v1 manifest:" (19) + sha64 + " blob:" (6) + sha64 + "\n\n" + orig + " (MapGit commit xxxxxxxxxx)" (27)
    if (msg.SubStr(83, 6) != " blob:") {
        MG_Log("pull: unexpected commit header format; cannot parse");
        return "";
    }
    string manifestSha = msg.SubStr(19, 64);
    string blobSha = msg.SubStr(89, 64);
    string origMsg = msg.SubStr(155, int(msg.Length) - 155 - 27);
    int64 time = GH_ParseIsoTime(isoTime);

    // objects: skip downloads if we already have them (shared history)
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(GetMap()));
    if (!IO::FileExists(repoDir + "/objects/blobs/" + blobSha + ".gbx") ||
        !IO::FileExists(repoDir + "/objects/manifests/" + manifestSha + ".json")) {
        // find the file blobs in the commit's tree
        Json::Value@ c = GH_Api("GET", GH_ApiUrl("/git/commits/" + g_ghCurImportSha), "");
        if (c is null) return "";
        string treeSha = c["tree"]["sha"];
        Json::Value@ tree = GH_Api("GET", GH_ApiUrl("/git/trees/" + treeSha), "");
        if (tree is null) return "";
        string gitMapSha = "", gitManSha = "";
        Json::Value@ entries = tree["tree"];
        for (uint i = 0; i < entries.Length; i++) {
            string path = entries[i]["path"];
            if (path == "map.Map.Gbx") gitMapSha = entries[i]["sha"];
            if (path == "manifest.json") gitManSha = entries[i]["sha"];
        }
        if (gitMapSha.Length == 0 || gitManSha.Length == 0) {
            MG_Log("pull: commit tree missing MapGit files; skipping");
            return "";
        }
        if (!IO::FileExists(repoDir + "/objects/blobs/" + blobSha + ".gbx")) {
            if (!GH_DownloadBlob(gitMapSha, blobSha, repoDir + "/objects/blobs/" + blobSha + ".gbx")) return "";
        }
        if (!IO::FileExists(repoDir + "/objects/manifests/" + manifestSha + ".json")) {
            if (!GH_DownloadBlob(gitManSha, manifestSha, repoDir + "/objects/manifests/" + manifestSha + ".json")) return "";
        }
    }

    // local commit object (same canonical shape as local commits)
    string commitJson = "{\"parents\":\"" + parentLocal + "\",\"manifest\":\"" + manifestSha +
        "\",\"blob\":\"" + blobSha + "\",\"author\":\"" + authorName + "\",\"message\":" + MG_JsonStr(origMsg) +
        ",\"time\":" + time +
        ",\"header\":\"mapgit:v1 manifest:" + manifestSha + " blob:" + blobSha + "\"}";
    string localSha = Crypto::Sha256(commitJson);
    MG_WriteTextFile(repoDir + "/commits/" + localSha + ".json", commitJson);
    return localSha;
}

string g_ghCurImportSha = ""; // git sha of the commit currently being imported

void GH_PullCoro() {
    if (g_ghBusy) return;
    startnew(GH_PullWork);
}

void GH_PullWork() {
    g_ghBusy = true;
    g_ghStatus = "pulling...";
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("pull: no map open"); g_ghBusy = false; g_ghStatus = "no map"; return; }
    if (g_ghToken.Length == 0) { MG_Log("pull: log in first"); g_ghBusy = false; g_ghStatus = "not logged in"; return; }
    if (g_ghLogin.Length == 0) {
        Json::Value@ me = GH_Api("GET", "https://api.github.com/user", "");
        if (me is null) { g_ghBusy = false; g_ghStatus = "auth failed"; return; }
        g_ghLogin = me["login"];
    }

    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
    if (!GH_ReadRemote(repoDir)) {
        MG_Log("pull: no remote bound for this map — push first");
        g_ghBusy = false; g_ghStatus = "no remote"; return;
    }
    string branch = MG_CurrentBranch(repoDir);
    string localTip = MG_TipSha(repoDir, branch);
    string lastLocal, lastGit;
    GH_ReadRemoteState(repoDir, branch, lastLocal, lastGit);

    // remote ref
    Json::Value@ remoteRef = GH_Api("GET", GH_ApiUrl("/git/refs/heads/" + branch), "");
    if (remoteRef is null && g_ghLastCode == 404) {
        MG_Log("pull: remote branch '" + branch + "' does not exist — push first");
        g_ghBusy = false; g_ghStatus = "remote branch missing"; return;
    }
    if (remoteRef is null) { g_ghBusy = false; g_ghStatus = "ref read failed"; return; }
    string remoteGit = remoteRef["object"]["sha"];
    if (remoteGit == lastGit) {
        MG_Log("pull: already up to date (" + branch + ")");
        g_ghStatus = "up to date";
        g_ghBusy = false;
        return;
    }

    // list remote commits (newest first) and collect the ones past our sync point
    Json::Value@ list = GH_Api("GET", GH_ApiUrl("/commits?sha=" + branch + "&per_page=100"), "");
    if (list is null) { g_ghBusy = false; g_ghStatus = "commit list failed"; return; }
    array<string> toImport;
    bool foundBase = (lastGit.Length == 0);
    for (uint i = 0; i < list.Length; i++) {
        string sha = list[i]["sha"];
        if (sha == lastGit) { foundBase = true; break; }
        toImport.InsertLast(sha);
    }
    if (!foundBase) {
        MG_Log("pull: remote history diverged from the last synced commit — merge is Phase D; refusing");
        g_ghStatus = "diverged (merge pending)";
        g_ghBusy = false;
        return;
    }
    if (toImport.Length == 0) {
        MG_Log("pull: nothing new");
        g_ghStatus = "up to date";
        g_ghBusy = false;
        return;
    }

    // import oldest-first
    string prevLocal = (lastGit.Length > 0) ? lastLocal : "";
    int imported = 0;
    for (int i = int(toImport.Length) - 1; i >= 0; i--) {
        g_ghCurImportSha = toImport[i];
        Json::Value@ e = GH_Api("GET", GH_ApiUrl("/git/commits/" + g_ghCurImportSha), "");
        if (e is null) { g_ghBusy = false; g_ghStatus = "commit read failed"; return; }
        string msg = e["message"];
        string authorName = g_ghLogin;
        try { authorName = e["author"]["name"]; } catch { }
        if (authorName.Length == 0) authorName = g_ghLogin;
        string isoTime = e["committer"]["date"];
        string newLocal = GH_ImportRemoteCommit(msg, authorName, isoTime, prevLocal);
        if (newLocal.Length == 0) {
            if (!msg.StartsWith("mapgit:v1")) { continue; } // bootstrap/README commit
            MG_Log("pull: import failed at " + MG_Short(g_ghCurImportSha));
            g_ghBusy = false; g_ghStatus = "import failed";
            return;
        }
        prevLocal = newLocal;
        imported++;
        MG_Log("pull: imported git " + MG_Short(g_ghCurImportSha) + " -> local " + MG_Short(newLocal));
        yield();
    }

    // fast-forward the branch when it has no unpushed local commits
    if (localTip == lastLocal) {
        MG_WriteTextFile(repoDir + "/refs/heads/" + branch, prevLocal);
        g_mgRepoTip = prevLocal;
        MG_Log("pull: fast-forwarded '" + branch + "' to " + MG_Short(prevLocal));

        // if the open map is clean, restore the new tip and reopen (like checkout)
        MG_Log("pull: checking the working map before restoring...");
        MGManifest@ m = MG_BuildManifest(map);
        string tmp = IO::FromStorageFolder("pull-manifest.json");
        MG_WriteManifest(m, tmp);
        yield();
        string msha = MG_Sha256File(tmp);
        string parents, tm, tb, author, message;
        int64 time;
        if (MG_ReadCommit(repoDir, prevLocal, parents, tm, tb, author, message, time) && tm != msha) {
            g_ghStatus = "imported " + imported + " commits; working map dirty — commit or undo, then reopen";
            MG_Log("pull: " + g_ghStatus);
        } else {
            CSystemFidFile@ mapFid = map.MapInfo.Fid;
            string mapPath;
            if (mapFid !is null) { mapPath = mapFid.FullFileName; }
            else { mapPath = IO::FromUserGameFolder(MG_MapFileOf(map)); }
            try {
                MG_CopyFile(repoDir + "/objects/blobs/" + tb + ".gbx", mapPath);
            } catch {
                MG_Log("pull: failed to write the map file: " + getExceptionInfo());
                g_ghStatus = "imported, map file write failed";
                g_ghBusy = false;
                return;
            }
            if (Permissions::OpenAdvancedMapEditor()) {
                string mapFile = MG_MapFileOf(map);
                auto app = cast<CGameManiaPlanet>(GetApp());
                app.BackToMainMenu();
                while (!app.ManiaTitleControlScriptAPI.IsReady) yield();
                while (app.Switcher.ModuleStack.Length < 1 || cast<CTrackManiaMenus>(app.Switcher.ModuleStack[0]) is null) yield();
                yield();
                app.ManiaTitleControlScriptAPI.EditMap(mapFile, "", "");
                uint waited = 0;
                while (GetMap() is null && waited < 3000) { yield(); waited++; }
                MG_Log("pull: reopened the map at " + MG_Short(prevLocal));
            }
            g_ghStatus = "pulled " + imported + " commits (" + branch + ")";
        }
    } else {
        g_ghStatus = "imported " + imported + " commits; local branch has unpushed commits — branch head kept (merge: Phase D)";
        MG_Log("pull: " + g_ghStatus);
    }

    GH_WriteRemoteState(repoDir, branch, prevLocal, remoteGit);
    g_mgRemoteSentence = "";   // we just brought the team's changes in
    g_mgNotifiedRemoteGit = "";
    MG_Log("pull: done — " + g_ghStatus);
    g_ghBusy = false;
}

// ------------------------- auth section (shared by panel + dev tab) -------------------------

// Compact GitHub connection UI for the everyday panel: no client-id input (the
// built-in app id covers normal users), just connect/log out + the device link.
void RenderGitHubAuthSection() {
    if (S_GHToken.Length == 0 && g_ghToken.Length == 0) {
        UI::BeginDisabled(g_ghBusy);
        if (UI::Button(T("Connect to GitHub", "Log in with GitHub"))) GH_StartDeviceFlow();
        UI::EndDisabled();
        UI::SameLine();
        UI::TextDisabled("required once to share maps with others");
        if (g_ghUserCode.Length > 0) {
            UI::Text("\\$fe1 code: " + g_ghUserCode + "  (copied to clipboard)");
            string linkUrl = (g_ghUriComplete.Length > 0) ? g_ghUriComplete : g_ghUri;
            if (g_ghUriComplete.Length > 0) {
                UI::TextLinkOpenURL("\\$0f0\\$iOpen github.com/login/device (code pre-filled)", linkUrl);
            } else {
                UI::TextLinkOpenURL("\\$0f0\\$iOpen " + g_ghUri, linkUrl);
            }
        }
    } else {
        UI::Text("\\$8f0" + "GitHub: " + (g_ghLogin.Length > 0 ? g_ghLogin : "connected"));
        UI::SameLine();
        if (UI::Button("Log out")) {
            g_ghToken = "";
            g_ghLogin = "";
            S_GHToken = "";
            GH_SaveToken();
            g_ghStatus = "not connected";
            MG_Log("GitHub: token cleared — you can log in again");
        }
    }
}

// ------------------------- UI -------------------------

void RenderGitHubTab() {
    UI::Text("GitHub sync (device-flow auth, real git repositories)");
    UI::Separator();

    bool changed;
    UI::SetNextItemWidth(300);
    S_GHClientId = UI::InputText("##gh-client", S_GHClientId, changed);
    UI::SameLine();
    UI::TextDisabled("client id override (empty = built-in)");

    if (g_ghToken.Length == 0) {
        UI::BeginDisabled(g_ghBusy);
        if (UI::Button("Log in with GitHub")) GH_StartDeviceFlow();
        UI::EndDisabled();
        if (g_ghUserCode.Length > 0) {
            UI::Text("\\$fe1 code: " + g_ghUserCode + "  (copied to clipboard)");
            string linkUrl = (g_ghUriComplete.Length > 0) ? g_ghUriComplete : g_ghUri;
            if (g_ghUriComplete.Length > 0) {
                UI::TextLinkOpenURL("\\$0f0\\$iOpen github.com/login/device (code pre-filled)", linkUrl);
            } else {
                UI::TextLinkOpenURL("\\$0f0\\$iOpen " + g_ghUri, linkUrl);
            }
        }
    } else {
        UI::Text("logged in as " + (g_ghLogin.Length > 0 ? g_ghLogin : "(unknown — will verify on upload)"));
        UI::SameLine();
        if (UI::Button("Log out")) {
            g_ghToken = "";
            g_ghLogin = "";
            S_GHToken = ""; // clears any legacy value too
            GH_SaveToken();
            g_ghStatus = "not connected";
            MG_Log("GitHub: token cleared — you can log in again");
        }
    }

    UI::Separator();
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor to push.");
        return;
    }

    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
    bool bound = GH_ReadRemote(repoDir);
    if (bound) {
        UI::Text("Remote: " + g_ghOwner + "/" + g_ghRepo + "  (" + T("version line", "branch") + " " + MG_CurrentBranch(repoDir) + ")");
        UI::BeginDisabled(g_ghBusy || g_ghToken.Length == 0);
        if (UI::Button(T("Upload", "Push") + " " + T("current version line", "branch"))) GH_PushCoro();
        UI::SameLine();
        if (UI::Button(T("Download", "Pull") + " " + T("current version line", "branch"))) GH_PullCoro();
        UI::EndDisabled();
    } else {
        UI::Text("First upload — creates a repository for this map:");
        if (g_ghRepoName.Length == 0) {
            g_ghRepoName = GH_SanitizeRepoName(map.MapName);
        }
        UI::SetNextItemWidth(280);
        g_ghRepoName = UI::InputText("##gh-repo-name", g_ghRepoName, changed);
        UI::SameLine();
        g_ghPrivate = UI::Checkbox("Private", g_ghPrivate);
        UI::BeginDisabled(g_ghBusy || g_ghToken.Length == 0 || g_ghRepoName.Length == 0);
        if (UI::Button(T("Create repository & upload", "Create repository & push"))) GH_PushCoro();
        UI::EndDisabled();

        UI::Text("or upload to an existing repository (GitHub App tokens cannot create repos):");
        UI::SetNextItemWidth(280);
        g_ghExistingRepo = UI::InputText("##gh-existing", g_ghExistingRepo, changed);
        UI::SameLine();
        UI::BeginDisabled(g_ghBusy || g_ghToken.Length == 0);
        if (UI::Button(T("Bind & upload", "Bind & push"))) startnew(GH_BindExistingCoro);
        UI::EndDisabled();
    }

    if (g_ghStatus.Length > 0) {
        UI::Separator();
        UI::Text(g_ghStatus);
    }
    UI::Separator();
    UI::TextDisabled("Remote repos contain map.Map.Gbx + manifest.json per commit — cloneable with git.");
}
