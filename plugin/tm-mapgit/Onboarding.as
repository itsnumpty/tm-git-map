// Onboarding.as — the first-run walkthrough (also reopenable from the Openplanet menu and
// Settings) and the per-map "getting started" checklist shown on Home until a map is shared.

[Setting hidden]
bool S_OnboardingDone = false;

bool g_mgOnbOpen = false;
int g_mgOnbStep = 0;
UI::Font@ g_mgHeadingFont = null;
UI::Font@ g_mgSubheadingFont = null;

const int MG_ONB_WELCOME = 0;
const int MG_ONB_NAME = 1;
const int MG_ONB_GITHUB = 2;
const int MG_ONB_HOWTO = 3;
const int MG_ONB_DONE = 4;
const int MG_ONB_STEPS = 5;

void MG_LoadFonts() {
    @g_mgHeadingFont = UI::LoadFont("DroidSans-Bold.ttf", 24);
    @g_mgSubheadingFont = UI::LoadFont("DroidSans-Bold.ttf", 17);
}

void MG_Heading(const string&in text) {
    if (g_mgHeadingFont !is null) UI::PushFont(g_mgHeadingFont);
    UI::Text(text);
    if (g_mgHeadingFont !is null) UI::PopFont();
}

void MG_Subheading(const string&in text) {
    if (g_mgSubheadingFont !is null) UI::PushFont(g_mgSubheadingFont);
    UI::Text(text);
    if (g_mgSubheadingFont !is null) UI::PopFont();
}

void MG_OnboardingStart() {
    g_windowVisible = true;
    g_mgOnbOpen = true;
    g_mgOnbStep = MG_ONB_WELCOME;
}

void MG_OnboardingFinish() {
    g_mgOnbOpen = false;
    S_OnboardingDone = true;
    S_Page = MG_PAGE_HOME;
}

// ------------------------- walkthrough -------------------------

void RenderOnboarding() {
    // progress dots
    string dots = "";
    for (int i = 0; i < MG_ONB_STEPS; i++) {
        dots += (i == g_mgOnbStep ? "\\$fd0" : (i < g_mgOnbStep ? "\\$8f0" : "\\$555")) + Icons::Circle + " ";
    }
    UI::Text(dots);
    UI::SameLine();
    UI::TextDisabled("Step " + (g_mgOnbStep + 1) + " of " + MG_ONB_STEPS);
    UI::Dummy(vec2(0, 6));

    float navH = UI::GetFrameHeight() + 12.0;
    if (UI::BeginChild("mapgit-onb-body", vec2(0, -navH))) {
        if (g_mgOnbStep == MG_ONB_WELCOME) RenderOnbWelcome();
        else if (g_mgOnbStep == MG_ONB_NAME) RenderOnbName();
        else if (g_mgOnbStep == MG_ONB_GITHUB) RenderOnbGitHub();
        else if (g_mgOnbStep == MG_ONB_HOWTO) RenderOnbHowTo();
        else RenderOnbDone();
    }
    UI::EndChild();

    UI::Separator();
    if (g_mgOnbStep > 0) {
        if (UI::Button("Back")) g_mgOnbStep--;
        UI::SameLine();
    }
    if (g_mgOnbStep < MG_ONB_DONE) {
        string nextLabel = "Next " + Icons::ArrowRight;
        if (g_mgOnbStep == MG_ONB_WELCOME) nextLabel = "Get started " + Icons::ArrowRight;
        if (g_mgOnbStep == MG_ONB_GITHUB && g_ghToken.Length == 0) nextLabel = "Skip for now " + Icons::ArrowRight;
        if (UI::Button(nextLabel)) g_mgOnbStep++;
        UI::SameLine();
        UI::TextDisabled("  ");
        UI::SameLine();
        if (UI::Button("Close setup")) MG_OnboardingFinish();
        if (UI::IsItemHovered()) UI::SetTooltip("You can reopen this from Settings, or the MapGit entry in the Openplanet menu.");
    } else {
        if (UI::Button(Icons::Check + " Finish")) MG_OnboardingFinish();
    }
}

void RenderOnbWelcome() {
    MG_Heading("Welcome to MapGit");
    UI::TextWrapped("MapGit lets you build Trackmania maps together with friends, without sending files back and forth "
                    "or losing anyone's work.");
    UI::Dummy(vec2(0, 8));
    MG_Feature(Icons::History, "Every version is kept",
        "Each time you share, MapGit keeps a copy. You can go back to any of them.");
    MG_Feature(Icons::Github, "Share with collaborators",
        "Maps are stored in a private GitHub repository that only you and the people you invite can see.");
    MG_Feature(Icons::Magic, "Work at the same time",
        "If you both edit the map, MapGit combines your changes automatically.");
    MG_Feature(Icons::Eye, "See differences in 3D",
        "When you both changed the same spot, MapGit shows both versions in the editor and you pick one.");
    UI::Dummy(vec2(0, 8));
    UI::TextDisabled("Setup takes about a minute. You'll need a free GitHub account to share maps.");
}

