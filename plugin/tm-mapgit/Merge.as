// Merge.as — Phase D: 3-way merge engine (port of MapGit.Core ThreeWayMerge +
// ManifestDiff), manifest reader, merge-base, live apply via E++, and the merge UI.
//
// Semantics (faithful to the C# reference): changes base->theirs are applied onto
// ours; anywhere ours also diverged from base becomes a conflict. Conflicts are
// resolved ours/theirs/both/none; a completed merge applies to the LIVE map,
// verifies (rebuilt manifest must hash-match the computed result, else restore),
// and lands as a two-parent commit.

// ------------------------- manifest reader (store -> MGManifest) -------------------------

MGBlock MG_BlockFromJson(Json::Value@ blk) {
    MGBlock b;
    b.key = blk["key"];
    b.name = blk["name"];
    b.isFree = bool(blk["isFree"]);
    b.isGhost = bool(blk["isGhost"]);
    b.isGround = bool(blk["isGround"]);
    b.cx = int(blk["coord"]["x"]);
    b.cy = int(blk["coord"]["y"]);
    b.cz = int(blk["coord"]["z"]);
    b.direction = int(blk["direction"]);
    b.variant = int(blk["variant"]);
    b.subVariant = int(blk["subVariant"]);
    b.color = blk["color"];
    b.lmQual = blk["lightmapQuality"];
    b.hasFree = blk.HasKey("freePosition") && blk["freePosition"].GetType() != Json::Type::Null;
    if (b.hasFree) {
        b.freePos = vec3(float(blk["freePosition"]["x"]), float(blk["freePosition"]["y"]), float(blk["freePosition"]["z"]));
        b.freeRot = vec3(float(blk["freeRotation"]["x"]), float(blk["freeRotation"]["y"]), float(blk["freeRotation"]["z"]));
    }
    b.hasSkin = bool(blk["hasSkin"]);
    b.hasWaypointProps = bool(blk["hasWaypointProps"]);
    return b;
}

MGItem MG_ItemFromJson(Json::Value@ itm) {
    MGItem i;
    i.key = itm["key"];
    i.itemModel = itm["itemModel"];
    i.position = vec3(float(itm["position"]["x"]), float(itm["position"]["y"]), float(itm["position"]["z"]));
    i.rotation = vec3(float(itm["rotation"]["x"]), float(itm["rotation"]["y"]), float(itm["rotation"]["z"]));
    i.scale = float(itm["scale"]);
    i.color = itm["color"];
    i.lmQual = itm["lightmapQuality"];
    i.hasWaypointProps = bool(itm["hasWaypointProps"]);
    return i;
}

MGMapInfo@ MG_MapInfoFromJson(Json::Value@ mi) {
    MGMapInfo@ r = MGMapInfo();
    r.name = mi["name"];
    r.comments = mi["comments"];
    r.collection = mi["collection"];
    r.decoration = mi["decoration"];
    r.titleId = mi["titleId"];
    r.authorLogin = mi["authorLogin"];
    r.mapType = mi["mapType"];
    r.mapStyle = mi["mapStyle"];
    r.authorTimeMs = mi.HasKey("authorTimeMs") && mi["authorTimeMs"].GetType() != Json::Type::Null ? int(mi["authorTimeMs"]) : -1;
    r.goldTimeMs = mi.HasKey("goldTimeMs") && mi["goldTimeMs"].GetType() != Json::Type::Null ? int(mi["goldTimeMs"]) : -1;
    r.silverTimeMs = mi.HasKey("silverTimeMs") && mi["silverTimeMs"].GetType() != Json::Type::Null ? int(mi["silverTimeMs"]) : -1;
    r.bronzeTimeMs = mi.HasKey("bronzeTimeMs") && mi["bronzeTimeMs"].GetType() != Json::Type::Null ? int(mi["bronzeTimeMs"]) : -1;
    r.nbLaps = int(mi["nbLaps"]);
    r.isLapRace = bool(mi["isLapRace"]);
    r.sizeX = int(mi["size"]["x"]);
    r.sizeY = int(mi["size"]["y"]);
    r.sizeZ = int(mi["size"]["z"]);
    r.createdWithSimpleEditor = bool(mi["createdWithSimpleEditor"]);
    return r;
}

MGManifest@ MG_ReadManifest(const string&in path) {
    string text = MG_ReadTextFile(path);
    if (text.Length == 0) return null;
    try {
        Json::Value@ j = Json::Parse(text);
        if (j is null) return null;
        MGManifest@ m = MGManifest();
        @m.mapInfo = MG_MapInfoFromJson(j["mapInfo"]);
        Json::Value@ blocks = j["blocks"];
        for (uint i = 0; i < blocks.Length; i++) {
            m.blocks.InsertLast(MG_BlockFromJson(blocks[i]));
        }
        Json::Value@ items = j["items"];
        for (uint i = 0; i < items.Length; i++) {
            m.items.InsertLast(MG_ItemFromJson(items[i]));
        }
        m.embeddedEntryCount = int(j["embedded"]["entryCount"]);
        return m;
    } catch {
        MG_Log("merge: manifest parse failed: " + getExceptionInfo());
        return null;
    }
}

// ------------------------- equality (C# JsonNode.DeepEquals equivalent) -------------------------

