// Manifest.as — ManifestBuilder v1: live map -> canonical manifest JSON (schema 0.1 subset).
// Port of MapGit.Core MapFile.ExtractManifest + ManifestCanonicalizer + ManifestKeys.
// Verified API basis: docs/phase-a-report.md.

// ------------------------- data model -------------------------

class MGBlock {
    string key;
    string name;
    bool isFree;
    bool isGhost;
    bool isGround;
    int cx;
    int cy;
    int cz;
    int direction;
    int variant;      // = MobilIndex (verified: GBX.NET flags Variant; BlockInfoVariantIndex is a different engine concept)
    int subVariant;   // = MobilVariantIndex (GBX.NET flags SubVariant)
    string color;
    string lmQual;
    bool hasFree;
    vec3 freePos;
    vec3 freeRot;
    bool hasSkin;
    bool hasSkinFile;
    bool hasSkinUrl;
    string skinFile;
    string skinUrl;
    bool hasWaypointProps;
    string contentJson; // full serialization (total-sort tiebreaker, Phase 0 finding F15)

    int opCmp(const MGBlock&in other) {
        if (key != other.key) return key < other.key ? -1 : 1;
        if (name != other.name) return name < other.name ? -1 : 1;
        if (contentJson != other.contentJson) return contentJson < other.contentJson ? -1 : 1;
        return 0;
    }
}

class MGItem {
    string key;
    string itemModel;
    vec3 position;
    vec3 rotation;
    float scale;
    string color;
    string lmQual;
    bool hasWaypointProps;
    string contentJson;

    int opCmp(const MGItem&in other) {
        if (key != other.key) return key < other.key ? -1 : 1;
        if (itemModel != other.itemModel) return itemModel < other.itemModel ? -1 : 1;
        if (contentJson != other.contentJson) return contentJson < other.contentJson ? -1 : 1;
        return 0;
    }
}

class MGMapInfo {
    string name;
    string comments;
    string collection;
    string decoration;
    string titleId;
    string authorLogin;
    string mapType;
    string mapStyle;
    int authorTimeMs;
    int goldTimeMs;
    int silverTimeMs;
    int bronzeTimeMs;
    int authorScore;  // -1 = null (JSON null)
    int cost;
    string playMode;  // "" = not extractable in-game
    int nbLaps;
    bool isLapRace;
    int sizeX;
    int sizeY;
    int sizeZ;
    bool createdWithSimpleEditor;
    bool hasGhostBlocks;
}

class MGEmbeddedEntry {
    string name;
    string fingerprint; // TolerantHash of entry bytes

    int opCmp(const MGEmbeddedEntry&in other) {
        if (name != other.name) return name < other.name ? -1 : 1;
        if (fingerprint != other.fingerprint) return fingerprint < other.fingerprint ? -1 : 1;
        return 0;
    }
}

class MGManifest {
    MGMapInfo@ mapInfo;
    array<MGBlock> blocks;
    array<MGItem> items;
    int embeddedEntryCount = 0;
    array<MGEmbeddedEntry> embeddedEntries;
}

// ------------------------- keys (port of ManifestKeys) -------------------------

// Fixed-point rounding away from zero with exactly `d` decimals (F3/F2, invariant culture).
// Zero is never negative ("0.00", not "-0.00") — file-saved floats carry -1e-7 noise where
// in-game memory holds exact 0; both sides must format identically.
string MG_Num(float v, int d) {
    int scale = (d == 3) ? 1000 : 100;
    int iv = int(Math::Floor(Math::Abs(v) * float(scale) + 0.5));
    string sign = (v < 0.0 && iv != 0) ? "-" : "";
    int ip = iv / scale;
    int fp = iv % scale;
    string fps = "" + fp;
    while (int(fps.Length) < d) fps = "0" + fps;
    return sign + ip + "." + fps;
}

string MG_Fmt(const vec3&in v, int d) {
    return MG_Num(v.x, d) + "," + MG_Num(v.y, d) + "," + MG_Num(v.z, d);
}

// ------------------------- extraction -------------------------