void MG_Feature(const string&in icon, const string&in title, const string&in body) {
    UI::Text("\\$fd0" + icon);
    UI::SameLine();
    MG_Subheading(title);
    UI::Indent(24);
    UI::TextWrapped("\\$bbb" + body);
    UI::Unindent(24);
    UI::Dummy(vec2(0, 4));
}

void RenderOnbName() {
    MG_Heading("What should we call you?");
    UI::TextWrapped("This name appears next to every version you share, so your collaborators know who changed what.");
    UI::Dummy(vec2(0, 8));
    bool changed;
    UI::SetNextItemWidth(260);
    S_MGAuthor = UI::InputText("Your name##onb-author", S_MGAuthor, changed);
    if (S_MGAuthor.Length == 0) {
        UI::TextDisabled(g_ghLogin.Length > 0 ? "Leave empty to use your GitHub name (" + g_ghLogin + ")."
                                               : "Leave empty to use your GitHub name once you connect.");
    }
}

void RenderOnbGitHub() {
    MG_Heading("Connect GitHub");
    UI::TextWrapped("GitHub is a free website for storing projects. MapGit uses it as the shared home for your maps: "
                    "each map gets its own private repository, and only people you invite can see it.");
    UI::Dummy(vec2(0, 8));
    RenderGitHubAuthSection();
    UI::Dummy(vec2(0, 8));
    if (g_ghToken.Length == 0) {
        UI::TextDisabled("MapGit only asks for access to repositories. It never sees your password.");
        UI::TextDisabled("You can skip this and connect later from the GitHub page. Versions are still kept on your PC.");
    } else {
        UI::TextWrapped("\\$8f0You're all set." + "\\$z MapGit will create a private repository the first time you share a map.");
    }
}

void RenderOnbHowTo() {
    MG_Heading("How it works");
    UI::Dummy(vec2(0, 4));
    MG_Feature(Icons::Cloud, "Share",
        "Saves what you've built as a new version and sends it to your collaborators. Add a short note like \"added the loop\".");
    MG_Feature(Icons::Download, "Update",
        "Brings in what your collaborators shared. If you both changed the map, MapGit combines the two for you.");
    MG_Feature(Icons::MapMarker, "Differences",
        "If you both changed the same block, MapGit shows yours in green and theirs as a red ghost in the editor. "
        "Pick Keep yours, Use theirs, or keep both. Then Apply & Share.");
    MG_Feature(Icons::History, "History and checkpoints",
        "Every shared version is listed on the History page. Name important moments as checkpoints and go back any time.");
    MG_Feature(Icons::User, "Your collaborators",
        "Invite collaborators to the map's repository on GitHub. They install MapGit, connect their own GitHub, "
        "and open \"Join a map\" to download it straight into their editor.");
}

void RenderOnbDone() {
    MG_Heading("You're ready");
    UI::TextWrapped("Open any map in the editor and the MapGit window will guide you through sharing it for the first time.");
    UI::TextWrapped("Did someone invite you to collaborate on their map? Open \\$fffJoin a map\\$z in the sidebar.");
    UI::Dummy(vec2(0, 8));
    UI::Text(Icons::Check + "  Name: \\$fff" + MG_AuthorName());
    if (g_ghToken.Length > 0) {
        UI::Text("\\$8f0" + Icons::Check + "\\$z  GitHub: connected" + (g_ghLogin.Length > 0 ? " as \\$fff" + g_ghLogin : ""));
    } else {
        UI::Text("\\$f84" + Icons::Times + "\\$z  GitHub: not connected yet (you can do this from the GitHub page)");
    }
    UI::Dummy(vec2(0, 8));
    UI::TextDisabled(Icons::LightbulbO + " Tip: collapse this window with the arrow in its title bar. It still shows what's happening.");
    UI::TextDisabled(Icons::QuestionCircle + " Reopen this walkthrough from Settings, or Plugins > MapGit > Setup & walkthrough.");
}

// ------------------------- per-map getting started -------------------------

string g_mgGsDir = "";
bool g_mgGsDismissed = false;

string MG_GsFlagPath(const string&in repoDir) {
    return repoDir + "/getting-started-done";
}