bool MG_Vec3Eq(const vec3&in a, const vec3&in b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

bool MG_BlockEquals(const MGBlock&in a, const MGBlock&in b) {
    if (a.key != b.key || a.name != b.name) return false;
    if (a.isFree != b.isFree || a.isGhost != b.isGhost || a.isGround != b.isGround) return false;
    if (a.cx != b.cx || a.cy != b.cy || a.cz != b.cz) return false;
    if (a.direction != b.direction || a.variant != b.variant || a.subVariant != b.subVariant) return false;
    if (a.color != b.color || a.lmQual != b.lmQual) return false;
    if (a.hasFree != b.hasFree) return false;
    if (a.hasFree && (!MG_Vec3Eq(a.freePos, b.freePos) || !MG_Vec3Eq(a.freeRot, b.freeRot))) return false;
    if (a.hasSkin != b.hasSkin || a.hasWaypointProps != b.hasWaypointProps) return false;
    return true;
}

bool MG_ItemEquals(const MGItem&in a, const MGItem&in b) {
    if (a.key != b.key || a.itemModel != b.itemModel) return false;
    if (!MG_Vec3Eq(a.position, b.position) || !MG_Vec3Eq(a.rotation, b.rotation)) return false;
    if (a.scale != b.scale || a.color != b.color || a.lmQual != b.lmQual) return false;
    if (a.hasWaypointProps != b.hasWaypointProps) return false;
    return true;
}

// ------------------------- keyed diff (base -> other) -------------------------

enum MG_CHANGE { Added = 0, Removed = 1, Modified = 2 }

class MGBlockIndex {
    dictionary byKey; // key -> index into the array
    array<MGBlock>@ src;
    MGBlockIndex(array<MGBlock>@ source) {
        @src = source;
        for (uint i = 0; i < source.Length; i++) {
            byKey.Set(source[i].key, int(i));
        }
    }
    bool Has(const string&in key) { return byKey.Exists(key); }
    int IndexOf(const string&in key) { int ix = -1; if (byKey.Get(key, ix)) return ix; return -1; }
}

class MGItemIndex {
    dictionary byKey;
    array<MGItem>@ src;
    MGItemIndex(array<MGItem>@ source) {
        @src = source;
        for (uint i = 0; i < source.Length; i++) {
            byKey.Set(source[i].key, int(i));
        }
    }
    bool Has(const string&in key) { return byKey.Exists(key); }
    int IndexOf(const string&in key) { int ix = -1; if (byKey.Get(key, ix)) return ix; return -1; }
}

// ------------------------- conflicts -------------------------

class MGMergeConflict {
    int kind;        // 0 AddAdd, 1 ModifyModify, 2 ModifyDelete, 3 DeleteModify, 4 Metadata, 5 Embedded
    string section;  // "block" / "item" / "mapInfo" / "embedded"
    string key;
    string oursSummary;
    string theirsSummary;
    string baseSummary;
    MGBlock@ theirsBlock;  // for block conflicts
    MGItem@ theirsItem;    // for item conflicts
    int resolution;        // 0 unresolved, 1 ours, 2 theirs, 3 both, 4 none
    vec3 oursPos;          // world position for the camera jump + green wireframe
    bool hasOursPos;
    vec3 theirsPos;        // world position for the camera jump + red ghost wireframe
    bool hasTheirsPos;
}

string MG_KindName(int kind) {
    if (kind == 0) return "add/add";
    if (kind == 1) return "modify/modify";
    if (kind == 2) return "modify/delete";
    if (kind == 3) return "delete/modify";
    if (kind == 4) return "metadata";
    return "embedded";
}

// ------------------------- conflict world positions -------------------------

vec3 MG_BlockWorldPos(const MGBlock&in b) {
    if (b.isFree) return b.freePos + vec3(0, 56, 0); // back to E++ memory space
    // E++ Math.as formula: pos = (coord.x*32, coord.y*8 - baseOffset, coord.z*32)
    // with baseOffset = -extendsBelowZero = -56 for Stadium2020 (same 7-cell constant
    // as the free-position offset; verified against E++'s own CoordToPos definition).
    return vec3(b.cx * 32.0 + 16.0, b.cy * 8.0 + 56.0 + 4.0, b.cz * 32.0 + 16.0);
}

vec3 MG_ItemWorldPos(const MGItem&in i) {
    return i.position; // items' manifest position IS the render-space position
}

void MG_JumpCamera(const vec3&in target) {
    try {
        Editor::SetCamAnimationGoTo(Editor::DirToLookUvFromCamera(target), target + vec3(0, 64, 128), 192.0);
    } catch {
        MG_Log("merge: camera jump failed: " + getExceptionInfo());
    }
}

// Draws unresolved conflicts as 3D wireframes every frame (called from Render()):
// green box = ours (in place), red ghost box = theirs. Resolved ones vanish.
void MG_DrawConflictMarkersFrame() {
    if (!g_mgMergeActive || g_mgConflicts.Length == 0) return;

    auto theirsDI = Editor::DrawLinesAndQuads::GetOrCreateDrawInstance("mapgit-merge-theirs");
    if (theirsDI is null) return;
    theirsDI.ResetLines();
    theirsDI.RequestLineColor(vec3(1, 0.25, 0.25)); // red — theirs (ghost)
    bool anyTheirs = false;

    auto oursDI = Editor::DrawLinesAndQuads::GetOrCreateDrawInstance("mapgit-merge-ours");
    if (oursDI is null) return;
    oursDI.ResetLines();
    oursDI.RequestLineColor(vec3(0.3, 1, 0.4)); // green — ours (in place)
    bool anyOurs = false;

    vec3 h = vec3(16, 4, 16); // half extents of a 32x8x32 block cell

    for (uint ci = 0; ci < g_mgConflicts.Length; ci++) {
        MGMergeConflict@ c = g_mgConflicts[ci];
        if (c.resolution != 0) continue; // resolved — no marker

        if (c.hasTheirsPos) {
            vec3 a = c.theirsPos - h;
            vec3 b = c.theirsPos + h;
            theirsDI.PushLineSegment(vec3(a.x, a.y, a.z), vec3(b.x, a.y, a.z));
            theirsDI.PushLineSegment(vec3(a.x, b.y, a.z), vec3(b.x, b.y, a.z));
            theirsDI.PushLineSegment(vec3(a.x, a.y, b.z), vec3(b.x, a.y, b.z));
            theirsDI.PushLineSegment(vec3(a.x, b.y, b.z), vec3(b.x, b.y, b.z));
            theirsDI.PushLineSegment(vec3(a.x, a.y, a.z), vec3(a.x, b.y, a.z));
            theirsDI.PushLineSegment(vec3(b.x, a.y, a.z), vec3(b.x, b.y, a.z));
            theirsDI.PushLineSegment(vec3(a.x, a.y, b.z), vec3(a.x, b.y, b.z));
            theirsDI.PushLineSegment(vec3(b.x, a.y, b.z), vec3(b.x, b.y, b.z));
            theirsDI.PushLineSegment(vec3(a.x, a.y, a.z), vec3(a.x, a.y, b.z));
            theirsDI.PushLineSegment(vec3(b.x, a.y, a.z), vec3(b.x, a.y, b.z));
            theirsDI.PushLineSegment(vec3(a.x, b.y, a.z), vec3(a.x, b.y, b.z));
            theirsDI.PushLineSegment(vec3(b.x, b.y, a.z), vec3(b.x, b.y, b.z));
            anyTheirs = true;
        }
        if (c.hasOursPos) {
            vec3 a = c.oursPos - h;
            vec3 b = c.oursPos + h;
            oursDI.PushLineSegment(vec3(a.x, a.y, a.z), vec3(b.x, a.y, a.z));
            oursDI.PushLineSegment(vec3(a.x, b.y, a.z), vec3(b.x, b.y, a.z));
            oursDI.PushLineSegment(vec3(a.x, a.y, b.z), vec3(b.x, a.y, b.z));
            oursDI.PushLineSegment(vec3(a.x, b.y, b.z), vec3(b.x, b.y, b.z));
            oursDI.PushLineSegment(vec3(a.x, a.y, a.z), vec3(a.x, b.y, a.z));
            oursDI.PushLineSegment(vec3(b.x, a.y, a.z), vec3(b.x, b.y, a.z));
            oursDI.PushLineSegment(vec3(a.x, a.y, b.z), vec3(a.x, b.y, b.z));
            oursDI.PushLineSegment(vec3(b.x, a.y, b.z), vec3(b.x, b.y, b.z));
            oursDI.PushLineSegment(vec3(a.x, a.y, a.z), vec3(a.x, a.y, b.z));
            oursDI.PushLineSegment(vec3(b.x, a.y, a.z), vec3(b.x, a.y, b.z));
            oursDI.PushLineSegment(vec3(a.x, b.y, a.z), vec3(a.x, b.y, b.z));
            oursDI.PushLineSegment(vec3(b.x, b.y, a.z), vec3(b.x, b.y, b.z));
            anyOurs = true;
        }
    }
    if (anyTheirs) theirsDI.Draw();
    if (anyOurs) oursDI.Draw();
}

// ------------------------- merge state -------------------------

bool g_mgMergeActive = false;
string g_mgMergeRepoDir = "";
string g_mgMergeBranch = "";      // ours (current)
string g_mgMergeSource = "";      // theirs (source branch)
string g_mgMergeOursTip = "";
string g_mgMergeTheirsTip = "";
string g_mgMergeBaseSha = "";
array<MGMergeConflict@> g_mgConflicts;
array<string> g_mgAppliedChanges;
MGManifest@ g_mgMergedClean;      // ours + clean takes (conflict resolutions applied at finalize)
MGMapInfo@ g_mgTheirsMapInfo;     // for metadata conflict resolutions
string g_mgMergeStatus = "";
int g_mgMergeSel = 0;             // source branch combo selection

// ------------------------- merge base -------------------------

array<string>@ MG_Ancestry(const string&in repoDir, const string&in tip) {
    array<string>@ chain = array<string>();
    string cur = tip;
    for (uint i = 0; i < 1000 && cur.Length > 0; i++) {
        chain.InsertLast(cur);
        string parents, manifest, blob, author, message;
        int64 time;
        if (!MG_ReadCommit(repoDir, cur, parents, manifest, blob, author, message, time)) break;
        string[] p = parents.Split(",");
        cur = (p.Length > 0 && p[0].Length > 0) ? p[0] : "";
    }
    return chain;
}

string MG_MergeBase(const string&in repoDir, const string&in oursTip, const string&in theirsTip) {
    array<string>@ oursChain = MG_Ancestry(repoDir, oursTip);
    array<string>@ theirsChain = MG_Ancestry(repoDir, theirsTip);
    dictionary seen;
    for (uint i = 0; i < theirsChain.Length; i++) seen.Set(theirsChain[i], true);
    for (uint i = 0; i < oursChain.Length; i++) {
        if (seen.Exists(oursChain[i])) return oursChain[i];
    }
    return "";
}

// ------------------------- reverse enum lookups (for placement) -------------------------

int MG_ColorValue(const string&in name) {
    if (name == "White") return 1;
    if (name == "Green") return 2;
    if (name == "Blue") return 3;
    if (name == "Red") return 4;
    if (name == "Black") return 5;
    return 0; // Default
}

int MG_LmValue(const string&in name) {
    if (name == "High") return 1;
    if (name == "VeryHigh") return 2;
    if (name == "Highest") return 3;
    if (name == "Low") return 4;
    if (name == "VeryLow") return 5;
    if (name == "Lowest") return 6;
    return 0; // Normal
}

// ------------------------- mapInfo merge (field-level) -------------------------

string MG_TimeStr(int ms) {
    return (ms < 0) ? "(none)" : ("" + ms + " ms");
}

string MG_MapInfoFieldStr(MGMapInfo@ m, const string&in field) {
    if (field == "name") return m.name;
    if (field == "comments") return m.comments;
    if (field == "collection") return m.collection;
    if (field == "decoration") return m.decoration;
    if (field == "titleId") return m.titleId;
    if (field == "authorLogin") return m.authorLogin;
    if (field == "mapType") return m.mapType;
    if (field == "mapStyle") return m.mapStyle;
    if (field == "authorTimeMs") return MG_TimeStr(m.authorTimeMs);
    if (field == "goldTimeMs") return MG_TimeStr(m.goldTimeMs);
    if (field == "silverTimeMs") return MG_TimeStr(m.silverTimeMs);
    if (field == "bronzeTimeMs") return MG_TimeStr(m.bronzeTimeMs);
    if (field == "nbLaps") return "" + m.nbLaps;
    if (field == "isLapRace") return m.isLapRace ? "true" : "false";
    if (field == "createdWithSimpleEditor") return m.createdWithSimpleEditor ? "true" : "false";
    return "?";
}

void MG_ApplyMapInfoField(MGMapInfo@ target, const string&in field, MGMapInfo@ from) {
    if (field == "name") target.name = from.name;
    else if (field == "comments") target.comments = from.comments;
    else if (field == "collection") target.collection = from.collection;
    else if (field == "decoration") target.decoration = from.decoration;
    else if (field == "titleId") target.titleId = from.titleId;
    else if (field == "authorLogin") target.authorLogin = from.authorLogin;
    else if (field == "mapType") target.mapType = from.mapType;
    else if (field == "mapStyle") target.mapStyle = from.mapStyle;
    else if (field == "authorTimeMs") target.authorTimeMs = from.authorTimeMs;
    else if (field == "goldTimeMs") target.goldTimeMs = from.goldTimeMs;
    else if (field == "silverTimeMs") target.silverTimeMs = from.silverTimeMs;
    else if (field == "bronzeTimeMs") target.bronzeTimeMs = from.bronzeTimeMs;
    else if (field == "nbLaps") target.nbLaps = from.nbLaps;
    else if (field == "isLapRace") target.isLapRace = from.isLapRace;
    else if (field == "createdWithSimpleEditor") target.createdWithSimpleEditor = from.createdWithSimpleEditor;
}

// ------------------------- 3-way merge (blocks + items) -------------------------

void MG_MergeKeyedBlocks(MGBlockIndex@ b, MGBlockIndex@ o, MGBlockIndex@ t,
                         array<MGBlock>@ merged, const string&in key, int changeKind) {
    int bi = b.IndexOf(key);
    int oi = o.IndexOf(key);
    int ti = t.IndexOf(key);

    if (changeKind == MG_CHANGE::Added) {
        if (oi < 0) {
            merged.InsertLast(t.src[ti]);
            g_mgAppliedChanges.InsertLast("take theirs: +block " + key + " (" + t.src[ti].name + ")");
        } else if (MG_BlockEquals(o.src[oi], t.src[ti])) {
            // both added identical — nothing to do
        } else {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 0; c.section = "block"; c.key = key;
            c.oursSummary = o.src[oi].name; c.theirsSummary = t.src[ti].name;
            @c.theirsBlock = t.src[ti];
            c.oursPos = MG_BlockWorldPos(o.src[oi]); c.hasOursPos = true;
            c.theirsPos = MG_BlockWorldPos(t.src[ti]); c.hasTheirsPos = true;
            g_mgConflicts.InsertLast(c);
        }
    } else if (changeKind == MG_CHANGE::Removed) {
        if (oi < 0) return; // both removed
        if (MG_BlockEquals(o.src[oi], b.src[bi])) {
            // ours unchanged -> take theirs' deletion
            for (uint i = 0; i < merged.Length; i++) {
                if (merged[i].key == key) { merged.RemoveRange(i, 1); break; }
            }
            g_mgAppliedChanges.InsertLast("take theirs: -block " + key + " (" + b.src[bi].name + ")");
        } else {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 2; c.section = "block"; c.key = key;
            c.oursSummary = o.src[oi].name; c.theirsSummary = "(deleted)"; c.baseSummary = b.src[bi].name;
            c.oursPos = MG_BlockWorldPos(o.src[oi]); c.hasOursPos = true;
            g_mgConflicts.InsertLast(c);
        }
    } else { // Modified
        if (oi < 0) {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 3; c.section = "block"; c.key = key;
            c.oursSummary = "(deleted)"; c.theirsSummary = t.src[ti].name; c.baseSummary = b.src[bi].name;
            @c.theirsBlock = t.src[ti];
            c.theirsPos = MG_BlockWorldPos(t.src[ti]); c.hasTheirsPos = true;
            g_mgConflicts.InsertLast(c);
            return;
        }
        if (MG_BlockEquals(o.src[oi], t.src[ti])) return; // same modification
        if (MG_BlockEquals(o.src[oi], b.src[bi])) {
            // ours unchanged -> take theirs
            for (uint i = 0; i < merged.Length; i++) {
                if (merged[i].key == key) { merged.RemoveRange(i, 1); break; }
            }
            merged.InsertLast(t.src[ti]);
            g_mgAppliedChanges.InsertLast("take theirs: ~block " + key + " (" + t.src[ti].name + ")");
        } else {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 1; c.section = "block"; c.key = key;
            c.oursSummary = o.src[oi].name; c.theirsSummary = t.src[ti].name; c.baseSummary = b.src[bi].name;
            @c.theirsBlock = t.src[ti];
            c.oursPos = MG_BlockWorldPos(o.src[oi]); c.hasOursPos = true;
            c.theirsPos = MG_BlockWorldPos(t.src[ti]); c.hasTheirsPos = true;
            g_mgConflicts.InsertLast(c);
        }
    }
}

void MG_MergeKeyedItems(MGItemIndex@ b, MGItemIndex@ o, MGItemIndex@ t,
                        array<MGItem>@ merged, const string&in key, int changeKind) {
    int bi = b.IndexOf(key);
    int oi = o.IndexOf(key);
    int ti = t.IndexOf(key);

    if (changeKind == MG_CHANGE::Added) {
        if (oi < 0) {
            merged.InsertLast(t.src[ti]);
            g_mgAppliedChanges.InsertLast("take theirs: +item " + key + " (" + t.src[ti].itemModel + ")");
        } else if (MG_ItemEquals(o.src[oi], t.src[ti])) {
        } else {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 0; c.section = "item"; c.key = key;
            c.oursSummary = o.src[oi].itemModel; c.theirsSummary = t.src[ti].itemModel;
            @c.theirsItem = t.src[ti];
            c.oursPos = MG_ItemWorldPos(o.src[oi]); c.hasOursPos = true;
            c.theirsPos = MG_ItemWorldPos(t.src[ti]); c.hasTheirsPos = true;
            g_mgConflicts.InsertLast(c);
        }
    } else if (changeKind == MG_CHANGE::Removed) {
        if (oi < 0) return;
        if (MG_ItemEquals(o.src[oi], b.src[bi])) {
            for (uint i = 0; i < merged.Length; i++) {
                if (merged[i].key == key) { merged.RemoveRange(i, 1); break; }
            }
            g_mgAppliedChanges.InsertLast("take theirs: -item " + key);
        } else {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 2; c.section = "item"; c.key = key;
            c.oursSummary = o.src[oi].itemModel; c.theirsSummary = "(deleted)";
            c.oursPos = MG_ItemWorldPos(o.src[oi]); c.hasOursPos = true;
            g_mgConflicts.InsertLast(c);
        }
    } else { // Modified
        if (oi < 0) {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 3; c.section = "item"; c.key = key;
            c.oursSummary = "(deleted)"; c.theirsSummary = t.src[ti].itemModel;
            @c.theirsItem = t.src[ti];
            c.theirsPos = MG_ItemWorldPos(t.src[ti]); c.hasTheirsPos = true;
            g_mgConflicts.InsertLast(c);
            return;
        }
        if (MG_ItemEquals(o.src[oi], t.src[ti])) return;
        if (MG_ItemEquals(o.src[oi], b.src[bi])) {
            for (uint i = 0; i < merged.Length; i++) {
                if (merged[i].key == key) { merged.RemoveRange(i, 1); break; }
            }
            merged.InsertLast(t.src[ti]);
            g_mgAppliedChanges.InsertLast("take theirs: ~item " + key);
        } else {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 1; c.section = "item"; c.key = key;
            c.oursSummary = o.src[oi].itemModel; c.theirsSummary = t.src[ti].itemModel;
            @c.theirsItem = t.src[ti];
            c.oursPos = MG_ItemWorldPos(o.src[oi]); c.hasOursPos = true;
            c.theirsPos = MG_ItemWorldPos(t.src[ti]); c.hasTheirsPos = true;
            g_mgConflicts.InsertLast(c);
        }
    }
}

// ------------------------- merge driver -------------------------

void MG_RunMerge(MGManifest@ baseMan, MGManifest@ oursMan, MGManifest@ theirsMan) {
    MGBlockIndex@ bB = MGBlockIndex(baseMan.blocks);
    MGBlockIndex@ oB = MGBlockIndex(oursMan.blocks);
    MGBlockIndex@ tB = MGBlockIndex(theirsMan.blocks);

    // union of base/theirs block keys, sorted (deterministic order)
    array<string> keys;
    dictionary seen;
    for (uint i = 0; i < baseMan.blocks.Length; i++) {
        if (!seen.Exists(baseMan.blocks[i].key)) { seen.Set(baseMan.blocks[i].key, true); keys.InsertLast(baseMan.blocks[i].key); }
    }
    for (uint i = 0; i < theirsMan.blocks.Length; i++) {
        if (!seen.Exists(theirsMan.blocks[i].key)) { seen.Set(theirsMan.blocks[i].key, true); keys.InsertLast(theirsMan.blocks[i].key); }
    }
    keys.SortAsc();

    for (uint k = 0; k < keys.Length; k++) {
        string key = keys[k];
        bool hasB = bB.Has(key);
        bool hasT = tB.Has(key);
        if (hasB && !hasT) MG_MergeKeyedBlocks(bB, oB, tB, g_mgMergedClean.blocks, key, MG_CHANGE::Removed);
        else if (!hasB && hasT) MG_MergeKeyedBlocks(bB, oB, tB, g_mgMergedClean.blocks, key, MG_CHANGE::Added);
        else if (hasB && hasT && !MG_BlockEquals(bB.src[bB.IndexOf(key)], tB.src[tB.IndexOf(key)])) {
            MG_MergeKeyedBlocks(bB, oB, tB, g_mgMergedClean.blocks, key, MG_CHANGE::Modified);
        }
    }

    // items
    MGItemIndex@ bI = MGItemIndex(baseMan.items);
    MGItemIndex@ oI = MGItemIndex(oursMan.items);
    MGItemIndex@ tI = MGItemIndex(theirsMan.items);
    array<string> ikeys;
    dictionary iseen;
    for (uint i = 0; i < baseMan.items.Length; i++) {
        if (!iseen.Exists(baseMan.items[i].key)) { iseen.Set(baseMan.items[i].key, true); ikeys.InsertLast(baseMan.items[i].key); }
    }
    for (uint i = 0; i < theirsMan.items.Length; i++) {
        if (!iseen.Exists(theirsMan.items[i].key)) { iseen.Set(theirsMan.items[i].key, true); ikeys.InsertLast(theirsMan.items[i].key); }
    }
    ikeys.SortAsc();

    for (uint k = 0; k < ikeys.Length; k++) {
        string key = ikeys[k];
        bool hasB = bI.Has(key);
        bool hasT = tI.Has(key);
        if (hasB && !hasT) MG_MergeKeyedItems(bI, oI, tI, g_mgMergedClean.items, key, MG_CHANGE::Removed);
        else if (!hasB && hasT) MG_MergeKeyedItems(bI, oI, tI, g_mgMergedClean.items, key, MG_CHANGE::Added);
        else if (hasB && hasT && !MG_ItemEquals(bI.src[bI.IndexOf(key)], tI.src[tI.IndexOf(key)])) {
            MG_MergeKeyedItems(bI, oI, tI, g_mgMergedClean.items, key, MG_CHANGE::Modified);
        }
    }

    // mapInfo fields (base -> theirs). nbLaps/isLapRace are excluded: const in the
    // game API — the plugin cannot apply their changes to the live map.
    array<string> fields = { "name", "comments", "collection", "decoration", "titleId", "authorLogin",
                             "mapType", "mapStyle", "authorTimeMs", "goldTimeMs", "silverTimeMs",
                             "bronzeTimeMs", "createdWithSimpleEditor" };
    for (uint f = 0; f < fields.Length; f++) {
        string field = fields[f];
        string baseVal = MG_MapInfoFieldStr(baseMan.mapInfo, field);
        string theirsVal = MG_MapInfoFieldStr(theirsMan.mapInfo, field);
        if (baseVal == theirsVal) continue;
        string oursVal = MG_MapInfoFieldStr(oursMan.mapInfo, field);
        if (oursVal == theirsVal) continue;
        if (oursVal == baseVal) {
            MG_ApplyMapInfoField(g_mgMergedClean.mapInfo, field, theirsMan.mapInfo);
            g_mgAppliedChanges.InsertLast("take theirs: mapInfo." + field + " = " + theirsVal);
        } else {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 4; c.section = "mapInfo"; c.key = field;
            c.oursSummary = oursVal; c.theirsSummary = theirsVal; c.baseSummary = baseVal;
            g_mgConflicts.InsertLast(c);
        }
    }

    // embedded (entry-count level until the entries port)
    if (oursMan.embeddedEntryCount != theirsMan.embeddedEntryCount) {
        if (oursMan.embeddedEntryCount == baseMan.embeddedEntryCount) {
            g_mgMergedClean.embeddedEntryCount = theirsMan.embeddedEntryCount;
            g_mgAppliedChanges.InsertLast("take theirs: embedded (" + theirsMan.embeddedEntryCount + " entries)");
        } else {
            MGMergeConflict@ c = MGMergeConflict();
            c.kind = 5; c.section = "embedded"; c.key = "zip";
            c.oursSummary = "" + oursMan.embeddedEntryCount + " entries";
            c.theirsSummary = "" + theirsMan.embeddedEntryCount + " entries";
            c.baseSummary = "" + baseMan.embeddedEntryCount + " entries";
            g_mgConflicts.InsertLast(c);
        }
    }
}

// ------------------------- resolution finalize -------------------------

// Strips a trailing "#N" duplicate suffix (keeps ghost "#gh" and unsuffixed keys).
string MG_BaseKey(const string&in key) {
    int h = -1;
    for (int i = int(key.Length) - 1; i >= 0; i--) {
        if (key.SubStr(i, 1) == "#") { h = i; break; }
    }
    if (h < 0 || h + 1 >= int(key.Length)) return key;
    for (int i = h + 1; i < int(key.Length); i++) {
        string ch = key.SubStr(i, 1);
        if (ch != "0" && ch != "1" && ch != "2" && ch != "3" && ch != "4" &&
            ch != "5" && ch != "6" && ch != "7" && ch != "8" && ch != "9") {
            return key; // e.g. "#gh" — not a duplicate suffix
        }
    }
    return key.SubStr(0, h);
}

// Restores the canonical form (the C# engine's ToManifest step): base keys,
// canonical sort, deterministic re-suffixing. Without this, merged manifests
// list appended theirs-entries out of order and never hash-match a rebuild.
void MG_Recanonicalize(MGManifest@ m) {
    for (uint i = 0; i < m.blocks.Length; i++) {
        m.blocks[i].key = MG_BaseKey(m.blocks[i].key);
    }
    m.blocks.SortAsc();
    MG_SuffixBlocks(m.blocks);
    for (uint i = 0; i < m.items.Length; i++) {
        m.items[i].key = MG_BaseKey(m.items[i].key);
    }
    m.items.SortAsc();
    MG_SuffixItems(m.items);
}

// Applies conflict resolutions onto g_mgMergedClean, producing the final manifest.
MGManifest@ MG_FinalizeMerged() {
    for (uint ci = 0; ci < g_mgConflicts.Length; ci++) {
        MGMergeConflict@ c = g_mgConflicts[ci];
        if (c.resolution == 0) return null; // unresolved
        // ours(1): keep ours. theirs(2): drop ours + take theirs.
        // both(3): keep ours + take theirs (for delete/modify it equals theirs; for
        // modify/delete theirs is a deletion so it equals ours). none(4): drop ours.
        bool takeTheirs = (c.resolution == 2 || c.resolution == 3);
        bool dropOurs = (c.resolution == 2 || c.resolution == 4);

        if (c.section == "block") {
            if (dropOurs && c.kind != 3) {
                for (uint i = 0; i < g_mgMergedClean.blocks.Length; i++) {
                    if (g_mgMergedClean.blocks[i].key == c.key) { g_mgMergedClean.blocks.RemoveRange(i, 1); break; }
                }
            }
            if (takeTheirs && c.theirsBlock !is null) {
                g_mgMergedClean.blocks.InsertLast(c.theirsBlock);
            }
        } else if (c.section == "item") {
            if (dropOurs && c.kind != 3) {
                for (uint i = 0; i < g_mgMergedClean.items.Length; i++) {
                    if (g_mgMergedClean.items[i].key == c.key) { g_mgMergedClean.items.RemoveRange(i, 1); break; }
                }
            }
            if (takeTheirs && c.theirsItem !is null) {
                g_mgMergedClean.items.InsertLast(c.theirsItem);
            }
        } else if (c.section == "mapInfo") {
            if (c.resolution == 2) {
                MG_ApplyMapInfoField(g_mgMergedClean.mapInfo, c.key, g_mgTheirsMapInfo);
            }
        } else if (c.section == "embedded") {
            if (c.resolution == 2) {
                // theirs' embedded count is not directly recoverable from summaries; keep ours (v1)
            }
        }
    }
    MG_Recanonicalize(g_mgMergedClean);
    return g_mgMergedClean;
}

// ------------------------- live map index (key -> nod) -------------------------

class MGLiveBlock {
    MGBlock entry;
    CGameCtnBlock@ nod;
    int opCmp(const MGLiveBlock&in other) { return entry.opCmp(other.entry); }
}

class MGLiveItem {
    MGItem entry;
    CGameCtnAnchoredObject@ nod;
    int opCmp(const MGLiveItem&in other) { return entry.opCmp(other.entry); }
}

class MGLiveIndex {
    array<MGLiveBlock> blocks; // sorted canonically, keys suffixed
    array<MGLiveItem> items;
    dictionary blockByKey; // final (suffixed) key -> index
    dictionary itemByKey;
}

MGLiveIndex@ MG_BuildLiveIndex(CGameCtnChallenge@ map) {
    MGLiveIndex@ ix = MGLiveIndex();
    for (uint i = 0; i < map.Blocks.Length; i++) {
        MGLiveBlock lb;
        lb.entry = MG_ToBlock(map.Blocks[i]);
        @lb.nod = map.Blocks[i];
        ix.blocks.InsertLast(lb);
    }
    for (uint j = 0; j < map.BakedBlocks.Length; j++) {
        CGameCtnBlock@ nb = map.BakedBlocks[j];
        bool dupe = false;
        for (uint i = 0; i < map.Blocks.Length; i++) {
            if (map.Blocks[i] is nb) { dupe = true; break; }
        }
        if (dupe) continue;
        MGLiveBlock lb;
        lb.entry = MG_ToBlock(nb);
        @lb.nod = nb;
        ix.blocks.InsertLast(lb);
    }
    for (uint i = 0; i < map.AnchoredObjects.Length; i++) {
        MGLiveItem li;
        li.entry = MG_ToItem(map.AnchoredObjects[i]);
        @li.nod = map.AnchoredObjects[i];
        ix.items.InsertLast(li);
    }
    ix.blocks.SortAsc();
    ix.items.SortAsc();

    // assign suffixed keys (same rules as the manifest builder) + key -> index maps
    {
        uint i = 0;
        while (i < ix.blocks.Length) {
            string baseKey = ix.blocks[i].entry.key;
            uint j = i + 1;
            int n = 1;
            while (j < ix.blocks.Length && ix.blocks[j].entry.key == baseKey) {
                n++;
                ix.blocks[j].entry.key = baseKey + "#" + n;
                ix.blockByKey.Set(ix.blocks[j].entry.key, int(j));
                j++;
            }
            ix.blockByKey.Set(baseKey, int(i));
            i = j;
        }
    }
    {
        uint i = 0;
        while (i < ix.items.Length) {
            string baseKey = ix.items[i].entry.key;
            uint j = i + 1;
            int n = 1;
            while (j < ix.items.Length && ix.items[j].entry.key == baseKey) {
                n++;
                ix.items[j].entry.key = baseKey + "#" + n;
                ix.itemByKey.Set(ix.items[j].entry.key, int(j));
                j++;
            }
            ix.itemByKey.Set(baseKey, int(i));
            i = j;
        }
    }
    return ix;
}

// ------------------------- apply (live map -> merged manifest) -------------------------

CGameItemModel@ MG_FindItemModel(CGameCtnChallenge@ map, const string&in name) {
    CGameItemModel@ model = Editor::GetInventoryItemModelByPath(name);
    if (model !is null) return model;
    for (uint i = 0; i < map.AnchoredObjects.Length; i++) {
        CGameCtnAnchoredObject@ a = map.AnchoredObjects[i];
        if (a.ItemModel !is null && a.ItemModel.Id.GetName() == name) return a.ItemModel;
    }
    return null;
}

// Transforms the live map into `final`: deletes/removes/places via E++, sets mapInfo.
bool MG_ApplyMerged(CGameCtnChallenge@ map, MGManifest@ final) {
    MGLiveIndex@ live = MG_BuildLiveIndex(map);
    MGBlockIndex@ finalB = MGBlockIndex(final.blocks);
    MGItemIndex@ finalI = MGItemIndex(final.items);

    array<CGameCtnBlock@> blocksToDelete;
    array<MGBlock@> blocksToPlace;
    for (uint i = 0; i < live.blocks.Length; i++) {
        string key = live.blocks[i].entry.key;
        if (!finalB.Has(key)) {
            blocksToDelete.InsertLast(live.blocks[i].nod);
            continue;
        }
        if (!MG_BlockEquals(live.blocks[i].entry, finalB.src[finalB.IndexOf(key)])) {
            blocksToDelete.InsertLast(live.blocks[i].nod);
        }
    }
    for (uint i = 0; i < final.blocks.Length; i++) {
        MGBlock@ fb = final.blocks[i];
        int liveIx = -1;
        live.blockByKey.Get(fb.key, liveIx);
        if (liveIx < 0) {
            blocksToPlace.InsertLast(fb);
        } else if (!MG_BlockEquals(live.blocks[liveIx].entry, fb)) {
            blocksToPlace.InsertLast(fb); // replacement (ours' nod already queued for deletion)
        }
    }

    array<CGameCtnAnchoredObject@> itemsToDelete;
    array<MGItem@> itemsToPlace;
    for (uint i = 0; i < live.items.Length; i++) {
        string key = live.items[i].entry.key;
        if (!finalI.Has(key)) {
            itemsToDelete.InsertLast(live.items[i].nod);
            continue;
        }
        if (!MG_ItemEquals(live.items[i].entry, finalI.src[finalI.IndexOf(key)])) {
            itemsToDelete.InsertLast(live.items[i].nod);
        }
    }
    for (uint i = 0; i < final.items.Length; i++) {
        MGItem@ fi = final.items[i];
        int liveIx = -1;
        live.itemByKey.Get(fi.key, liveIx);
        if (liveIx < 0) {
            itemsToPlace.InsertLast(fi);
        } else if (!MG_ItemEquals(live.items[liveIx].entry, fi)) {
            itemsToPlace.InsertLast(fi);
        }
    }

    MG_Log("merge apply: -" + blocksToDelete.Length + " +" + blocksToPlace.Length + " blocks, -" +
           itemsToDelete.Length + " +" + itemsToPlace.Length + " items");

    if (blocksToDelete.Length > 0) {
        if (!Editor::DeleteBlocks(blocksToDelete, true)) {
            MG_Log("merge apply: DeleteBlocks failed");
            return false;
        }
    }
    if (itemsToDelete.Length > 0) {
        if (!Editor::DeleteItems(itemsToDelete, true)) {
            MG_Log("merge apply: DeleteItems failed");
            return false;
        }
    }

    if (blocksToPlace.Length > 0) {
        array<Editor::BlockSpec@> specs;
        for (uint i = 0; i < blocksToPlace.Length; i++) {
            MGBlock@ e = blocksToPlace[i];
            CGameCtnBlockInfo@ info = Editor::GetInventoryBlockInfoByName(e.name);
            if (info is null) {
                MG_Log("merge apply: unknown block '" + e.name + "' (key " + e.key + ") — skipped");
                continue;
            }
            Editor::BlockSpec@ spec;
            if (e.isFree) {
                vec3 pos = e.freePos + vec3(0, 56, 0);        // back to E++ memory space
                vec3 pyr = vec3(e.freeRot.y, e.freeRot.x, e.freeRot.z); // back to (pitch, yaw, roll)
                @spec = Editor::MakeBlockSpec(info, pos, pyr);
                spec.isGhost = e.isGhost;
            } else {
                @spec = Editor::MakeBlockSpec(info, nat3(e.cx, e.cy, e.cz), e.direction);
                spec.isGhost = e.isGhost;
            }
            spec.isGround = e.isGround;
            spec.color = CGameCtnBlock::EMapElemColor(MG_ColorValue(e.color));
            spec.lmQual = CGameCtnBlock::EMapElemLightmapQuality(MG_LmValue(e.lmQual));
            spec.variant = e.variant; // BlockSpec's settable variant (mobilIx is read-only on the exported spec)
            if (e.hasWaypointProps) {
                MG_Log("merge apply: WARNING - waypoint props on '" + e.name + "' are not re-applied (v1)");
            }
            if (e.hasSkin) {
                MG_Log("merge apply: WARNING - skin on '" + e.name + "' is not re-applied (v1)");
            }
            specs.InsertLast(spec);
        }
        if (specs.Length > 0 && !Editor::PlaceBlocks(specs, true)) {
            MG_Log("merge apply: PlaceBlocks failed");
            return false;
        }
    }

    if (itemsToPlace.Length > 0) {
        array<Editor::ItemSpec@> specs;
        for (uint i = 0; i < itemsToPlace.Length; i++) {
            MGItem@ e = itemsToPlace[i];
            CGameItemModel@ model = MG_FindItemModel(map, e.itemModel);
            if (model is null) {
                MG_Log("merge apply: unknown item '" + e.itemModel + "' — skipped");
                continue;
            }
            vec3 pyr = vec3(e.rotation.y, e.rotation.x, e.rotation.z);
            Editor::ItemSpec@ spec = Editor::MakeItemSpec(model, e.position, pyr);
            spec.scale = e.scale;
            spec.color = CGameCtnAnchoredObject::EMapElemColor(MG_ColorValue(e.color));
            spec.lmQual = CGameCtnAnchoredObject::EMapElemLightmapQuality(MG_LmValue(e.lmQual));
            specs.InsertLast(spec);
        }
        if (specs.Length > 0 && !Editor::PlaceItems(specs, true)) {
            MG_Log("merge apply: PlaceItems failed");
            return false;
        }
    }

    // mapInfo: set writable members where final differs.
    // NOTE: TMObjective_NbLaps/IsLapRace are const in the game API (not writable
    // in-game) — they are excluded from merging entirely (see MG_RunMerge fields).
    if (final.mapInfo !is null) {
        string curName = map.MapName;
        if (curName != final.mapInfo.name) map.MapName = final.mapInfo.name;
        string curComments = map.Comments;
        if (curComments != final.mapInfo.comments) map.Comments = final.mapInfo.comments;
        if (final.mapInfo.authorTimeMs >= 0) map.TMObjective_AuthorTime = uint(final.mapInfo.authorTimeMs);
        if (final.mapInfo.goldTimeMs >= 0) map.TMObjective_GoldTime = uint(final.mapInfo.goldTimeMs);
        if (final.mapInfo.silverTimeMs >= 0) map.TMObjective_SilverTime = uint(final.mapInfo.silverTimeMs);
        if (final.mapInfo.bronzeTimeMs >= 0) map.TMObjective_BronzeTime = uint(final.mapInfo.bronzeTimeMs);
    }
    return true;
}

// ------------------------- merge flow -------------------------

string g_mgMergeSecondParent = ""; // consumed by MG_CommitCoro (two-parent merge commit)

void MG_ClearMergeState() {
    g_mgMergeActive = false;
    g_mgConflicts.RemoveRange(0, g_mgConflicts.Length);
    g_mgAppliedChanges.RemoveRange(0, g_mgAppliedChanges.Length);
    @g_mgMergedClean = null;
    @g_mgTheirsMapInfo = null;
    g_mgMergeStatus = "";
}

bool MG_RestoreOursBlob(CGameCtnChallenge@ map, const string&in repoDir, const string&in oursTip) {
    string parents, manifest, blob, author, message;
    int64 time;
    if (!MG_ReadCommit(repoDir, oursTip, parents, manifest, blob, author, message, time)) return false;
    string blobPath = repoDir + "/objects/blobs/" + blob + ".gbx";
    if (!IO::FileExists(blobPath)) return false;
    CSystemFidFile@ mapFid = map.MapInfo.Fid;
    string mapPath;
    if (mapFid !is null) { mapPath = mapFid.FullFileName; }
    else { mapPath = IO::FromUserGameFolder(MG_MapFileOf(map)); }
    try {
        MG_CopyFile(blobPath, mapPath);
    } catch {
        return false;
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
    }
    return true;
}

void MG_MergeCoro() {
    if (g_mgRepoBusy) return;
    startnew(MG_MergeWork);
}

void MG_MergeWork() {
    g_mgRepoBusy = true;
    try {
        MG_MergeWorkInner();
    } catch {
        MG_Log("merge: EXCEPTION - " + getExceptionInfo());
        MG_ClearMergeState();
        g_mgMergeStatus = "merge failed (exception - see log)";
        g_mgRepoBusy = false;
    }
}

void MG_MergeWorkInner() {
    g_mgMergeStatus = "combining...";
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("merge: no map open"); g_mgRepoBusy = false; g_mgMergeStatus = "no map"; return; }
    if (g_mgMergeSel < 0 || g_mgMergeSel >= int(g_mgBranches.Length)) {
        MG_Log("merge: pick a source version line first"); g_mgRepoBusy = false; return;
    }
    string source = g_mgBranches[g_mgMergeSel];
    string mapFile = MG_MapFileOf(map);
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(mapFile);
    string oursBranch = MG_CurrentBranch(repoDir);
    if (source == oursBranch) { MG_Log("merge: source is the current version line"); g_mgRepoBusy = false; return; }
    string oursTip = MG_TipSha(repoDir, oursBranch);
    string theirsTip = MG_TipSha(repoDir, source);
    if (oursTip.Length == 0 || theirsTip.Length == 0) {
        MG_Log("merge: both version lines need commits first"); g_mgRepoBusy = false; return;
    }
    string baseSha = MG_MergeBase(repoDir, oursTip, theirsTip);
    if (baseSha.Length == 0) {
        MG_Log("merge: no common ancestor between '" + oursBranch + "' and '" + source + "'");
        g_mgRepoBusy = false; g_mgMergeStatus = "no common base";
        return;
    }
    if (baseSha == oursTip) {
        MG_Log("merge: '" + source + "' already contains everything on '" + oursBranch +
               "' (it was created after your latest commit) — there is nothing to combine. " +
               "Switch to '" + source + "' to get its changes (fast-forward).");
        g_mgMergeStatus = "'" + source + "' is ahead - nothing to combine (Switch instead)";
        g_mgRepoBusy = false;
        return;
    }

    // clean check: live manifest must match ours' tip
    MG_Log("merge: checking for uncommitted changes...");
    MGManifest@ oursMan = MG_BuildManifest(map);
    string tmp = IO::FromStorageFolder("merge-ours.json");
    MG_WriteManifest(oursMan, tmp);
    yield();
    string oursLiveSha = MG_Sha256File(tmp);
    string parents, oursTipManifest, oursTipBlob, author, message;
    int64 time;
    if (!MG_ReadCommit(repoDir, oursTip, parents, oursTipManifest, oursTipBlob, author, message, time)) {
        g_mgRepoBusy = false; return;
    }
    if (oursLiveSha != oursTipManifest) {
        g_mgMergeStatus = "merge refused: uncommitted changes (save a version first)";
        MG_Log("merge: " + g_mgMergeStatus);
        g_mgRepoBusy = false;
        return;
    }

    // load theirs + base manifests (capture theirs' manifest sha before reusing the out vars)
    string p2, m2, b2, a2, msg2;
    int64 t2;
    if (!MG_ReadCommit(repoDir, theirsTip, p2, m2, b2, a2, msg2, t2)) {
        MG_Log("merge: theirs commit unreadable"); g_mgRepoBusy = false; return;
    }
    string theirsManifestSha = m2;
    if (!MG_ReadCommit(repoDir, baseSha, p2, m2, b2, a2, msg2, t2)) {
        MG_Log("merge: base commit unreadable"); g_mgRepoBusy = false; return;
    }
    MGManifest@ theirsMan = MG_ReadManifest(repoDir + "/objects/manifests/" + theirsManifestSha + ".json");
    MGManifest@ baseMan = MG_ReadManifest(repoDir + "/objects/manifests/" + m2 + ".json");
    if (theirsMan is null || baseMan is null) {
        MG_Log("merge: stored manifests unreadable"); g_mgRepoBusy = false; return;
    }

    // merge state
    MG_ClearMergeState();
    @g_mgMergedClean = MGManifest();
    @g_mgMergedClean.mapInfo = oursMan.mapInfo;
    for (uint i = 0; i < oursMan.blocks.Length; i++) g_mgMergedClean.blocks.InsertLast(oursMan.blocks[i]);
    for (uint i = 0; i < oursMan.items.Length; i++) g_mgMergedClean.items.InsertLast(oursMan.items[i]);
    g_mgMergedClean.embeddedEntryCount = oursMan.embeddedEntryCount;
    @g_mgTheirsMapInfo = theirsMan.mapInfo;
    g_mgMergeRepoDir = repoDir;
    g_mgMergeBranch = oursBranch;
    g_mgMergeSource = source;
    g_mgMergeOursTip = oursTip;
    g_mgMergeTheirsTip = theirsTip;
    g_mgMergeBaseSha = baseSha;

    yield();
    MG_RunMerge(baseMan, oursMan, theirsMan);

    if (g_mgConflicts.Length > 0) {
        g_mgMergeActive = true;
        g_mgMergeStatus = g_mgConflicts.Length + " conflicts — resolve below, then apply";
        MG_Log("merge: " + g_mgMergeStatus);
        g_mgRepoBusy = false;
        return;
    }

    // clean merge: continue straight into apply + two-parent commit
    g_mgMergeActive = true;
    g_mgMergeStatus = "clean — applying " + g_mgAppliedChanges.Length + " changes...";
    MG_Log("merge: clean — " + g_mgAppliedChanges.Length + " changes from '" + source + "'");
    g_mgRepoBusy = false;
    MG_ApplyMergeWork();
}