// CGameCtnBlock::EMapElemColor / EMapElemLightmapQuality (Openplanet.h; GBX.NET
// DifficultyColor/LightmapQuality emit the same names via ToString()).
string[] g_mgColorNames = { "Default", "White", "Green", "Blue", "Red", "Black" };
string[] g_mgLmNames = { "Normal", "High", "VeryHigh", "Highest", "Low", "VeryLow", "Lowest" };

string MG_ColorName(int c) {
    if (c >= 0 && c < int(g_mgColorNames.Length)) return g_mgColorNames[c];
    return "" + c;
}

string MG_LmName(int q) {
    if (q >= 0 && q < int(g_mgLmNames.Length)) return g_mgLmNames[q];
    return "" + q;
}

MGBlock MG_ToBlock(CGameCtnBlock@ b) {
    MGBlock r;
    r.name = b.DescId.GetName();
    r.isGhost = b.IsGhostBlock();
    r.isGround = b.IsGround;
    r.cx = b.Coord.x;
    r.cy = b.Coord.y;
    r.cz = b.Coord.z;
    r.direction = int(b.Direction);
    // Variant mapping settled by probe round 1: the file's flags-based Variant/SubVariant
    // (what GBX.NET and the manifest use) live in MobilIndex/MobilVariantIndex in-game.
    // BlockInfoVariantIndex reads 0 for baked blocks — do not use it.
    r.variant = b.MobilIndex;
    r.subVariant = b.MobilVariantIndex;
    r.color = MG_ColorName(int(b.MapElemColor));
    r.lmQual = MG_LmName(int(b.MapElemLmQuality));
    r.hasSkin = b.Skin !is null;
    r.hasWaypointProps = b.WaypointSpecialProperty !is null;

    // Block skins ARE extractable in-game: CGameCtnBlockSkin.PackDesc is a
    // CSystemPackDesc with FileName (wstring) and Url (string).
    r.hasSkinFile = false;
    r.hasSkinUrl = false;
    r.skinFile = "";
    r.skinUrl = "";
    if (b.Skin !is null && b.Skin.PackDesc !is null) {
        r.skinFile = b.Skin.PackDesc.FileName; // wstring -> string
        r.skinUrl = b.Skin.PackDesc.Url;
        r.hasSkinFile = r.skinFile.Length > 0;
        r.hasSkinUrl = r.skinUrl.Length > 0;
    }

    Editor::BlockSpec@ spec = Editor::MakeBlockSpec(b);
    if (spec !is null && spec.isFree) {
        r.isFree = true;
        r.hasFree = true;
        // E++ reads raw engine fields: in-memory free pos is +56 (Stadium2020 7-cell base
        // offset) above the file's AbsolutePositionInMap, and spec.pyr is (pitch, yaw,
        // roll) while the manifest wants (yaw, pitch, roll). Both verified empirically
        // against the C# engine manifest (Phase B conformance round 1).
        r.freePos = spec.pos - vec3(0, 56, 0);
        r.freeRot = vec3(spec.pyr.y, spec.pyr.x, spec.pyr.z);
        r.key = "f:" + MG_Fmt(r.freePos, 3) + "|" + MG_Fmt(r.freeRot, 2) + (r.isGhost ? "|gh" : "");
    } else {
        r.key = "b:" + r.cx + "," + r.cy + "," + r.cz + (r.isGhost ? "#gh" : "");
    }

    r.contentJson = MG_BlockJson(r);
    return r;
}

MGItem MG_ToItem(CGameCtnAnchoredObject@ a) {
    MGItem r;
    r.itemModel = (a.ItemModel is null) ? "" : a.ItemModel.Id.GetName();
    r.position = a.AbsolutePositionInMap;
    r.rotation = vec3(a.Yaw, a.Pitch, a.Roll); // in-game items expose three floats, not YawPitchRoll
    r.scale = a.Scale;
    r.color = MG_ColorName(int(a.MapElemColor));
    r.lmQual = MG_LmName(int(a.MapElemLmQuality));
    r.hasWaypointProps = a.WaypointSpecialProperty !is null;
    r.key = "i:" + MG_Fmt(r.position, 3) + "|" + MG_Fmt(r.rotation, 2);
    r.contentJson = MG_ItemJson(r);
    return r;
}

