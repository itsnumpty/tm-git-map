// MapGit Phase A spike S12: GitHub device flow + authenticated API calls.
//
// Setup (once): create an OAuth app on GitHub:
//   github.com -> Settings -> Developer settings -> OAuth Apps -> New OAuth App
//   name: MapGit Spikes, homepage: http://localhost, callback: http://localhost
//   (device flow does not use the callback URL, but GitHub requires the field)
// Copy the Client ID into the setting below.

[Setting name="GitHub OAuth Client ID"]
string S_GHClientId = "";

[Setting name="GitHub token (device flow)" hidden]
string S_GHToken = "";

string g_ghUserCode = "";
string g_ghUri = "";
string g_ghLogin = "";

void GH_Log(const string&in msg) {
    PA_Log("GH: " + msg);
}

// ------------------------- device flow -------------------------

void GH_StartDeviceFlow() {
    if (S_GHClientId.Length == 0) {
        GH_Log("set the OAuth client id first (see instructions)");
        return;
    }
    startnew(GH_DeviceFlowCoro);
}

void GH_DeviceFlowCoro() {
    auto req = Net::HttpRequest(
        "https://github.com/login/device/code",
        "client_id=" + S_GHClientId + "&scope=repo");
    req.Headers["Accept"] = "application/json";
    req.Start();
    while (!req.Finished()) yield();

    if (req.Error() != "" || req.ResponseCode() != 200) {
        GH_Log("device/code failed: HTTP " + req.ResponseCode() + " " + req.Error() +
               " body: " + req.String().SubStr(0, 200));
        return;
    }

    Json::Value@ j = req.Json();
    if (j is null || !j.HasKey("device_code")) {
        GH_Log("no device_code in response: " + req.String().SubStr(0, 200));
        return;
    }

    string deviceCode = j["device_code"];
    g_ghUserCode = j["user_code"];
    g_ghUri = j["verification_uri"];
    int interval = j.HasKey("interval") ? int(j["interval"]) : 5;
    int expires = j.HasKey("expires_in") ? int(j["expires_in"]) : 900;

    IO::SetClipboard(g_ghUserCode);
    UI::ShowNotification("MapGit Spikes", "Code copied: " + g_ghUserCode + " — visit " + g_ghUri);
    GH_Log("visit " + g_ghUri + " and enter " + g_ghUserCode + " (copied to clipboard). Polling every " + interval + "s...");

    int64 deadline = Time::Stamp + expires;
    while (Time::Stamp < deadline) {
        sleep(interval * 1000);

        auto tokReq = Net::HttpRequest(
            "https://github.com/login/oauth/access_token",
            "client_id=" + S_GHClientId +
            "&device_code=" + deviceCode +
            "&grant_type=urn:ietf:params:oauth:grant-type:device_code");
        tokReq.Headers["Accept"] = "application/json";
        tokReq.Start();
        while (!tokReq.Finished()) yield();

        Json::Value@ tj = tokReq.Json();
        if (tj !is null && tj.HasKey("access_token")) {
            S_GHToken = tj["access_token"];
            g_ghUserCode = "";
            GH_Log("TOKEN ACQUIRED (stored in hidden setting; " + S_GHToken.Length + " chars)");
            UI::ShowNotification("MapGit Spikes", "GitHub linked!");
            return;
        }

        string err = "?";
        if (tj !is null && tj.HasKey("error")) {
            err = tj["error"];
        }
        if (err == "authorization_pending") continue;
        if (err == "slow_down") { interval += 5; continue; }
        GH_Log("device flow error: " + err);
        return;
    }

    GH_Log("device flow expired");
}

// ------------------------- authenticated API -------------------------

Json::Value@ GH_GetJson(const string&in url) {
    if (S_GHToken.Length == 0) {
        GH_Log("no token — run the device flow first");
        return null;
    }

    auto req = Net::HttpRequest(url);
    req.Headers["Authorization"] = "token " + S_GHToken;
    req.Headers["Accept"] = "application/vnd.github+json";
    req.Start();
    while (!req.Finished()) yield();

    if (req.Error() != "" || req.ResponseCode() != 200) {
        GH_Log("GET " + url + " -> HTTP " + req.ResponseCode() + " " + req.Error() +
               " body: " + req.String().SubStr(0, 200));
        return null;
    }
    return req.Json();
}

void GH_WhoAmI() {
    startnew(GH_WhoAmICoro);
}

void GH_WhoAmICoro() {
    Json::Value@ j = GH_GetJson("https://api.github.com/user");
    if (j is null) return;
    g_ghLogin = j["login"];
    int ghId = j["id"];
    GH_Log("logged in as: " + g_ghLogin + " (id " + ghId + ")");
}

void GH_ListRepos() {
    startnew(GH_ListReposCoro);
}

void GH_ListReposCoro() {
    Json::Value@ j = GH_GetJson("https://api.github.com/user/repos?per_page=5&sort=created");
    if (j is null) return;

    try {
        uint count = j.Length;
        if (count == 0) {
            GH_Log("no repos yet (expected on a fresh account)");
        }
        for (uint i = 0; i < count && i < 5; i++) {
            string full = j[i]["full_name"];
            bool priv = j[i]["private"];
            GH_Log("repo: " + full + (priv ? " (private)" : " (public)"));
        }
    } catch {
        GH_Log("unexpected response shape: " + getExceptionInfo());
    }
}

// ------------------------- UI -------------------------

void RenderGitHubTab() {
    UI::Text("S12 — GitHub device flow (in-plugin auth)");
    UI::TextWrapped("1. Create an OAuth app (github.com > Settings > Developer settings > OAuth Apps > New: "
                    "name MapGit, homepage http://localhost, callback http://localhost). "
                    "2. Paste its Client ID here. 3. Start the flow, visit the shown URL on any device, enter the code.");

    bool changed;
    UI::SetNextItemWidth(360);
    S_GHClientId = UI::InputText("##client-id", S_GHClientId, changed);
    UI::SameLine();
    UI::Text("client id");

    if (UI::Button("Start device flow")) GH_StartDeviceFlow();
    if (g_ghUserCode.Length > 0) {
        UI::Text("\\$fe1 code: " + g_ghUserCode + "  at  " + g_ghUri + " (also copied to clipboard)");
    }
    if (S_GHToken.Length > 0) {
        UI::Text("\\$8b8 token present (" + S_GHToken.Length + " chars)");
    }

    UI::Separator();
    UI::BeginDisabled(S_GHToken.Length == 0);
    if (UI::Button("Who am I?")) GH_WhoAmI();
    UI::SameLine();
    if (UI::Button("List my repos (up to 5)")) GH_ListRepos();
    UI::EndDisabled();

    if (g_ghLogin.Length > 0) {
        UI::Text("login: " + g_ghLogin);
    }

    RenderPhaseALog();
}