void MG_ApplyMergeCoro() {
    if (g_mgRepoBusy) return;
    startnew(MG_ApplyMergeWork);
}

void MG_ApplyMergeWork() {
    g_mgRepoBusy = true;
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("merge apply: no map open"); g_mgRepoBusy = false; return; }
    MGManifest@ final = MG_FinalizeMerged();
    if (final is null) {
        MG_Log("merge apply: unresolved conflicts remain");
        g_mgRepoBusy = false;
        return;
    }

    if (!MG_ApplyMerged(map, final)) {
        MG_Log("merge apply: apply step failed — restoring");
        MG_RestoreOursBlob(map, g_mgMergeRepoDir, g_mgMergeOursTip);
        MG_ClearMergeState();
        g_mgRepoBusy = false;
        return;
    }
    yield();

    // verification invariant: rebuilt manifest must hash-match the computed merge
    MGManifest@ rebuilt = MG_BuildManifest(map);
    string tmpR = IO::FromStorageFolder("merge-verify-rebuilt.json");
    MG_WriteManifest(rebuilt, tmpR);
    string tmpF = IO::FromStorageFolder("merge-verify-final.json");
    MG_WriteManifest(final, tmpF);
    yield();
    string hashR = MG_Sha256File(tmpR);
    string hashF = MG_Sha256File(tmpF);
    if (hashR != hashF) {
        MG_Log("merge apply: VERIFICATION FAILED (rebuilt " + MG_Short(hashR) + " != expected " + MG_Short(hashF) +
               ") — restoring. Rebuilt: " + rebuilt.blocks.Length + " blocks / " + rebuilt.items.Length +
               " items; expected: " + final.blocks.Length + " / " + final.items.Length);
        MG_RestoreOursBlob(map, g_mgMergeRepoDir, g_mgMergeOursTip);
        MG_ClearMergeState();
        g_mgRepoBusy = false;
        g_mgMergeStatus = "verification failed — restored";
        return;
    }
    MG_Log("merge apply: verified (" + MG_Short(hashR) + ")");

    // two-parent merge commit via the standard commit flow
    g_mgMergeSecondParent = g_mgMergeTheirsTip;
    g_mgCommitMsg = T("Combined '", "Merge '") + g_mgMergeSource + T("' into '", "' into '") + g_mgMergeBranch + "'";
    string srcBranch = g_mgMergeSource;
    MG_ClearMergeState();
    g_mgMergeStatus = "merged '" + srcBranch + "'";
    MG_CommitCoro();
}