MGMapInfo@ MG_ExtractMapInfo(CGameCtnChallenge@ map) {
    MGMapInfo@ mi = MGMapInfo();
    mi.name = map.MapName;
    mi.comments = map.Comments;
    // CGameCtnChallengeInfo (the MapInfo fid nod) carries the file-level metadata
    // the engine reads: collection id, author login, type/style, editor mode.
    mi.collection = map.MapInfo.CollectionName;
    mi.decoration = map.DecorationName; // challenge-nod member (not on ChallengeInfo)
    mi.titleId = map.TitleId.GetName();
    mi.authorLogin = map.MapInfo.AuthorLogin;
    mi.mapType = map.MapInfo.MapType;
    mi.mapStyle = map.MapInfo.MapStyle;
    mi.createdWithSimpleEditor = map.MapInfo.CreatedWithSimpleEditor;
    // ChallengeParameters (holds times/scores when the challenge header doesn't)
    CGameCtnChallengeParameters@ cp = map.ChallengeParameters;
    // authorScore: from ChallengeParameters when present
    mi.authorScore = -1; // -1 = null in JSON
    if (cp !is null) {
        mi.authorScore = int(cp.AuthorScore);
    }
    // cost: the C# header Cost corresponds to ChallengeInfo's CopperPrice
    mi.cost = map.MapInfo.CopperPrice;
    // playMode: file-format only (GBX.NET PlayMode enum, not on any in-game nod)
    mi.playMode = "";
    // hasGhostBlocks: no header flag in-game; compute from content
    mi.hasGhostBlocks = false;
    for (uint i = 0; i < map.Blocks.Length; i++) {
        if (map.Blocks[i].IsGhostBlock()) { mi.hasGhostBlocks = true; break; }
    }
    mi.authorTimeMs = map.TMObjective_AuthorTime;
    mi.goldTimeMs = map.TMObjective_GoldTime;
    mi.silverTimeMs = map.TMObjective_SilverTime;
    mi.bronzeTimeMs = map.TMObjective_BronzeTime;
    // header fields can be empty while ChallengeParameters holds the values
    if (cp !is null) {
        if (mi.authorTimeMs < 0) mi.authorTimeMs = int(cp.AuthorTime);
        if (mi.goldTimeMs < 0) mi.goldTimeMs = int(cp.GoldTime);
        if (mi.silverTimeMs < 0) mi.silverTimeMs = int(cp.SilverTime);
        if (mi.bronzeTimeMs < 0) mi.bronzeTimeMs = int(cp.BronzeTime);
    }
    mi.nbLaps = map.TMObjective_NbLaps;
    mi.isLapRace = map.TMObjective_IsLapRace;
    mi.sizeX = map.Size.x;
    mi.sizeY = map.Size.y;
    mi.sizeZ = map.Size.z;
    return mi;
}

uint g_mgDupesSkipped = 0;

MGManifest@ MG_BuildManifest(CGameCtnChallenge@ map) {
    MGManifest@ m = MGManifest();
    @m.mapInfo = MG_ExtractMapInfo(map);

    // Canonical block set (Phase A finding): map.Blocks (2845) + BakedBlocks minus
    // nod-identity dupes (grass double-references — same nods in both lists) = the
    // engine's flat file list. Dedup by handle identity, never by fields.
    for (uint i = 0; i < map.Blocks.Length; i++) {
        m.blocks.InsertLast(MG_ToBlock(map.Blocks[i]));
    }
    g_mgDupesSkipped = 0;
    for (uint j = 0; j < map.BakedBlocks.Length; j++) {
        CGameCtnBlock@ nb = map.BakedBlocks[j];
        bool dupe = false;
        for (uint i = 0; i < map.Blocks.Length; i++) {
            if (map.Blocks[i] is nb) { dupe = true; break; }
        }
        if (dupe) { g_mgDupesSkipped++; continue; }
        m.blocks.InsertLast(MG_ToBlock(nb));
    }

    for (uint i = 0; i < map.AnchoredObjects.Length; i++) {
        m.items.InsertLast(MG_ToItem(map.AnchoredObjects[i]));
    }

    // canonical sort (total: key, name, content) then deterministic "#2"/"#3" suffixes
    m.blocks.SortAsc();
    m.items.SortAsc();
    MG_SuffixBlocks(m.blocks);
    MG_SuffixItems(m.items);

    MG_FillEmbedded(m);
    return m;
}

