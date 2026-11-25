// Media.as — MediaTracker (intro, in-game, end-race and ambiance clips).
// Clips live inside the map file, not the block/item manifest, so each version records
// a fingerprint of them ("media" in the commit json, "media" in extras.json on GitHub).
// Openplanet exposes clip structure and timing but not key values: the fingerprint sees
// clips/tracks/blocks/keys being added, removed, renamed or retimed, but not a camera key
// moved without changing its time.

string MG_MediaNum(float v) {
    return Text::Format("%.3f", v);
}

string MG_MediaClipSig(CGameCtnMediaClip@ clip) {
    if (clip is null) return "-";
    string s = string(clip.Name) + "{" + (clip.StopWhenRespawn ? "r" : "") + (clip.StopWhenLeave ? "l" : "") +
               (clip.TriggersBeforeRaceStart ? "b" : "");
    for (uint i = 0; i < clip.Tracks.Length; i++) {
        CGameCtnMediaTrack@ t = clip.Tracks[i];
        if (t is null) continue;
        s += "[" + string(t.Name) + (t.IsCycling ? "~" : "");
        for (uint j = 0; j < t.Blocks.Length; j++) {
            CGameCtnMediaBlock@ b = t.Blocks[j];
            if (b is null) continue;
            s += "(" + Reflection::TypeOf(b).Name + ":" + MG_MediaNum(b.Start) + "-" + MG_MediaNum(b.End);
            uint keys = b.GetKeysCount();
            for (uint k = 0; k < keys; k++) s += "," + MG_MediaNum(b.GetKeyTime(k));
            s += ")";
        }
        s += "]";
    }
    return s + "}";
}

string MG_MediaGroupSig(CGameCtnMediaClipGroup@ g) {
    if (g is null) return "-";
    string s = "";
    for (uint i = 0; i < g.Clips.Length; i++) s += MG_MediaClipSig(g.Clips[i]) + ";";
    return s;
}

bool MG_MediaIsEmpty(CGameCtnChallenge@ map) {
    if (map is null) return true;
    return map.ClipIntro is null && map.ClipAmbiance is null &&
           (map.ClipGroupInGame is null || map.ClipGroupInGame.Clips.Length == 0) &&
           (map.ClipGroupEndRace is null || map.ClipGroupEndRace.Clips.Length == 0);
}

string MG_MediaFingerprint(CGameCtnChallenge@ map) {
    if (map is null) return "";
    if (MG_MediaIsEmpty(map)) return "none";
    string s = "intro:" + MG_MediaClipSig(map.ClipIntro) +
               "|ingame:" + MG_MediaGroupSig(map.ClipGroupInGame) +
               "|end:" + MG_MediaGroupSig(map.ClipGroupEndRace) +
               "|amb:" + MG_MediaClipSig(map.ClipAmbiance);
    return Crypto::Sha256(s).SubStr(0, 16);
}

// Optional commit fields ("media", "items"); "" when absent on older commits.
string MG_ReadCommitExtra(const string&in repoDir, const string&in sha, const string&in field) {
    if (sha.Length == 0) return "";
    string text = MG_ReadTextFile(repoDir + "/commits/" + sha + ".json");
    if (text.Length == 0) return "";
    try {
        Json::Value@ j = Json::Parse(text);
        if (j is null || j.GetType() != Json::Type::Object || !j.HasKey(field)) return "";
        return string(j[field]);
    } catch {
        return "";
    }
}

// True when the live clips differ from the ones a version recorded. Versions saved before
// clip tracking carry no fingerprint: `unknownCounts` decides whether a map with clips then
// counts as changed (true where the answer just saves a new version, false where it would
// block the player).
bool MG_MediaChangedSince(CGameCtnChallenge@ map, const string&in repoDir, const string&in commitSha,
                          bool unknownCounts = true) {
    string recorded = MG_ReadCommitExtra(repoDir, commitSha, "media");
    if (recorded.Length == 0) return unknownCounts && !MG_MediaIsEmpty(map);
    return recorded != MG_MediaFingerprint(map);
}

// ------------------------- merge -------------------------

bool g_mgMediaTakeTheirs = false;

// 3-way decision on the clips. Takes theirs silently when only they changed them;
// raises a conflict when both sides did.
void MG_MergeMedia(const string&in repoDir, const string&in baseSha, const string&in oursSha, const string&in theirsSha) {
    g_mgMediaTakeTheirs = false;
    string b = MG_ReadCommitExtra(repoDir, baseSha, "media");
    string o = MG_ReadCommitExtra(repoDir, oursSha, "media");
    string t = MG_ReadCommitExtra(repoDir, theirsSha, "media");
    if (o.Length == 0 || t.Length == 0) {
        if (o != t) MG_Log("merge: clip info missing on an older version — keeping your MediaTracker clips");
        return;
    }
    if (t == o) return;
    if (b.Length > 0 && t == b) return;
    if (b.Length > 0 && o == b) {
        g_mgMediaTakeTheirs = true;
        g_mgAppliedChanges.InsertLast("take theirs: MediaTracker clips");
        return;
    }
    MGMergeConflict@ c = MGMergeConflict();
    c.kind = 7; c.section = "media"; c.key = "media";
    c.oursSummary = (o == "none") ? "No clips" : "Your clips";
    c.theirsSummary = (t == "none") ? "No clips" : "Their clips";
    c.baseSummary = b;
    g_mgConflicts.InsertLast(c);
}

// Copies the four clip slots from their version of the map into the open map.
// Their map file is loaded from a scratch copy under Maps/MapGit-temp.
bool MG_ApplyTheirsMedia(CGameCtnChallenge@ map, const string&in blobPath, const string&in blobSha) {
    if (map is null || !IO::FileExists(blobPath)) return false;
    string folderRel = "Maps/MapGit-temp";
    string rel = folderRel + "/theirs-" + blobSha.SubStr(0, 12) + ".Map.Gbx";
    try {
        IO::CreateFolder(IO::FromUserGameFolder(folderRel));
        MG_CopyFile(blobPath, IO::FromUserGameFolder(rel));
        CSystemFidsFolder@ folder = Fids::GetUserFolder(folderRel);
        if (folder !is null) Fids::UpdateTree(folder);
        CSystemFidFile@ fid = Fids::GetUser(rel);
        if (fid is null) { MG_Log("media: could not find the scratch copy of their map"); return false; }
        CGameCtnChallenge@ other = cast<CGameCtnChallenge>(Fids::Preload(fid));
        if (other is null) { MG_Log("media: could not load their map to read its clips"); return false; }
        @map.ClipIntro = other.ClipIntro;
        @map.ClipGroupInGame = other.ClipGroupInGame;
        @map.ClipGroupEndRace = other.ClipGroupEndRace;
        @map.ClipAmbiance = other.ClipAmbiance;
    } catch {
        MG_Log("media: copying their clips failed: " + getExceptionInfo());
        return false;
    }
    MG_Log("media: took their MediaTracker clips");
    return true;
}