// ------------------------- merge UI -------------------------

void MG_ResolutionButton(MGMergeConflict@ c, int res, const string&in label) {
    bool active = (c.resolution == res);
    if (active) UI::BeginDisabled();
    if (UI::Button(label + "##c" + c.key + res)) {
        c.resolution = res;
    }
    if (active) UI::EndDisabled();
}

void RenderMergeSection() {
    UI::Separator();
    UI::Text(T("Combine version lines", "Merge") + ":");
    if (!g_mgMergeActive) {
        if (g_mgBranches.Length > 1) {
            if (g_mgMergeSel < 0 || g_mgMergeSel >= int(g_mgBranches.Length)) g_mgMergeSel = 0;
            if (UI::BeginCombo("##mg-merge-src", g_mgBranches[g_mgMergeSel])) {
                for (uint i = 0; i < g_mgBranches.Length; i++) {
                    if (UI::Selectable(g_mgBranches[i], int(i) == g_mgMergeSel)) {
                        g_mgMergeSel = int(i);
                    }
                }
                UI::EndCombo();
            }
            UI::BeginDisabled(g_mgRepoBusy);
            UI::SameLine();
            if (UI::Button(T("Combine", "Merge"))) MG_MergeCoro();
            UI::EndDisabled();
        } else {
            UI::TextDisabled("  (create a second version line above to combine)");
        }
    } else {
        if (g_mgMergeStatus.Length > 0) UI::Text(g_mgMergeStatus);
        if (g_mgConflicts.Length > 0) {
            bool allResolved = true;
            for (uint i = 0; i < g_mgConflicts.Length; i++) {
                if (g_mgConflicts[i].resolution == 0) { allResolved = false; break; }
            }
            for (uint i = 0; i < g_mgConflicts.Length; i++) {
                MGMergeConflict@ c = g_mgConflicts[i];
                UI::Text("  - " + MG_KindName(c.kind) + "  " + c.key +
                         "   [ours: " + c.oursSummary + "  theirs: " + c.theirsSummary + "]");
                if (c.hasOursPos) {
                    UI::SameLine();
                    if (UI::Button("\\$0f2go ours##o" + i)) MG_JumpCamera(c.oursPos);
                    if (UI::IsItemHovered()) UI::SetTooltip("Ours (green box in the world): " + c.oursSummary);
                }
                if (c.hasTheirsPos) {
                    UI::SameLine();
                    if (UI::Button("\\$f42go theirs##t" + i)) MG_JumpCamera(c.theirsPos);
                    if (UI::IsItemHovered()) UI::SetTooltip("Theirs (red ghost box): " + c.theirsSummary +
                        " — not placed yet; it only exists on the other version line");
                }
                UI::SameLine();
                MG_ResolutionButton(c, 1, "Ours");
                UI::SameLine();
                MG_ResolutionButton(c, 2, "Theirs");
                if (c.kind == 0 || c.kind == 1) {
                    UI::SameLine();
                    MG_ResolutionButton(c, 3, "Both");
                }
                UI::SameLine();
                MG_ResolutionButton(c, 4, "None");
                if (c.resolution != 0) {
                    UI::SameLine();
                    UI::TextDisabled("-> " + (c.resolution == 1 ? "ours" : c.resolution == 2 ? "theirs" :
                                              c.resolution == 3 ? "both" : "none"));
                }
            }
            UI::BeginDisabled(g_mgRepoBusy || !allResolved);
            if (UI::Button(T("Apply resolution", "Commit merge"))) MG_ApplyMergeCoro();
            UI::EndDisabled();
            UI::SameLine();
            if (UI::Button("Abort") && !g_mgRepoBusy) {
                MG_ClearMergeState();
            }
        }
        if (g_mgAppliedChanges.Length > 0 && g_mgConflicts.Length == 0) {
            for (uint i = 0; i < g_mgAppliedChanges.Length && i < 10; i++) {
                UI::TextDisabled("  " + g_mgAppliedChanges[i]);
            }
        }
    }
}