// Enumerate CurrentMap_EmbeddedFiles via Fids and fingerprint each leaf.
void MG_FillEmbedded(MGManifest@ m) {
    m.embeddedEntries.RemoveRange(0, m.embeddedEntries.Length);
    m.embeddedEntryCount = 0;
    CSystemFidsFolder@ folder = MG_FindEmbeddedFolder();
    if (folder is null) return;
    try {
        MG_CollectEmbeddedLeaves(folder, "", m.embeddedEntries);
    } catch {
        MG_Log("manifest: embedded enum failed: " + getExceptionInfo());
        return;
    }
    m.embeddedEntries.SortAsc();
    m.embeddedEntryCount = int(m.embeddedEntries.Length);
}

CSystemFidsFolder@ MG_FindEmbeddedFolder() {
    string[] drives = { "fake", "user", "game", "programdata", "resource" };
    for (uint d = 0; d < drives.Length; d++) {
        CSystemFidsFolder@ candidate = MG_TryGetFidsFolder(drives[d], "CurrentMap_EmbeddedFiles");
        if (candidate !is null) return candidate;
    }
    CSystemFidsFolder@ viaMem = Fids::GetFakeFolder("MemoryTemp/CurrentMap_EmbeddedFiles");
    if (viaMem !is null) return viaMem;
    return null;
}

CSystemFidsFolder@ MG_TryGetFidsFolder(const string&in drive, const string&in path) {
    if (drive == "fake") return Fids::GetFakeFolder(path);
    if (drive == "user") return Fids::GetUserFolder(path);
    if (drive == "game") return Fids::GetGameFolder(path);
    if (drive == "programdata") return Fids::GetProgramDataFolder(path);
    if (drive == "resource") return Fids::GetResourceFolder(path);
    return null;
}

void MG_CollectEmbeddedLeaves(CSystemFidsFolder@ folder, const string&in prefix, array<MGEmbeddedEntry>@ outEntries) {
    try { Fids::UpdateTree(folder); } catch { }
    auto leaves = folder.Leaves;
    for (uint i = 0; i < leaves.Length; i++) {
        CSystemFidFile@ leaf = leaves[i];
        if (leaf is null) continue;
        string name = prefix + leaf.FileName;
        string fp = "";
        try {
            // Prefer extracting bytes when the Fid has an absolute path
            string full = leaf.FullFileName;
            if (full.Length > 0 && IO::FileExists(full)) {
                fp = MG_TolerantFingerprintFile(full);
            }
        } catch { }
        MGEmbeddedEntry e;
        e.name = name;
        e.fingerprint = fp;
        outEntries.InsertLast(e);
    }
    auto trees = folder.Trees;
    for (uint i = 0; i < trees.Length; i++) {
        string dir = trees[i].DirName;
        MG_CollectEmbeddedLeaves(trees[i], prefix + dir + "/", outEntries);
    }
}

// Stable string of "name:fingerprint" pairs for set equality in merge.
string MG_EmbeddedFingerprintSet(MGManifest@ m) {
    if (m is null) return "";
    string s = "";
    for (uint i = 0; i < m.embeddedEntries.Length; i++) {
        if (i > 0) s += "|";
        s += m.embeddedEntries[i].name + ":" + m.embeddedEntries[i].fingerprint;
    }
    if (s.Length == 0 && m.embeddedEntryCount > 0) return "count:" + m.embeddedEntryCount;
    return s;
}