bool MG_GettingStartedDismissed(const string&in repoDir) {
    if (repoDir != g_mgGsDir) {
        g_mgGsDir = repoDir;
        g_mgGsDismissed = IO::FileExists(MG_GsFlagPath(repoDir));
    }
    return g_mgGsDismissed;
}

void MG_DismissGettingStarted(const string&in repoDir) {
    if (IO::FolderExists(repoDir)) MG_WriteTextFile(MG_GsFlagPath(repoDir), "1");
    g_mgGsDir = repoDir;
    g_mgGsDismissed = true;
}

// Whether Home should show the checklist instead of (or above) the normal controls.
bool MG_ShouldShowGettingStarted(CGameCtnChallenge@ map) {
    if (map is null) return false;
    if (!MG_MapIsSaved(map)) return true;
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
    if (MG_CachedRemote(repoDir).Length == 0) return !IO::FolderExists(repoDir) || g_mgRepoTip.Length == 0;
    return !MG_GettingStartedDismissed(repoDir);
}

void MG_StepRow(int n, bool done, bool active, const string&in title) {
    string mark = done ? "\\$8f0" + Icons::Check : (active ? "\\$fd0" + Icons::ArrowRight : "\\$555" + Icons::Circle);
    string col = done ? "\\$888" : (active ? "\\$fff" : "\\$777");
    UI::Text(mark + "  " + col + n + ". " + title);
}

void RenderGettingStarted(CGameCtnChallenge@ map) {
    bool saved = MG_MapIsSaved(map);
    bool connected = g_ghToken.Length > 0;
    string repoDir = saved ? MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map)) : "";
    string remote = saved ? MG_CachedRemote(repoDir) : "";
    bool shared = remote.Length > 0;

    MG_Heading(shared ? "Your map is shared" : "Let's get this map shared");
    UI::TextDisabled(shared ? "One last thing: invite your collaborators." : "Three quick steps. MapGit does the technical bits for you.");
    UI::Dummy(vec2(0, 6));

    // 1. save
    MG_StepRow(1, saved, !saved, "Give the map a name and save it");
    if (!saved) {
        UI::Indent(28);
        RenderSaveNewMapCard(map);
        UI::Unindent(28);
        return;
    }

    // 2. github
    MG_StepRow(2, connected, !connected, "Connect GitHub (once per PC)");
    if (!connected) {
        UI::Indent(28);
        RenderGitHubAuthSection();
        UI::Dummy(vec2(0, 4));
        UI::TextDisabled("Not ready to share? You can still keep versions on this PC:");
        UI::BeginDisabled(g_mgRepoBusy);
        if (UI::Button(Icons::FloppyO + " Save a version on this PC")) {
            g_mgCommitMsg = "first version";
            startnew(MG_CommitCoro);
        }
        UI::EndDisabled();
        UI::Unindent(28);
        return;
    }

    // 3. first share
    MG_StepRow(3, shared, !shared, "Share it for the first time");
    if (!shared) {
        UI::Indent(28);
        UI::TextWrapped("This saves the map as its first version and creates a private repository called \\$fff"
                        + GH_DefaultRepoName(map) + "\\$z on your GitHub.");
        UI::BeginDisabled(g_mgRepoBusy || g_ghBusy);
        if (UI::Button(Icons::Cloud + " Share for the first time")) {
            g_mgShareNote = "first version";
            MG_ShareCoro();
        }
        UI::EndDisabled();
        if (g_mgRepoBusy || g_ghBusy) {
            UI::SameLine();
            UI::TextDisabled(Icons::Refresh + " working... (see Activity below)");
        }
        UI::Unindent(28);
        return;
    }

    // 4. team
    MG_StepRow(4, false, true, "Invite collaborators");
    UI::Indent(28);
    UI::TextWrapped("Add collaborators on GitHub using their GitHub username.");
    if (UI::Button(Icons::User + " Open the invite page on GitHub")) {
        OpenBrowserURL("https://github.com/" + remote + "/settings/access");
    }
    UI::TextWrapped("\\$bbbThen tell them to install MapGit and open \\$fffJoin a map\\$bbb. Your invite shows up there, "
                    "and one click downloads the map into their editor.");
    UI::Dummy(vec2(0, 4));
    UI::TextWrapped("\\$bbbFrom now on: press \\$fffShare\\$bbb when you've built something, and \\$fffUpdate\\$bbb to get what others shared.");
    if (UI::Button(Icons::Check + " Got it")) MG_DismissGettingStarted(repoDir);
    UI::Unindent(28);
    UI::Separator();
}