// Best-effort: reload item paths named in theirs' embedded list so PlaceItems can resolve them.
void MG_EnsureTheirsEmbeddedAvailable(const string&in repoDir, const string&in theirsBlobSha, MGManifest@ theirsMan) {
    if (theirsMan is null || theirsMan.embeddedEntries.Length == 0) return;
    array<string> paths;
    for (uint i = 0; i < theirsMan.embeddedEntries.Length; i++) {
        string n = theirsMan.embeddedEntries[i].name;
        if (n.Length == 0) continue;
        paths.InsertLast(n);
    }
    if (paths.Length == 0) return;
    try {
        Editor::ReloadItemsAsync(paths);
        MG_Log("merge: requested ReloadItemsAsync for " + paths.Length + " embedded paths from theirs");
    } catch {
        MG_Log("merge: ReloadItemsAsync unavailable or failed: " + getExceptionInfo());
    }
    // Hint: custom items must be in the player's Items folder or already embedded in the live map.
    // Full zip install from the theirs .gbx blob is not available in-plugin (no LZO unpacker).
}

void MG_SuffixBlocks(array<MGBlock>@ arr) {
    uint i = 0;
    while (i < arr.Length) {
        string baseKey = arr[i].key;
        uint j = i + 1;
        int n = 1;
        while (j < arr.Length && arr[j].key == baseKey) {
            n++;
            arr[j].key = baseKey + "#" + n;
            j++;
        }
        i = j;
    }
}

void MG_SuffixItems(array<MGItem>@ arr) {
    uint i = 0;
    while (i < arr.Length) {
        string baseKey = arr[i].key;
        uint j = i + 1;
        int n = 1;
        while (j < arr.Length && arr[j].key == baseKey) {
            n++;
            arr[j].key = baseKey + "#" + n;
            j++;
        }
        i = j;
    }
}

// ------------------------- canonical JSON (C# CanonicalJson-compatible shape) -------------------------

string MG_JsonStr(const string&in s) {
    string r = s;
    r = r.Replace("\\", "\\\\");
    r = r.Replace("\"", "\\\"");
    return "\"" + r + "\"";
}

string MG_F(float v) {
    if (v == Math::Floor(v) && Math::Abs(v) < 9000000.0) return "" + int64(v);
    return "" + v; // v1: structural comparison; byte-exact float formatting is a v2 item
}

string MG_Vec3Json(const vec3&in v) {
    return "{\"x\":" + MG_F(v.x) + ",\"y\":" + MG_F(v.y) + ",\"z\":" + MG_F(v.z) + "}";
}

string MG_BlockJson(const MGBlock&in b) {
    return "{\"key\":" + MG_JsonStr(b.key) +
        ",\"name\":" + MG_JsonStr(b.name) +
        ",\"isFree\":" + (b.isFree ? "true" : "false") +
        ",\"isGhost\":" + (b.isGhost ? "true" : "false") +
        ",\"isGround\":" + (b.isGround ? "true" : "false") +
        ",\"isClip\":false,\"isPillar\":false" + // file-format-only flags (GBX.NET bits 13/14, no in-game members)
        ",\"coord\":{\"x\":" + b.cx + ",\"y\":" + b.cy + ",\"z\":" + b.cz + "}" +
        ",\"direction\":" + b.direction +
        ",\"variant\":" + b.variant +
        ",\"subVariant\":" + b.subVariant +
        ",\"color\":\"" + b.color + "\"" +
        ",\"lightmapQuality\":\"" + b.lmQual + "\"" +
        ",\"freePosition\":" + (b.hasFree ? MG_Vec3Json(b.freePos) : "null") +
        ",\"freeRotation\":" + (b.hasFree ? MG_Vec3Json(b.freeRot) : "null") +
        ",\"hasSkin\":" + (b.hasSkin ? "true" : "false") +
        ",\"skinFile\":" + (b.hasSkinFile ? MG_JsonStr(b.skinFile) : "null") +
        ",\"skinUrl\":" + (b.hasSkinUrl ? MG_JsonStr(b.skinUrl) : "null") +
        ",\"hasWaypointProps\":" + (b.hasWaypointProps ? "true" : "false") +
        ",\"decalId\":null,\"hasMacroblockRef\":false}"; // file-format-only (no in-game members)
}

string MG_ItemJson(const MGItem&in i) {
    return "{\"key\":" + MG_JsonStr(i.key) +
        ",\"itemModel\":" + MG_JsonStr(i.itemModel) +
        ",\"position\":" + MG_Vec3Json(i.position) +
        ",\"rotation\":" + MG_Vec3Json(i.rotation) +
        ",\"scale\":" + MG_F(i.scale) +
        ",\"pivot\":null" + // file-format-only (no PivotPosition on in-game CGameCtnAnchoredObject)
        ",\"color\":\"" + i.color + "\"" +
        ",\"lightmapQuality\":\"" + i.lmQual + "\"" +
        ",\"hasSkin\":false,\"skinFile\":null,\"skinUrl\":null" + // no PackDesc on in-game CGameCtnAnchoredObject
        ",\"hasWaypointProps\":" + (i.hasWaypointProps ? "true" : "false") + "}";
}

string MG_TimeJson(int ms) {
    return (ms < 0) ? "null" : ("" + ms);
}

string MG_MapInfoJson(MGMapInfo@ mi) {
    return "{\"name\":" + MG_JsonStr(mi.name) +
        ",\"comments\":" + MG_JsonStr(mi.comments) +
        ",\"authorLogin\":" + MG_JsonStr(mi.authorLogin) +
        ",\"collection\":" + MG_JsonStr(mi.collection) +
        ",\"decoration\":" + MG_JsonStr(mi.decoration) +
        ",\"titleId\":" + MG_JsonStr(mi.titleId) +
        ",\"mapType\":" + MG_JsonStr(mi.mapType) +
        ",\"mapStyle\":" + MG_JsonStr(mi.mapStyle) +
        ",\"authorTimeMs\":" + MG_TimeJson(mi.authorTimeMs) +
        ",\"goldTimeMs\":" + MG_TimeJson(mi.goldTimeMs) +
        ",\"silverTimeMs\":" + MG_TimeJson(mi.silverTimeMs) +
        ",\"bronzeTimeMs\":" + MG_TimeJson(mi.bronzeTimeMs) +
        ",\"authorScore\":" + (mi.authorScore < 0 ? "null" : "" + mi.authorScore) +
        ",\"nbLaps\":" + mi.nbLaps +
        ",\"isLapRace\":" + (mi.isLapRace ? "true" : "false") +
        ",\"playMode\":" + MG_JsonStr(mi.playMode) + // "" until the GBX PlayMode enum surfaces in-game
        ",\"cost\":" + mi.cost +
        ",\"size\":{\"x\":" + mi.sizeX + ",\"y\":" + mi.sizeY + ",\"z\":" + mi.sizeZ + "}" +
        ",\"createdWithSimpleEditor\":" + (mi.createdWithSimpleEditor ? "true" : "false") +
        ",\"hasGhostBlocks\":" + (mi.hasGhostBlocks ? "true" : "false") + "}";
}

void MG_WriteManifest(MGManifest@ m, const string&in path) {
    IO::File f(path, IO::FileMode::Write);
    f.Write("{\"schemaVersion\":\"0.1\",\"mapInfo\":");
    f.Write(MG_MapInfoJson(m.mapInfo));
    f.Write(",\"blocks\":[");
    for (uint i = 0; i < m.blocks.Length; i++) {
        if (i > 0) f.Write(",");
        f.Write(MG_BlockJson(m.blocks[i]));
    }
    f.Write("],\"items\":[");
    for (uint i = 0; i < m.items.Length; i++) {
        if (i > 0) f.Write(",");
        f.Write(MG_ItemJson(m.items[i]));
    }
    f.Write("],\"embedded\":{\"entryCount\":" + m.embeddedEntryCount + ",\"entries\":[");
    for (uint i = 0; i < m.embeddedEntries.Length; i++) {
        if (i > 0) f.Write(",");
        f.Write("{\"name\":" + MG_JsonStr(m.embeddedEntries[i].name) +
                ",\"fingerprint\":" + MG_JsonStr(m.embeddedEntries[i].fingerprint) + "}");
    }
    f.Write("]}}");
    f.Close();
}

// ------------------------- variant probe -------------------------

// Dumps every block's variant-related fields (manifest key joinable) so the engine
// manifest can settle which in-game field carries the file's flags-based Variant
// (baked blocks reset BlockInfoVariantIndex to 0 in memory — Phase B open question).
void MG_VariantProbe() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("no map open"); return; }
    string path = IO::FromStorageFolder("variant-probe.csv");
    IO::File f(path, IO::FileMode::Write);
    f.WriteLine("source,key,name,variant,mobilVariant,mobilIx,isFree,isGhost,cx,cy,cz");
    uint n = 0;
    for (uint pass = 0; pass < 2; pass++) {
        bool baked = pass == 1;
        uint len = baked ? map.BakedBlocks.Length : map.Blocks.Length;
        for (uint i = 0; i < len; i++) {
            CGameCtnBlock@ b = baked ? map.BakedBlocks[i] : map.Blocks[i];
            Editor::BlockSpec@ spec = Editor::MakeBlockSpec(b);
            bool free = spec !is null && spec.isFree;
            bool ghost = b.IsGhostBlock();
            string k;
            if (free) {
                vec3 pos = spec.pos - vec3(0, 56, 0);
                vec3 rot = vec3(spec.pyr.y, spec.pyr.x, spec.pyr.z);
                k = "f:" + MG_Fmt(pos, 3) + "|" + MG_Fmt(rot, 2) + (ghost ? "|gh" : "");
            } else {
                k = "b:" + b.Coord.x + "," + b.Coord.y + "," + b.Coord.z + (ghost ? "#gh" : "");
            }
            f.WriteLine((baked ? "bk" : "b") + ",\"" + k + "\"," + b.DescId.GetName() +
                "," + b.BlockInfoVariantIndex + "," + b.MobilVariantIndex + "," + b.MobilIndex +
                "," + (free ? 1 : 0) + "," + (ghost ? 1 : 0) +
                "," + b.Coord.x + "," + b.Coord.y + "," + b.Coord.z);
            n++;
        }
    }
    f.Close();
    MG_Log("variant probe: " + n + " blocks -> " + path);
}

// ------------------------- UI -------------------------

string g_mgLastSummary = "(manifest not built yet)";

void RenderManifestTab() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) {
        UI::Text("Open the map editor to use MapGit.");
        return;
    }
    UI::Text("ManifestBuilder v1 — live map → canonical manifest (schema 0.1 subset)");
    if (UI::Button("Build manifest")) MG_BuildAndWrite();
    UI::SameLine();
    if (UI::Button("Variant probe (CSV)")) MG_VariantProbe();
    UI::Separator();
    UI::TextWrapped(g_mgLastSummary);
    UI::Separator();
    UI::TextDisabled("v1 gaps (structural compare only): isClip/isPillar/subVariant, skins, " +
        "decals, macroblock refs, item pivot, most mapInfo fields, embedded entries. " +
        "Byte-exact JSON + hash equality is a v2 item.");
}

void MG_BuildAndWrite() {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("no map open"); return; }
    MG_Log("building manifest v1 from '" + map.MapName + "'...");
    MGManifest@ m = MG_BuildManifest(map);
    string path = IO::FromStorageFolder("manifest-current.json");
    MG_WriteManifest(m, path);
    g_mgLastSummary = "blocks: " + m.blocks.Length + " (baked dupes skipped: " + g_mgDupesSkipped + ")\n" +
        "items: " + m.items.Length + "\n" +
        "embedded: " + m.embeddedEntryCount + " entries (TolerantHash port pending)\n" +
        "written: " + path;
    MG_Log("blocks " + m.blocks.Length + " (dupes skipped " + g_mgDupesSkipped + "), items " +
        m.items.Length + " -> " + path);
}
