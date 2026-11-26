// Merge.as — 3-way merge engine, manifest reader, merge-base, live apply via E++,
// conflict markers/previews, and the developer merge UI.
//
// Semantics: changes base->theirs are applied onto ours; anywhere ours also diverged
// from base becomes a conflict. Conflicts are resolved ours/theirs/both/none; a
// completed merge applies to the live map, verifies (rebuilt manifest must hash-match
// the computed result, else restore), and lands as a two-parent commit.

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
    b.hasSkinFile = false;
    b.hasSkinUrl = false;
    b.skinFile = "";
    b.skinUrl = "";
    if (blk.HasKey("skinFile") && blk["skinFile"].GetType() != Json::Type::Null) {
        b.skinFile = blk["skinFile"];
        b.hasSkinFile = b.skinFile.Length > 0;
    }
    if (blk.HasKey("skinUrl") && blk["skinUrl"].GetType() != Json::Type::Null) {
        b.skinUrl = blk["skinUrl"];
        b.hasSkinUrl = b.skinUrl.Length > 0;
    }
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
        if (j["embedded"].HasKey("entries")) {
            Json::Value@ ents = j["embedded"]["entries"];
            for (uint i = 0; i < ents.Length; i++) {
                MGEmbeddedEntry e;
                e.name = ents[i]["name"];
                e.fingerprint = ents[i].HasKey("fingerprint") ? string(ents[i]["fingerprint"]) : "";
                m.embeddedEntries.InsertLast(e);
            }
        }
        return m;
    } catch {
        MG_Log("merge: manifest parse failed: " + getExceptionInfo());
        return null;
    }
}

// ------------------------- equality -------------------------

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
    int kind;        // 0 AddAdd, 1 ModifyModify, 2 ModifyDelete, 3 DeleteModify, 4 Metadata, 5 Embedded, 6 StartLine
    string section;  // "block" / "item" / "mapInfo" / "embedded" (for StartLine: theirs' kind)
    string key;
    string oursSection;    // StartLine only: ours may be a block while theirs is an item
    string oursKey;
    string oursSummary;
    string theirsSummary;
    string baseSummary;
    MGBlock@ theirsBlock;  // for block conflicts
    MGItem@ theirsItem;    // for item conflicts
    MGBlock@ oursBlock;
    MGItem@ oursItem;
    int resolution;        // 0 unresolved, 1 ours, 2 theirs, 3 both, 4 none
    vec3 oursPos;          // world position for the camera jump + green wireframe
    bool hasOursPos;
    vec3 theirsPos;        // world position for the camera jump + red ghost / model
    bool hasTheirsPos;
    bool previewPlaced;    // real ghost/item model was placed for theirs
    bool previewFallback;  // model missing — wireframe only
    CGameCtnBlock@ previewBlock;
    CGameCtnAnchoredObject@ previewItem;
}

string MG_KindName(int kind) {
    if (kind == 0) return "add/add";
    if (kind == 1) return "modify/modify";
    if (kind == 2) return "modify/delete";
    if (kind == 3) return "delete/modify";
    if (kind == 4) return "metadata";
    if (kind == 6) return "start line";
    if (kind == 7) return "mediatracker";
    return "embedded";
}

// ------------------------- single start line -------------------------
// A map may only have one start (or one multilap start/finish). Each side can move
// it to a different spot without any per-cell conflict, so the merge checks it.

dictionary g_mgStartCache;

bool MG_IsStartBlockName(const string&in name) {
    bool v = false;
    if (g_mgStartCache.Get("b:" + name, v)) return v;
    CGameCtnBlockInfo@ info = MG_ResolveBlockInfo(name);
    v = info !is null && (info.WaypointType == CGameCtnBlockInfo::EWayPointType::Start ||
                          info.WaypointType == CGameCtnBlockInfo::EWayPointType::StartFinish);
    g_mgStartCache.Set("b:" + name, v);
    return v;
}

bool MG_IsStartItemModel(const string&in name) {
    bool v = false;
    if (g_mgStartCache.Get("i:" + name, v)) return v;
    CGameCtnChallenge@ map = GetMap();
    CGameItemModel@ model = null;
    if (map !is null) @model = MG_FindItemModel(map, name);
    v = model !is null && (model.WaypointType == CGameItemModel::EnumWaypointType::Start ||
                           model.WaypointType == CGameItemModel::EnumWaypointType::StartFinish);
    g_mgStartCache.Set("i:" + name, v);
    return v;
}

bool MG_ConflictHasStart(MGMergeConflict@ c) {
    if (c.kind == 6) return true;
    if (c.oursBlock !is null && MG_IsStartBlockName(c.oursBlock.name)) return true;
    if (c.theirsBlock !is null && MG_IsStartBlockName(c.theirsBlock.name)) return true;
    if (c.oursItem !is null && MG_IsStartItemModel(c.oursItem.itemModel)) return true;
    if (c.theirsItem !is null && MG_IsStartItemModel(c.theirsItem.itemModel)) return true;
    return false;
}

int MG_CountStarts(MGManifest@ m) {
    int n = 0;
    for (uint i = 0; i < m.blocks.Length; i++) if (MG_IsStartBlockName(m.blocks[i].name)) n++;
    for (uint i = 0; i < m.items.Length; i++) if (MG_IsStartItemModel(m.items[i].itemModel)) n++;
    return n;
}

// Runs after MG_RunMerge. If the clean result holds a start from each side, theirs is
// held back and the player picks which one the map keeps.
int g_mgOursStartCount = 0;

void MG_EnforceSingleStart(MGManifest@ oursMan) {
    g_mgOursStartCount = MG_CountStarts(oursMan);
    MGBlockIndex@ oB = MGBlockIndex(oursMan.blocks);
    MGItemIndex@ oI = MGItemIndex(oursMan.items);
    MGBlock@ oursStartB = null;
    MGItem@ oursStartI = null;
    array<MGBlock@> theirsStartsB;
    array<MGItem@> theirsStartsI;
    for (uint i = 0; i < g_mgMergedClean.blocks.Length; i++) {
        MGBlock@ b = g_mgMergedClean.blocks[i];
        if (!MG_IsStartBlockName(b.name)) continue;
        int oi = oB.IndexOf(b.key);
        bool fromOurs = oi >= 0 && oB.src[oi].contentJson == b.contentJson;
        if (fromOurs) { if (oursStartB is null) @oursStartB = b; }
        else theirsStartsB.InsertLast(b);
    }
    for (uint i = 0; i < g_mgMergedClean.items.Length; i++) {
        MGItem@ it = g_mgMergedClean.items[i];
        if (!MG_IsStartItemModel(it.itemModel)) continue;
        int oi = oI.IndexOf(it.key);
        bool fromOurs = oi >= 0 && oI.src[oi].contentJson == it.contentJson;
        if (fromOurs) { if (oursStartI is null) @oursStartI = it; }
        else theirsStartsI.InsertLast(it);
    }
    bool oursHas = oursStartB !is null || oursStartI !is null;
    bool theirsHas = theirsStartsB.Length > 0 || theirsStartsI.Length > 0;
    if (!oursHas || !theirsHas) return;

    MGMergeConflict@ c = MGMergeConflict();
    c.kind = 6;
    if (oursStartB !is null) {
        c.oursSection = "block"; c.oursKey = oursStartB.key; c.oursSummary = oursStartB.name;
        @c.oursBlock = oursStartB; c.oursPos = MG_BlockWorldPos(oursStartB);
    } else {
        c.oursSection = "item"; c.oursKey = oursStartI.key; c.oursSummary = oursStartI.itemModel;
        @c.oursItem = oursStartI; c.oursPos = MG_ItemWorldPos(oursStartI);
    }
    c.hasOursPos = true;
    if (theirsStartsB.Length > 0) {
        MGBlock@ tb = theirsStartsB[0];
        c.section = "block"; c.key = tb.key; c.theirsSummary = tb.name;
        @c.theirsBlock = tb; c.theirsPos = MG_BlockWorldPos(tb);
    } else {
        MGItem@ ti = theirsStartsI[0];
        c.section = "item"; c.key = ti.key; c.theirsSummary = ti.itemModel;
        @c.theirsItem = ti; c.theirsPos = MG_ItemWorldPos(ti);
    }
    c.hasTheirsPos = true;

    // Hold every incoming start back; only the one the player picks is added.
    for (int i = int(g_mgMergedClean.blocks.Length) - 1; i >= 0; i--) {
        for (uint j = 0; j < theirsStartsB.Length; j++) {
            if (g_mgMergedClean.blocks[i] is theirsStartsB[j]) { g_mgMergedClean.blocks.RemoveAt(i); break; }
        }
    }
    for (int i = int(g_mgMergedClean.items.Length) - 1; i >= 0; i--) {
        for (uint j = 0; j < theirsStartsI.Length; j++) {
            if (g_mgMergedClean.items[i] is theirsStartsI[j]) { g_mgMergedClean.items.RemoveAt(i); break; }
        }
    }
    g_mgConflicts.InsertLast(c);
    MG_Log("merge: both sides have a start line — asking which one to keep");
}

// ------------------------- conflict world positions -------------------------

// World-space Y of the floor of cell y=0 (world y = cy*8 + this). Stadium2020: -64.
float g_mgGridWorldBaseY = -64.0;
// E++ keeps free-block positions in a space shifted up from the file/world position
// (the map's "macroblock" height offset). Stadium2020: +56.
float g_mgFreeMemOffsetY = 56.0;

// Game-side coord -> world conversion (bottom-min corner of the cell), via the
// editor's ManiaScript API so custom map bases are honoured.
bool MG_CoordFloorWorld(int cx, int cy, int cz, vec3 &out pos) {
    if (cx < 0 || cy < 0 || cz < 0) return false;
    auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
    if (editor is null || editor.PluginMapType is null) return false;
    vec3 v = editor.PluginMapType.GetVec3FromCoord(nat3(cx, cy, cz));
    // Some builds return the cell centre rather than its min corner.
    if (Math::Abs(v.x - (cx * 32.0 + 16.0)) < 1.0) v -= vec3(16.0, 4.0, 16.0);
    pos = v;
    return true;
}

void MG_CalibrateWorldSpace(CGameCtnChallenge@ map) {
    if (map is null) return;
    for (uint i = 0; i < map.Blocks.Length; i++) {
        CGameCtnBlock@ b = map.Blocks[i];
        if (int(b.Coord.x) < 0) continue; // grid blocks only
        Editor::BlockSpec@ spec = Editor::MakeBlockSpec(b);
        if (spec is null || spec.isFree) continue;
        float memBase = spec.pos.y - (b.Coord.y * 8.0);
        vec3 floor;
        if (MG_CoordFloorWorld(int(b.Coord.x), int(b.Coord.y), int(b.Coord.z), floor)) {
            g_mgGridWorldBaseY = floor.y - (b.Coord.y * 8.0);
            g_mgFreeMemOffsetY = memBase - g_mgGridWorldBaseY;
        } else {
            g_mgGridWorldBaseY = memBase - g_mgFreeMemOffsetY;
        }
        MG_Log("merge: world-space calibration gridBaseY=" + g_mgGridWorldBaseY +
               " freeMemOffsetY=" + g_mgFreeMemOffsetY +
               " (from live block '" + b.DescId.GetName() + "' at cell y=" + b.Coord.y + ")");
        return;
    }
}

vec3 MG_BlockWorldPos(const MGBlock&in b) {
    if (b.isFree) return b.freePos; // manifest free pos is already world (file) space
    vec3 floor;
    if (!MG_CoordFloorWorld(b.cx, b.cy, b.cz, floor)) {
        floor = vec3(b.cx * 32.0, b.cy * 8.0 + g_mgGridWorldBaseY, b.cz * 32.0);
    }
    return floor + vec3(16.0, 4.0, 16.0);
}

vec3 MG_ItemWorldPos(const MGItem&in i) {
    return i.position; // items' manifest position IS the render-space position
}

vec3 g_mgLastCamTarget = vec3(-99999, -99999, -99999);

void MG_JumpCamera(const vec3&in target) {
    // E++ orbital API (see Editor++ BI_MainTab): second arg is the TARGET position,
    // not the camera eye. Passing target+offset was why aim drifted / missed the block.
    if (Math::Abs(target.x - g_mgLastCamTarget.x) < 0.5 &&
        Math::Abs(target.y - g_mgLastCamTarget.y) < 0.5 &&
        Math::Abs(target.z - g_mgLastCamTarget.z) < 0.5) {
        return; // already aimed here — don't re-animate (prevents micro-drift)
    }
    g_mgLastCamTarget = target;
    try {
        vec2 uv = Editor::DirToLookUvFromCamera(target);
        if (uv.y < 0.7) uv.y = 0.7;
        bool ok = Editor::SetCamAnimationGoTo(uv, target, 160.0);
        MG_Log("merge: go -> look at " + target.ToString() + " -> " + (ok ? "true" : "false"));
    } catch {
        MG_Log("merge: camera jump failed: " + getExceptionInfo());
        try {
            CGameCtnEditorFree@ ed = GetEditorFree();
            if (ed !is null && ed.PluginMapType !is null) {
                ed.PluginMapType.CameraTargetPosition = target;
                ed.PluginMapType.CameraToTargetDistance = 160.0;
                ed.PluginMapType.CameraVAngle = 0.55;
            }
        } catch { }
    }
}

// Resolve BlockInfo for preview/apply: live map → inventory → PluginMapType (incl. terrain).
CGameCtnBlockInfo@ MG_ResolveBlockInfo(const string&in name) {
    CGameCtnChallenge@ map = GetMap();
    if (map !is null) {
        for (uint i = 0; i < map.Blocks.Length; i++) {
            if (map.Blocks[i].DescId.GetName() == name && map.Blocks[i].BlockInfo !is null) {
                return map.Blocks[i].BlockInfo;
            }
        }
        for (uint j = 0; j < map.BakedBlocks.Length; j++) {
            if (map.BakedBlocks[j].DescId.GetName() == name && map.BakedBlocks[j].BlockInfo !is null) {
                return map.BakedBlocks[j].BlockInfo;
            }
        }
    }
    CGameCtnBlockInfo@ inv = Editor::GetInventoryBlockInfoByName(name);
    if (inv !is null) return inv;
    CGameCtnEditorFree@ ed = GetEditorFree();
    if (ed !is null && ed.PluginMapType !is null) {
        try {
            CGameCtnBlockInfo@ m = ed.PluginMapType.GetBlockModelFromName(name);
            if (m !is null) return m;
        } catch { }
        try {
            CGameCtnBlockInfo@ t = ed.PluginMapType.GetTerrainBlockModelFromName(name);
            if (t !is null) return t;
        } catch { }
    }
    return null;
}

// Clip/connector pieces ("...FC", "...FCBGround") are generated by the game around
// the blocks a player places; they can't be placed directly and are regenerated on
// their own, so the merge leaves them to the game.
dictionary g_mgAutoBlockCache;

bool MG_NameLooksLikeClip(const string&in name) {
    int at = name.IndexOf("FC");
    while (at >= 0) {
        int next = at + 2;
        if (next >= int(name.Length)) return true;
        string ch = name.SubStr(next, 1);
        if (ch != ch.ToLower()) return true; // followed by an uppercase letter
        int rel = name.SubStr(next).IndexOf("FC");
        at = rel < 0 ? -1 : next + rel;
    }
    return false;
}

bool MG_IsAutoBlock(const string&in name) {
    bool cached = false;
    if (g_mgAutoBlockCache.Get(name, cached)) return cached;
    bool isAuto;
    CGameCtnBlockInfo@ info = MG_ResolveBlockInfo(name);
    if (info !is null) isAuto = info.IsClip;
    else isAuto = MG_NameLooksLikeClip(name);
    g_mgAutoBlockCache.Set(name, isAuto);
    return isAuto;
}

// Copy of `m` without auto-generated blocks, re-keyed canonically.
MGManifest@ MG_WithoutAutoBlocks(MGManifest@ m) {
    MGManifest@ r = MGManifest();
    @r.mapInfo = m.mapInfo;
    for (uint i = 0; i < m.blocks.Length; i++) {
        if (!MG_IsAutoBlock(m.blocks[i].name)) r.blocks.InsertLast(m.blocks[i]);
    }
    for (uint i = 0; i < m.items.Length; i++) r.items.InsertLast(m.items[i]);
    r.embeddedEntryCount = m.embeddedEntryCount;
    for (uint i = 0; i < m.embeddedEntries.Length; i++) r.embeddedEntries.InsertLast(m.embeddedEntries[i]);
    MG_Recanonicalize(r);
    return r;
}

// Conflict markers are a NanoVG screen overlay projected from world space.
// Editor++'s DrawLinesAndQuads shares one colour across all instances and writes into
// internal editor trees that don't render on every game build, so it isn't used here.
bool g_mgMarkersLogged = false;
int g_mgNvgFont = -1;

vec4 MG_COL_THEIRS = vec4(1.0, 0.25, 0.25, 1.0);
vec4 MG_COL_OURS   = vec4(0.2, 0.95, 0.4, 1.0);

bool MG_ToScreen(const vec3&in world, vec2&out screen) {
    vec3 s = Camera::ToScreen(world);
    screen = s.xy;
    return s.z < 0; // z >= 0 means behind the camera
}

void MG_NvgWorldSegment(const vec3&in a, const vec3&in b) {
    vec2 sa, sb;
    if (!MG_ToScreen(a, sa) || !MG_ToScreen(b, sb)) return;
    nvg::MoveTo(sa);
    nvg::LineTo(sb);
}

void MG_NvgBoxPath(const vec3&in center, const vec3&in h) {
    vec3 a = center - h;
    vec3 b = center + h;
    MG_NvgWorldSegment(vec3(a.x, a.y, a.z), vec3(b.x, a.y, a.z));
    MG_NvgWorldSegment(vec3(a.x, b.y, a.z), vec3(b.x, b.y, a.z));
    MG_NvgWorldSegment(vec3(a.x, a.y, b.z), vec3(b.x, a.y, b.z));
    MG_NvgWorldSegment(vec3(a.x, b.y, b.z), vec3(b.x, b.y, b.z));
    MG_NvgWorldSegment(vec3(a.x, a.y, a.z), vec3(a.x, b.y, a.z));
    MG_NvgWorldSegment(vec3(b.x, a.y, a.z), vec3(b.x, b.y, a.z));
    MG_NvgWorldSegment(vec3(a.x, a.y, b.z), vec3(a.x, b.y, b.z));
    MG_NvgWorldSegment(vec3(b.x, a.y, b.z), vec3(b.x, b.y, b.z));
    MG_NvgWorldSegment(vec3(a.x, a.y, a.z), vec3(a.x, a.y, b.z));
    MG_NvgWorldSegment(vec3(b.x, a.y, a.z), vec3(b.x, a.y, b.z));
    MG_NvgWorldSegment(vec3(a.x, b.y, a.z), vec3(a.x, b.y, b.z));
    MG_NvgWorldSegment(vec3(b.x, b.y, a.z), vec3(b.x, b.y, b.z));
}

void MG_NvgStrokeBox(const vec3&in center, const vec3&in h, const vec4&in col, float width) {
    // Dark under-stroke keeps the coloured outline readable on any background.
    nvg::BeginPath();
    MG_NvgBoxPath(center, h);
    nvg::StrokeColor(vec4(0, 0, 0, 0.75));
    nvg::StrokeWidth(width + 3.0);
    nvg::Stroke();
    nvg::BeginPath();
    MG_NvgBoxPath(center, h);
    nvg::StrokeColor(col);
    nvg::StrokeWidth(width);
    nvg::Stroke();
}

void MG_NvgLabel(const vec2&in anchor, const string&in text, const vec4&in col) {
    if (g_mgNvgFont < 0) g_mgNvgFont = nvg::LoadFont("DroidSans.ttf");
    nvg::FontFace(g_mgNvgFont);
    nvg::FontSize(18.0);
    nvg::TextAlign(nvg::Align::Center | nvg::Align::Middle);
    vec2 bounds = nvg::TextBounds(text);
    vec2 pad = vec2(10, 5);
    vec2 size = bounds + pad * 2.0;
    vec2 tl = anchor - vec2(size.x * 0.5, size.y);
    nvg::BeginPath();
    nvg::RoundedRect(tl, size, 6.0);
    nvg::FillColor(vec4(0.05, 0.05, 0.07, 0.85));
    nvg::Fill();
    nvg::StrokeColor(col);
    nvg::StrokeWidth(2.0);
    nvg::Stroke();
    nvg::FillColor(col);
    nvg::Text(tl + size * 0.5, text);
}

// Pin at the screen edge pointing toward a marker that is off-screen or behind the camera.
void MG_NvgOffscreenArrow(const vec3&in world, const vec4&in col) {
    vec2 scr = vec2(Display::GetWidth(), Display::GetHeight());
    vec2 mid = scr * 0.5;
    vec3 s = Camera::ToScreen(world);
    vec2 dir = s.xy - mid;
    if (s.z >= 0) dir = dir * -1.0;
    if (dir.LengthSquared() < 1.0) dir = vec2(0, 1);
    dir = dir.Normalized();
    float margin = 40.0;
    float tx = dir.x != 0 ? (mid.x - margin) / Math::Abs(dir.x) : 1e9;
    float ty = dir.y != 0 ? (mid.y - margin) / Math::Abs(dir.y) : 1e9;
    vec2 p = mid + dir * Math::Min(tx, ty);
    vec2 perp = vec2(-dir.y, dir.x);
    nvg::BeginPath();
    nvg::MoveTo(p + dir * 18.0);
    nvg::LineTo(p - dir * 10.0 + perp * 14.0);
    nvg::LineTo(p - dir * 10.0 - perp * 14.0);
    nvg::ClosePath();
    nvg::FillColor(col);
    nvg::Fill();
    nvg::StrokeColor(vec4(0, 0, 0, 0.8));
    nvg::StrokeWidth(2.0);
    nvg::Stroke();
}

bool MG_OnScreen(const vec3&in world) {
    vec2 s;
    if (!MG_ToScreen(world, s)) return false;
    return s.x >= 0 && s.y >= 0 && s.x <= Display::GetWidth() && s.y <= Display::GetHeight();
}

void MG_DrawMarker(const vec3&in center, const vec4&in col, const string&in label, float pulse, float labelLift) {
    if (!MG_OnScreen(center)) {
        MG_NvgOffscreenArrow(center, col);
        return;
    }
    MG_NvgStrokeBox(center, vec3(16, 4, 16), col, 2.5);
    vec3 grow = vec3(1, 1, 1) * (1.5 + 2.5 * pulse);
    vec4 glow = vec4(col.x, col.y, col.z, 0.35 + 0.4 * (1.0 - pulse));
    MG_NvgStrokeBox(center, vec3(16, 4, 16) + grow, glow, 1.5);

    vec3 top = center + vec3(0, 4, 0);
    vec3 tip = center + vec3(0, 28 + labelLift, 0);
    nvg::BeginPath();
    MG_NvgWorldSegment(top, tip);
    nvg::StrokeColor(col);
    nvg::StrokeWidth(2.0);
    nvg::Stroke();
    vec2 s;
    if (MG_ToScreen(tip, s)) MG_NvgLabel(s, label, col);
}

void MG_DrawConflictMarkersFrame() {
    if (!g_mgMergeActive || g_mgConflicts.Length == 0) return;
    if (GetEditorFree() is null) return;

    float pulse = (Math::Sin(float(Time::Now) / 250.0) + 1.0) * 0.5;
    nvg::Reset();
    nvg::LineCap(nvg::LineCapType::Round);
    nvg::LineJoin(nvg::LineCapType::Round);

    bool showOurs = g_mgViewMode != 2;
    bool showTheirs = g_mgViewMode != 1;
    for (uint ci = 0; ci < g_mgConflicts.Length; ci++) {
        MGMergeConflict@ c = g_mgConflicts[ci];
        if (c.resolution != 0) continue;
        if (!g_mgShowAllConflicts && int(ci) != g_mgConflictFocus) continue;

        string num = "#" + (ci + 1) + "  ";
        bool same = c.hasTheirsPos && c.hasOursPos && (c.theirsPos - c.oursPos).LengthSquared() < 1.0;
        if (c.hasOursPos && showOurs) {
            string lbl = num + "Yours: " + MG_PrettyName(c.oursSummary);
            if (!c.hasTheirsPos) lbl += " (they removed it)";
            MG_DrawMarker(c.oursPos, MG_COL_OURS, lbl, pulse, 0.0);
        }
        if (c.hasTheirsPos && showTheirs) {
            string lbl = num + "Theirs: " + MG_PrettyName(c.theirsSummary);
            if (!c.hasOursPos) lbl += " (you removed yours)";
            MG_DrawMarker(c.theirsPos, MG_COL_THEIRS, lbl, pulse, (same && showOurs) ? 16.0 : 0.0);
        }
    }

    if (!g_mgMarkersLogged && g_mgConflicts.Length > 0) {
        g_mgMarkersLogged = true;
        uint placed = 0, fallback = 0;
        for (uint i = 0; i < g_mgConflicts.Length; i++) {
            if (g_mgConflicts[i].previewPlaced) placed++;
            if (g_mgConflicts[i].previewFallback) fallback++;
        }
        MG_Log("conflict markers: " + g_mgConflicts.Length + " conflicts; model previews=" +
               placed + " wireframe-fallback=" + fallback);
    }
}

// ------------------------- real ghost / item conflict previews -------------------------

void MG_TryApplyBlockSkin(CGameCtnBlock@ nod, MGBlock@ e) {
    if (nod is null || e is null || !e.hasSkin) return;
    string skin = e.hasSkinFile ? e.skinFile : e.skinUrl;
    if (skin.Length == 0) return;
    try {
        CGameCtnEditorFree@ editor = GetEditorFree();
        if (editor is null || editor.PluginMapType is null) return;
        editor.PluginMapType.SetBlockSkin(nod, skin);
    } catch {
        MG_Log("merge: SetBlockSkin failed for '" + e.name + "': " + getExceptionInfo());
    }
}

void MG_ApplySkinsAfterPlace(CGameCtnChallenge@ map, array<MGBlock@>@ placed) {
    if (placed.Length == 0) return;
    // Re-scan live blocks and match by name+coord/free pose to apply skins.
    for (uint p = 0; p < placed.Length; p++) {
        MGBlock@ e = placed[p];
        if (e is null || !e.hasSkin) continue;
        for (uint i = 0; i < map.Blocks.Length; i++) {
            CGameCtnBlock@ b = map.Blocks[i];
            if (b.DescId.GetName() != e.name) continue;
            if (e.isFree) {
                Editor::BlockSpec@ spec = Editor::MakeBlockSpec(b);
                if (spec is null || !spec.isFree) continue;
                vec3 mem = e.freePos + vec3(0, g_mgFreeMemOffsetY, 0);
                if (Math::Abs(spec.pos.x - mem.x) > 0.5 || Math::Abs(spec.pos.z - mem.z) > 0.5) continue;
            } else {
                if (int(b.Coord.x) != e.cx || int(b.Coord.y) != e.cy || int(b.Coord.z) != e.cz) continue;
            }
            MG_TryApplyBlockSkin(b, e);
            break;
        }
    }
}

array<CGameCtnBlock@> MG_PreviewCandidates(CGameCtnChallenge@ map, MGBlock@ e) {
    array<CGameCtnBlock@> res;
    vec3 mem = e.freePos + vec3(0, g_mgFreeMemOffsetY, 0);
    for (uint i = 0; i < map.Blocks.Length; i++) {
        CGameCtnBlock@ b = map.Blocks[i];
        if (b.DescId.GetName() != e.name) continue;
        if (e.isFree) {
            Editor::BlockSpec@ spec = Editor::MakeBlockSpec(b);
            if (spec is null || !spec.isFree) continue;
            if (Math::Abs(spec.pos.x - mem.x) > 0.5 || Math::Abs(spec.pos.z - mem.z) > 0.5) continue;
        } else {
            if (int(b.Coord.x) != e.cx || int(b.Coord.y) != e.cy || int(b.Coord.z) != e.cz) continue;
        }
        res.InsertLast(b);
    }
    return res;
}

bool MG_PlaceOnePreviewBlock(MGMergeConflict@ c, MGBlock@ e) {
    CGameCtnBlockInfo@ info = MG_ResolveBlockInfo(e.name);
    if (info is null) {
        MG_Log("preview: unknown block '" + e.name + "' — wireframe fallback");
        c.previewFallback = true;
        return false;
    }
    Editor::BlockSpec@ spec;
    if (e.isFree) {
        vec3 pos = e.freePos + vec3(0, g_mgFreeMemOffsetY, 0);
        vec3 pyr = vec3(e.freeRot.y, e.freeRot.x, e.freeRot.z);
        @spec = Editor::MakeBlockSpec(info, pos, pyr);
    } else {
        @spec = Editor::MakeBlockSpec(info, nat3(e.cx, e.cy, e.cz), e.direction);
    }
    if (spec is null) { c.previewFallback = true; return false; }
    spec.isGhost = true; // always ghost for conflict preview (can share a cell with ours)
    spec.isGround = e.isGround;
    spec.color = CGameCtnBlock::EMapElemColor(4); // Red — make theirs visually distinct
    spec.lmQual = CGameCtnBlock::EMapElemLightmapQuality(MG_LmValue(e.lmQual));
    spec.variant = e.variant;
    array<Editor::BlockSpec@> specs;
    specs.InsertLast(spec);
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { c.previewFallback = true; return false; }
    uint before = map.Blocks.Length;
    array<CGameCtnBlock@> existing = MG_PreviewCandidates(map, e);
    if (!Editor::PlaceBlocks(specs, false)) {
        MG_Log("preview: PlaceBlocks failed for '" + e.name + "' — wireframe fallback");
        c.previewFallback = true;
        return false;
    }
    // The preview is whichever matching block wasn't there before placement.
    array<CGameCtnBlock@> after = MG_PreviewCandidates(map, e);
    for (uint i = 0; i < after.Length; i++) {
        bool wasThere = false;
        for (uint j = 0; j < existing.Length; j++) {
            if (existing[j] is after[i]) { wasThere = true; break; }
        }
        if (wasThere) continue;
        @c.previewBlock = after[i];
        c.previewPlaced = true;
        MG_TryApplyBlockSkin(after[i], e);
        return true;
    }
    if (map.Blocks.Length > before) {
        @c.previewBlock = map.Blocks[map.Blocks.Length - 1];
        c.previewPlaced = true;
        return true;
    }
    MG_Log("preview: placed '" + e.name + "' but could not find the nod — wireframe fallback");
    c.previewFallback = true;
    return false;
}

bool MG_PlaceOnePreviewItem(MGMergeConflict@ c, MGItem@ e) {
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { c.previewFallback = true; return false; }
    CGameItemModel@ model = MG_FindItemModel(map, e.itemModel);
    if (model is null) {
        MG_Log("preview: unknown item '" + e.itemModel + "' — wireframe fallback (custom item may need embedding)");
        c.previewFallback = true;
        return false;
    }
    vec3 pyr = vec3(e.rotation.y, e.rotation.x, e.rotation.z);
    Editor::ItemSpec@ spec = Editor::MakeItemSpec(model, e.position, pyr);
    if (spec is null) { c.previewFallback = true; return false; }
    spec.scale = e.scale;
    spec.color = CGameCtnAnchoredObject::EMapElemColor(MG_ColorValue(e.color));
    spec.lmQual = CGameCtnAnchoredObject::EMapElemLightmapQuality(MG_LmValue(e.lmQual));
    array<Editor::ItemSpec@> specs;
    specs.InsertLast(spec);
    uint before = map.AnchoredObjects.Length;
    if (!Editor::PlaceItems(specs, false)) {
        MG_Log("preview: PlaceItems failed for '" + e.itemModel + "' — wireframe fallback");
        c.previewFallback = true;
        return false;
    }
    // Prefer the last anchored object (newly placed)
    if (map.AnchoredObjects.Length > before) {
        @c.previewItem = map.AnchoredObjects[map.AnchoredObjects.Length - 1];
        c.previewPlaced = true;
        return true;
    }
    c.previewFallback = true;
    return false;
}

bool MG_PlaceOnePreview(MGMergeConflict@ c) {
    if (c.resolution != 0 || !c.hasTheirsPos) return false;
    if (c.section == "block" && c.theirsBlock !is null) return MG_PlaceOnePreviewBlock(c, c.theirsBlock);
    if (c.section == "item" && c.theirsItem !is null) return MG_PlaceOnePreviewItem(c, c.theirsItem);
    return false;
}

// "Only theirs" lifts your live block/item out of the map while it is being looked at.
// E++ specs carry waypoint data, so putting them back restores the exact original.
array<Editor::BlockSpec@> g_mgHiddenOursBlocks;
array<MGBlock@> g_mgHiddenOursBlockEntries;
array<Editor::ItemSpec@> g_mgHiddenOursItems;

CGameCtnAnchoredObject@ MG_FindLiveItem(CGameCtnChallenge@ map, MGItem@ e) {
    for (uint i = 0; i < map.AnchoredObjects.Length; i++) {
        CGameCtnAnchoredObject@ a = map.AnchoredObjects[i];
        if (a.ItemModel is null || a.ItemModel.Id.GetName() != e.itemModel) continue;
        if ((a.AbsolutePositionInMap - e.position).Length() < 0.05) return a;
    }
    return null;
}

void MG_HideOurs(MGMergeConflict@ c) {
    CGameCtnChallenge@ map = GetMap();
    if (map is null || c.resolution != 0) return;
    if (c.oursBlock !is null) {
        array<CGameCtnBlock@> cands = MG_PreviewCandidates(map, c.oursBlock);
        if (cands.Length == 0) return;
        Editor::BlockSpec@ spec = Editor::MakeBlockSpec(cands[0]);
        if (spec is null) return;
        array<CGameCtnBlock@> del = { cands[0] };
        if (!Editor::DeleteBlocks(del, false)) return;
        g_mgHiddenOursBlocks.InsertLast(spec);
        g_mgHiddenOursBlockEntries.InsertLast(c.oursBlock);
    } else if (c.oursItem !is null) {
        CGameCtnAnchoredObject@ a = MG_FindLiveItem(map, c.oursItem);
        if (a is null) return;
        Editor::ItemSpec@ spec = Editor::MakeItemSpec(a);
        if (spec is null) return;
        array<CGameCtnAnchoredObject@> del = { a };
        if (Editor::DeleteItems(del, false)) g_mgHiddenOursItems.InsertLast(spec);
    }
}

void MG_RestoreHiddenOurs() {
    if (g_mgHiddenOursBlocks.Length > 0) {
        if (!Editor::PlaceBlocks(g_mgHiddenOursBlocks, false)) {
            MG_Log("preview: could not put your hidden block(s) back — use Cancel to restore your version");
        } else {
            CGameCtnChallenge@ map = GetMap();
            for (uint i = 0; map !is null && i < g_mgHiddenOursBlockEntries.Length; i++) {
                MGBlock@ e = g_mgHiddenOursBlockEntries[i];
                if (!e.hasSkin) continue;
                array<CGameCtnBlock@> cands = MG_PreviewCandidates(map, e);
                if (cands.Length > 0) MG_TryApplyBlockSkin(cands[0], e);
            }
        }
    }
    if (g_mgHiddenOursItems.Length > 0) {
        if (!Editor::PlaceItems(g_mgHiddenOursItems, false)) {
            MG_Log("preview: could not put your hidden item(s) back — use Cancel to restore your version");
        }
    }
    g_mgHiddenOursBlocks.RemoveRange(0, g_mgHiddenOursBlocks.Length);
    g_mgHiddenOursBlockEntries.RemoveRange(0, g_mgHiddenOursBlockEntries.Length);
    g_mgHiddenOursItems.RemoveRange(0, g_mgHiddenOursItems.Length);
}

// Ghost models exist only for what is currently being looked at, so the scene stays readable.
void MG_RefreshConflictPreviews() {
    MG_ClearConflictPreviews();
    if (!g_mgMergeActive || g_mgViewMode == 1) return;
    uint placed = 0;
    for (uint i = 0; i < g_mgConflicts.Length; i++) {
        if (!g_mgShowAllConflicts && int(i) != g_mgConflictFocus) continue;
        if (g_mgViewMode == 2) MG_HideOurs(g_mgConflicts[i]);
        if (MG_PlaceOnePreview(g_mgConflicts[i])) placed++;
    }
    MG_Log("conflict previews: placed " + placed + " real models");
}

void MG_PlaceConflictPreviews() {
    if (GetMap() is null) return;
    g_mgShowAllConflicts = false;
    g_mgViewMode = 0;
    int first = MG_NextUnresolvedConflict(-1);
    MG_SetConflictFocus(first < 0 ? 0 : first);
}

void MG_SetConflictFocus(int index) {
    if (index < 0 || index >= int(g_mgConflicts.Length)) return;
    g_mgConflictFocus = index;
    MG_RefreshConflictPreviews();
    MG_FocusConflictCamera(index);
}

void MG_SetConflictViewMode(int mode) {
    if (mode == g_mgViewMode) return;
    g_mgViewMode = mode;
    MG_RefreshConflictPreviews();
}

void MG_SetShowAllConflicts(bool all) {
    if (all == g_mgShowAllConflicts) return;
    g_mgShowAllConflicts = all;
    MG_RefreshConflictPreviews();
}

void MG_FocusConflictCamera(int index) {
    if (index < 0 || index >= int(g_mgConflicts.Length)) return;
    MGMergeConflict@ c = g_mgConflicts[index];
    g_mgLastCamTarget = vec3(-99999, -99999, -99999); // allow re-aim
    bool preferOurs = g_mgViewMode == 1;
    if (preferOurs && c.hasOursPos) MG_JumpCamera(c.oursPos);
    else if (c.hasTheirsPos) MG_JumpCamera(c.theirsPos);
    else if (c.hasOursPos) MG_JumpCamera(c.oursPos);
}

// "RoadTechCurve2" -> "Road Tech Curve 2"; item paths -> file name without ".Item.Gbx".
string MG_PrettyName(const string&in raw) {
    if (raw == "(deleted)") return "nothing";
    string s = raw;
    int slash = -1;
    for (int k = 0; k < s.Length; k++) {
        if (s[k] == 0x2F || s[k] == 0x5C) slash = k;
    }
    if (slash >= 0) s = s.SubStr(slash + 1);
    string lower = s.ToLower();
    if (lower.EndsWith(".item.gbx")) s = s.SubStr(0, s.Length - 9);
    else if (lower.EndsWith(".block.gbx")) s = s.SubStr(0, s.Length - 10);
    string res = "";
    for (int i = 0; i < s.Length; i++) {
        uint8 ch = s[i];
        if (i > 0) {
            uint8 prev = s[i - 1];
            bool up = ch >= 0x41 && ch <= 0x5A;
            bool dig = ch >= 0x30 && ch <= 0x39;
            bool prevLower = prev >= 0x61 && prev <= 0x7A;
            bool prevDig = prev >= 0x30 && prev <= 0x39;
            if ((up && (prevLower || prevDig)) || (dig && !prevDig && prev != 0x20)) res += " ";
        }
        res += s.SubStr(i, 1);
    }
    return res;
}

int MG_NextUnresolvedConflict(int from) {
    for (uint i = 0; i < g_mgConflicts.Length; i++) {
        int ix = (from + 1 + int(i)) % int(g_mgConflicts.Length);
        if (g_mgConflicts[ix].resolution == 0) return ix;
    }
    return -1;
}

int MG_PrevUnresolvedConflict(int from) {
    int n = int(g_mgConflicts.Length);
    for (int i = 1; i <= n; i++) {
        int ix = ((from - i) % n + n) % n;
        if (g_mgConflicts[ix].resolution == 0) return ix;
    }
    return -1;
}

int MG_CountUnresolvedConflicts() {
    int n = 0;
    for (uint i = 0; i < g_mgConflicts.Length; i++) {
        if (g_mgConflicts[i].resolution == 0) n++;
    }
    return n;
}

string MG_FriendlyConflictTitle(MGMergeConflict@ c) {
    if (c.section == "mapInfo") return "Map details differ";
    if (c.section == "embedded") return "Custom embedded files differ";
    if (c.section == "media") return "You both changed the MediaTracker clips (intro, in-game or end cameras)";
    if (c.kind == 6) return "You each put the start somewhere different — a map can only have one";
    if (c.kind == 2) return "You changed this — they removed it";
    if (c.kind == 3) return "You removed this — they changed it";
    if (c.kind == 0) return "You both added something different here";
    return "You both changed this spot differently";
}

string MG_FriendlySideLabel(const string&in summary, bool isYours) {
    if (summary == "(deleted)") return isYours ? "Nothing (you removed it)" : "Nothing (they removed it)";
    if (summary.Length == 0) return isYours ? "Your version" : "Their version";
    return summary;
}

void MG_ClearConflictPreviews() {
    array<CGameCtnBlock@> blocks;
    array<CGameCtnAnchoredObject@> items;
    for (uint i = 0; i < g_mgConflicts.Length; i++) {
        MGMergeConflict@ c = g_mgConflicts[i];
        if (c.previewBlock !is null) blocks.InsertLast(c.previewBlock);
        if (c.previewItem !is null) items.InsertLast(c.previewItem);
        @c.previewBlock = null;
        @c.previewItem = null;
        c.previewPlaced = false;
        c.previewFallback = false;
    }
    if (blocks.Length > 0) {
        try { Editor::DeleteBlocks(blocks, false); } catch {
            MG_Log("preview clear: DeleteBlocks failed: " + getExceptionInfo());
        }
    }
    if (items.Length > 0) {
        try { Editor::DeleteItems(items, false); } catch {
            MG_Log("preview clear: DeleteItems failed: " + getExceptionInfo());
        }
    }
    MG_RestoreHiddenOurs();
}

// ------------------------- merge state -------------------------

bool g_mgMergeActive = false;
string g_mgMergeRepoDir = "";
string g_mgMergeBranch = "";      // ours (current)
string g_mgMergeSource = "";      // theirs (source branch / origin label)
string g_mgMergeOursTip = "";
string g_mgMergeTheirsTip = "";
string g_mgMergeBaseSha = "";
array<MGMergeConflict@> g_mgConflicts;
array<string> g_mgAppliedChanges;
MGManifest@ g_mgMergedClean;      // ours + clean takes (conflict resolutions applied at finalize)
MGMapInfo@ g_mgTheirsMapInfo;     // for metadata conflict resolutions
MGManifest@ g_mgTheirsManifest;   // full theirs (embedded take-theirs)
string g_mgMergeStatus = "";
int g_mgMergeSel = 0;             // source branch combo selection
bool g_mgMergePushAfter = false;  // everyday Apply & Share / Update after merge
string g_mgMergePendingRemoteGit = ""; // git sha to write into sync state after merge+push
int g_mgConflictFocus = 0;           // which conflict is being looked at
bool g_mgShowAllConflicts = false;   // developer tools: show every unresolved conflict at once
int g_mgViewMode = 0;                // 0 = both versions, 1 = only yours, 2 = only theirs

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
            c.oursPos = MG_BlockWorldPos(o.src[oi]); c.hasOursPos = true; @c.oursBlock = o.src[oi];
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
            c.oursPos = MG_BlockWorldPos(o.src[oi]); c.hasOursPos = true; @c.oursBlock = o.src[oi];
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
            c.oursPos = MG_BlockWorldPos(o.src[oi]); c.hasOursPos = true; @c.oursBlock = o.src[oi];
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
            c.oursPos = MG_ItemWorldPos(o.src[oi]); c.hasOursPos = true; @c.oursItem = o.src[oi];
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
            c.oursPos = MG_ItemWorldPos(o.src[oi]); c.hasOursPos = true; @c.oursItem = o.src[oi];
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
            c.oursPos = MG_ItemWorldPos(o.src[oi]); c.hasOursPos = true; @c.oursItem = o.src[oi];
            c.theirsPos = MG_ItemWorldPos(t.src[ti]); c.hasTheirsPos = true;
            g_mgConflicts.InsertLast(c);
        }
    }
}

// ------------------------- same-cell block alignment -------------------------
// Several blocks can share a cell (terrain + a block on it, stacked pieces). Their
// stored keys get "#2", "#3" by sort order, so a change to one shifts the others and
// the base/ours/theirs entries pair up wrongly. Re-key each shared cell by identity:
// identical first, then same block name, then whatever is left (a type change).

class MGCellSides {
    array<int> b;
    array<int> o;
    array<int> t;
}

void MG_CollectCells(array<MGBlock>@ arr, int side, dictionary@ cells, array<string>@ order) {
    for (uint i = 0; i < arr.Length; i++) {
        string k = MG_BaseKey(arr[i].key);
        MGCellSides@ g;
        if (!cells.Get(k, @g) || g is null) {
            @g = MGCellSides();
            cells.Set(k, @g);
            order.InsertLast(k);
        }
        if (side == 0) g.b.InsertLast(int(i));
        else if (side == 1) g.o.InsertLast(int(i));
        else g.t.InsertLast(int(i));
    }
}

bool MG_CellPairs(MGBlock@ refB, MGBlock@ x, int pass) {
    if (pass == 0) return refB.name == x.name && refB.contentJson == x.contentJson;
    if (pass == 1) return refB.name == x.name;
    return MG_IsAutoBlock(refB.name) == MG_IsAutoBlock(x.name);
}

// side 1 = ours, 2 = theirs. Theirs may also pair with ours-only slots (add/add).
void MG_MatchCellSide(MGManifest@ baseMan, MGManifest@ oursMan, array<MGBlock>@ sideArr,
                      array<int>@ sideIdx, array<int>@ sb, array<int>@ so, array<int>@ st, int side) {
    array<bool> used;
    used.Resize(sideIdx.Length);
    for (uint j = 0; j < used.Length; j++) used[j] = false;
    for (int pass = 0; pass < 3; pass++) {
        for (uint s = 0; s < sb.Length; s++) {
            if ((side == 1 ? so[s] : st[s]) >= 0) continue;
            MGBlock@ refB = null;
            if (sb[s] >= 0) @refB = baseMan.blocks[sb[s]];
            else if (side == 2 && so[s] >= 0) @refB = oursMan.blocks[so[s]];
            if (refB is null) continue;
            for (uint j = 0; j < sideIdx.Length; j++) {
                if (used[j]) continue;
                if (!MG_CellPairs(refB, sideArr[sideIdx[j]], pass)) continue;
                used[j] = true;
                if (side == 1) so[s] = sideIdx[j]; else st[s] = sideIdx[j];
                break;
            }
        }
    }
    for (uint j = 0; j < sideIdx.Length; j++) {
        if (used[j]) continue;
        sb.InsertLast(-1);
        so.InsertLast(side == 1 ? sideIdx[j] : -1);
        st.InsertLast(side == 2 ? sideIdx[j] : -1);
    }
}

void MG_AlignSharedCellKeys(MGManifest@ baseMan, MGManifest@ oursMan, MGManifest@ theirsMan) {
    dictionary cells;
    array<string> order;
    MG_CollectCells(baseMan.blocks, 0, cells, order);
    MG_CollectCells(oursMan.blocks, 1, cells, order);
    MG_CollectCells(theirsMan.blocks, 2, cells, order);
    int realigned = 0;
    for (uint k = 0; k < order.Length; k++) {
        MGCellSides@ g;
        cells.Get(order[k], @g);
        if (g is null || (g.b.Length <= 1 && g.o.Length <= 1 && g.t.Length <= 1)) continue;
        array<int> sb, so, st;
        for (uint i = 0; i < g.b.Length; i++) { sb.InsertLast(g.b[i]); so.InsertLast(-1); st.InsertLast(-1); }
        MG_MatchCellSide(baseMan, oursMan, oursMan.blocks, g.o, sb, so, st, 1);
        MG_MatchCellSide(baseMan, oursMan, theirsMan.blocks, g.t, sb, so, st, 2);
        for (uint s = 0; s < sb.Length; s++) {
            string key = (s == 0) ? order[k] : order[k] + "#" + (s + 1);
            if (sb[s] >= 0) baseMan.blocks[sb[s]].key = key;
            if (so[s] >= 0) oursMan.blocks[so[s]].key = key;
            if (st[s] >= 0) theirsMan.blocks[st[s]].key = key;
        }
        realigned++;
    }
    if (realigned > 0) MG_Log("merge: aligned " + realigned + " shared cell(s) by block identity");
}

bool MG_KeyIsAutoOnly(MGBlockIndex@ b, MGBlockIndex@ o, MGBlockIndex@ t, const string&in key) {
    int bi = b.IndexOf(key), oi = o.IndexOf(key), ti = t.IndexOf(key);
    if (bi < 0 && oi < 0 && ti < 0) return false;
    if (bi >= 0 && !MG_IsAutoBlock(b.src[bi].name)) return false;
    if (oi >= 0 && !MG_IsAutoBlock(o.src[oi].name)) return false;
    if (ti >= 0 && !MG_IsAutoBlock(t.src[ti].name)) return false;
    return true;
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
        if (MG_KeyIsAutoOnly(bB, oB, tB, key)) continue; // ours kept; the game regenerates clips
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

    // embedded: fingerprint set compare when entries exist; else entry-count
    string oursEmb = MG_EmbeddedFingerprintSet(oursMan);
    string theirsEmb = MG_EmbeddedFingerprintSet(theirsMan);
    string baseEmb = MG_EmbeddedFingerprintSet(baseMan);
    if (oursEmb != theirsEmb) {
        if (oursEmb == baseEmb) {
            g_mgMergedClean.embeddedEntryCount = theirsMan.embeddedEntryCount;
            g_mgMergedClean.embeddedEntries.RemoveRange(0, g_mgMergedClean.embeddedEntries.Length);
            for (uint i = 0; i < theirsMan.embeddedEntries.Length; i++) {
                g_mgMergedClean.embeddedEntries.InsertLast(theirsMan.embeddedEntries[i]);
            }
            g_mgAppliedChanges.InsertLast("take theirs: embedded (" + theirsMan.embeddedEntryCount + " entries)");
        } else if (theirsEmb != baseEmb) {
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

// Restores the canonical form: base keys, canonical sort, deterministic re-suffixing. Without this, merged manifests
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

        if (c.kind == 6) {
            if (c.resolution != 2) continue; // keep yours: theirs was already held back
            if (c.oursSection == "block") {
                for (uint i = 0; i < g_mgMergedClean.blocks.Length; i++) {
                    if (g_mgMergedClean.blocks[i].key == c.oursKey) { g_mgMergedClean.blocks.RemoveRange(i, 1); break; }
                }
            } else {
                for (uint i = 0; i < g_mgMergedClean.items.Length; i++) {
                    if (g_mgMergedClean.items[i].key == c.oursKey) { g_mgMergedClean.items.RemoveRange(i, 1); break; }
                }
            }
            if (c.theirsBlock !is null) g_mgMergedClean.blocks.InsertLast(c.theirsBlock);
            if (c.theirsItem !is null) g_mgMergedClean.items.InsertLast(c.theirsItem);
            continue;
        }

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
        } else if (c.section == "media") {
            g_mgMediaTakeTheirs = c.resolution == 2;
        } else if (c.section == "embedded") {
            if (c.resolution == 2 && g_mgTheirsManifest !is null) {
                g_mgMergedClean.embeddedEntryCount = g_mgTheirsManifest.embeddedEntryCount;
                g_mgMergedClean.embeddedEntries.RemoveRange(0, g_mgMergedClean.embeddedEntries.Length);
                for (uint i = 0; i < g_mgTheirsManifest.embeddedEntries.Length; i++) {
                    g_mgMergedClean.embeddedEntries.InsertLast(g_mgTheirsManifest.embeddedEntries[i]);
                }
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
        if (MG_IsAutoBlock(lb.entry.name)) continue;
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
        if (MG_IsAutoBlock(lb.entry.name)) continue;
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
    return MG_LoadItemModelFromFile(name);
}

// True when blocks match aside from waypoint props — keep live nod (props not re-writable).
bool MG_BlockEqualsIgnoringWaypoint(const MGBlock&in a, const MGBlock&in b) {
    if (a.key != b.key || a.name != b.name) return false;
    if (a.isFree != b.isFree || a.isGhost != b.isGhost || a.isGround != b.isGround) return false;
    if (a.cx != b.cx || a.cy != b.cy || a.cz != b.cz) return false;
    if (a.direction != b.direction || a.variant != b.variant || a.subVariant != b.subVariant) return false;
    if (a.color != b.color || a.lmQual != b.lmQual) return false;
    if (a.hasFree != b.hasFree) return false;
    if (a.hasFree && (!MG_Vec3Eq(a.freePos, b.freePos) || !MG_Vec3Eq(a.freeRot, b.freeRot))) return false;
    if (a.hasSkin != b.hasSkin) return false;
    return true;
}

bool MG_ItemEqualsIgnoringWaypoint(const MGItem&in a, const MGItem&in b) {
    if (a.key != b.key || a.itemModel != b.itemModel) return false;
    if (!MG_Vec3Eq(a.position, b.position) || !MG_Vec3Eq(a.rotation, b.rotation)) return false;
    if (a.scale != b.scale || a.color != b.color || a.lmQual != b.lmQual) return false;
    return true;
}

// Transforms the live map into `final`: deletes/removes/places via E++, sets mapInfo.
bool MG_ApplyMerged(CGameCtnChallenge@ map, MGManifest@ finalAll) {
    MGManifest@ final = MG_WithoutAutoBlocks(finalAll);
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
        MGBlock@ fb = finalB.src[finalB.IndexOf(key)];
        if (MG_BlockEquals(live.blocks[i].entry, fb)) continue;
        if (MG_BlockEqualsIgnoringWaypoint(live.blocks[i].entry, fb)) {
            // Only waypoint props differ — preserve live block (props not re-applicable).
            MG_Log("merge apply: preserving waypoint block '" + fb.name + "' in place");
            continue;
        }
        blocksToDelete.InsertLast(live.blocks[i].nod);
    }
    for (uint i = 0; i < final.blocks.Length; i++) {
        MGBlock@ fb = final.blocks[i];
        int liveIx = -1;
        live.blockByKey.Get(fb.key, liveIx);
        if (liveIx < 0) {
            blocksToPlace.InsertLast(fb);
        } else if (!MG_BlockEquals(live.blocks[liveIx].entry, fb) &&
                   !MG_BlockEqualsIgnoringWaypoint(live.blocks[liveIx].entry, fb)) {
            blocksToPlace.InsertLast(fb);
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
        MGItem@ fi = finalI.src[finalI.IndexOf(key)];
        if (MG_ItemEquals(live.items[i].entry, fi)) continue;
        if (MG_ItemEqualsIgnoringWaypoint(live.items[i].entry, fi)) {
            MG_Log("merge apply: preserving waypoint item '" + fi.itemModel + "' in place");
            continue;
        }
        itemsToDelete.InsertLast(live.items[i].nod);
    }
    for (uint i = 0; i < final.items.Length; i++) {
        MGItem@ fi = final.items[i];
        int liveIx = -1;
        live.itemByKey.Get(fi.key, liveIx);
        if (liveIx < 0) {
            itemsToPlace.InsertLast(fi);
        } else if (!MG_ItemEquals(live.items[liveIx].entry, fi) &&
                   !MG_ItemEqualsIgnoringWaypoint(live.items[liveIx].entry, fi)) {
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
            CGameCtnBlockInfo@ info = MG_ResolveBlockInfo(e.name);
            if (info is null) {
                MG_Log("merge apply: unknown block '" + e.name + "' (key " + e.key + ") — skipped");
                continue;
            }
            Editor::BlockSpec@ spec;
            if (e.isFree) {
                vec3 pos = e.freePos + vec3(0, g_mgFreeMemOffsetY, 0);        // back to E++ memory space
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
                MG_Log("merge apply: NOTE - waypoint props on '" + e.name + "' are not re-writable; model placed");
            }
            specs.InsertLast(spec);
        }
        if (specs.Length > 0 && !Editor::PlaceBlocks(specs, true)) {
            MG_Log("merge apply: PlaceBlocks failed");
            return false;
        }
        MG_ApplySkinsAfterPlace(map, blocksToPlace);
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
    // Drop any temporary ghost/item previews before wiping conflict list.
    if (g_mgConflicts.Length > 0) MG_ClearConflictPreviews();
    g_mgMergeActive = false;
    g_mgConflicts.RemoveRange(0, g_mgConflicts.Length);
    g_mgAppliedChanges.RemoveRange(0, g_mgAppliedChanges.Length);
    @g_mgMergedClean = null;
    @g_mgTheirsMapInfo = null;
    @g_mgTheirsManifest = null;
    g_mgMediaTakeTheirs = false;
    g_mgMergeStatus = "";
    g_mgMarkersLogged = false;
    g_mgMergePendingRemoteGit = "";
    g_mgConflictFocus = 0;
    g_mgShowAllConflicts = false;
    g_mgViewMode = 0;
    g_mgLastCamTarget = vec3(-99999, -99999, -99999);
}

bool MG_RestoreOursBlob(CGameCtnChallenge@ map, const string&in repoDir, const string&in oursTip) {
    string parents, manifest, blob, author, message;
    int64 time;
    if (!MG_ReadCommit(repoDir, oursTip, parents, manifest, blob, author, message, time)) return false;
    string blobPath = repoDir + "/objects/blobs/" + blob + ".gbx";
    if (!IO::FileExists(blobPath)) return false;
    string mapPath = MG_MapAbsPath(map);
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
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("merge: no map open"); g_mgRepoBusy = false; g_mgMergeStatus = "no map"; return; }
    MG_RebuildMergeSources();
    if (g_mgMergeSel < 0 || g_mgMergeSel >= int(g_mgMergeSources.Length)) {
        MG_Log("merge: pick a source version line first"); g_mgRepoBusy = false; return;
    }
    string source = g_mgMergeSources[g_mgMergeSel];
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
    string oursBranch = MG_CurrentBranch(repoDir);
    if (source == oursBranch) { MG_Log("merge: source is the current version line"); g_mgRepoBusy = false; return; }
    string oursTip = MG_TipSha(repoDir, oursBranch);
    string theirsTip = source.StartsWith("origin/")
        ? GH_OriginTipSha(repoDir, source.SubStr(7))
        : MG_TipSha(repoDir, source);
    MG_MergeFromTips(repoDir, oursTip, theirsTip, source, oursBranch, false, "");
}

// Tip-based merge entry used by branch UI and remote Update/Share diverge path.
void MG_MergeFromTips(const string&in repoDir, const string&in oursTip, const string&in theirsTip,
                      const string&in sourceLabel, const string&in oursBranch,
                      bool pushAfter, const string&in pendingRemoteGit) {
    g_mgRepoBusy = true;
    g_mgMergeStatus = "combining...";
    g_mgMergePushAfter = pushAfter;
    g_mgMergePendingRemoteGit = pendingRemoteGit;
    MG_CalibrateWorldSpace(GetMap());
    CGameCtnChallenge@ map = GetMap();
    if (map is null) { MG_Log("merge: no map open"); g_mgRepoBusy = false; g_mgMergeStatus = "no map"; return; }
    if (oursTip.Length == 0 || theirsTip.Length == 0) {
        MG_Log("merge: both sides need commits first"); g_mgRepoBusy = false; g_mgMergeStatus = "missing tips"; return;
    }
    if (oursTip == theirsTip) {
        MG_Log("merge: already the same tip"); g_mgRepoBusy = false; g_mgMergeStatus = "already up to date"; return;
    }
    string baseSha = MG_MergeBase(repoDir, oursTip, theirsTip);
    if (baseSha.Length == 0) {
        MG_Log("merge: no common ancestor between local and '" + sourceLabel + "'");
        g_mgRepoBusy = false; g_mgMergeStatus = "no common base";
        return;
    }
    if (baseSha == oursTip) {
        // Theirs is a fast-forward of ours — move branch tip to theirs and restore.
        MG_Log("merge: fast-forward to '" + sourceLabel + "'");
        MG_WriteTextFile(repoDir + "/refs/heads/" + oursBranch, theirsTip);
        g_mgRepoTip = theirsTip;
        string p, m, b, a, msg; int64 t;
        if (MG_ReadCommit(repoDir, theirsTip, p, m, b, a, msg, t)) {
            string mapPath = MG_MapAbsPath(map);
            MG_InstallCustomFilesFor(repoDir, theirsTip); // loaded when the map reopens
            try { MG_CopyFile(repoDir + "/objects/blobs/" + b + ".gbx", mapPath); } catch { }
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
        }
        if (pendingRemoteGit.Length > 0) GH_WriteRemoteState(repoDir, oursBranch, theirsTip, pendingRemoteGit);
        g_mgMergeStatus = "fast-forwarded to '" + sourceLabel + "'";
        g_mgRepoBusy = false;
        if (pushAfter) GH_PushCoro();
        return;
    }

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
    if (oursLiveSha != oursTipManifest || MG_MediaChangedSince(map, repoDir, oursTip, false)) {
        g_mgMergeStatus = "merge refused: uncommitted changes (save a version first)";
        MG_Log("merge: " + g_mgMergeStatus);
        g_mgRepoBusy = false;
        return;
    }

    string p2, m2, b2, a2, msg2;
    int64 t2;
    if (!MG_ReadCommit(repoDir, theirsTip, p2, m2, b2, a2, msg2, t2)) {
        MG_Log("merge: theirs commit unreadable"); g_mgRepoBusy = false; return;
    }
    string theirsManifestSha = m2;
    string theirsBlobSha = b2;
    if (!MG_ReadCommit(repoDir, baseSha, p2, m2, b2, a2, msg2, t2)) {
        MG_Log("merge: base commit unreadable"); g_mgRepoBusy = false; return;
    }
    MGManifest@ theirsMan = MG_ReadManifest(repoDir + "/objects/manifests/" + theirsManifestSha + ".json");
    MGManifest@ baseMan = MG_ReadManifest(repoDir + "/objects/manifests/" + m2 + ".json");
    if (theirsMan is null || baseMan is null) {
        MG_Log("merge: stored manifests unreadable"); g_mgRepoBusy = false; return;
    }

    // Custom items: install the files their version shared, then make sure every item
    // they placed can be found before anything in the map is touched.
    array<string>@ installedItems = MG_InstallCustomFilesFor(repoDir, theirsTip);
    if (installedItems.Length > 0) {
        try { Editor::ReloadItemsAsync(installedItems); } catch {
            MG_Log("items: reloading new items failed: " + getExceptionInfo());
        }
    }
    MG_EnsureTheirsEmbeddedAvailable(repoDir, theirsBlobSha, theirsMan);
    array<string>@ missingItems = MG_MissingCustomItems(map, theirsMan);
    if (missingItems.Length > 0) {
        string names = "";
        for (uint i = 0; i < missingItems.Length && i < 3; i++) names += (i > 0 ? ", " : "") + MG_PrettyName(missingItems[i]);
        if (missingItems.Length > 3) names += " and " + (missingItems.Length - 3) + " more";
        if (installedItems.Length > 0) {
            g_mgMergeStatus = "new custom items were installed — reopen the map, then Update again";
        } else {
            g_mgMergeStatus = "their version uses custom items you don't have (" + names +
                              ") — ask them to Share again with the latest MapGit, or send you the files";
        }
        MG_Log("merge: stopped before changing your map: " + g_mgMergeStatus);
        UI::ShowNotification("MapGit", g_mgMergeStatus);
        g_mgRepoBusy = false;
        return;
    }

    MG_ClearMergeState();
    g_mgMergePushAfter = pushAfter;
    g_mgMergePendingRemoteGit = pendingRemoteGit;
    g_mgAutoBlockCache.DeleteAll();
    g_mgStartCache.DeleteAll();
    MG_AlignSharedCellKeys(baseMan, oursMan, theirsMan);
    @g_mgMergedClean = MGManifest();
    @g_mgMergedClean.mapInfo = oursMan.mapInfo;
    for (uint i = 0; i < oursMan.blocks.Length; i++) g_mgMergedClean.blocks.InsertLast(oursMan.blocks[i]);
    for (uint i = 0; i < oursMan.items.Length; i++) g_mgMergedClean.items.InsertLast(oursMan.items[i]);
    g_mgMergedClean.embeddedEntryCount = oursMan.embeddedEntryCount;
    for (uint i = 0; i < oursMan.embeddedEntries.Length; i++) {
        g_mgMergedClean.embeddedEntries.InsertLast(oursMan.embeddedEntries[i]);
    }
    @g_mgTheirsMapInfo = theirsMan.mapInfo;
    @g_mgTheirsManifest = theirsMan;
    g_mgMergeRepoDir = repoDir;
    g_mgMergeBranch = oursBranch;
    g_mgMergeSource = sourceLabel;
    g_mgMergeOursTip = oursTip;
    g_mgMergeTheirsTip = theirsTip;
    g_mgMergeBaseSha = baseSha;

    yield();
    MG_RunMerge(baseMan, oursMan, theirsMan);
    MG_EnforceSingleStart(oursMan);
    MG_MergeMedia(repoDir, baseSha, oursTip, theirsTip);

    if (g_mgConflicts.Length > 0) {
        g_mgMergeActive = true;
        g_mgMergeStatus = g_mgConflicts.Length + " conflicts — resolve in the world, then apply";
        MG_Log("merge: " + g_mgMergeStatus);
        MG_PlaceConflictPreviews();
        g_mgRepoBusy = false;
        return;
    }

    g_mgMergeActive = true;
    g_mgMergeStatus = "clean — applying " + g_mgAppliedChanges.Length + " changes...";
    MG_Log("merge: clean — " + g_mgAppliedChanges.Length + " changes from '" + sourceLabel + "'");
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
    int starts = MG_CountStarts(final);
    if (starts > 1 && starts > g_mgOursStartCount) {
        g_mgMergeStatus = "the combined map would have " + starts + " starts — pick one";
        MG_Log("merge apply: refused — combined map would have " + starts + " start lines");
        g_mgRepoBusy = false;
        return;
    }

    // Remove temporary ghost/item previews before the real apply so they are not
    // part of the live index or the merge commit.
    MG_ClearConflictPreviews();

    if (!MG_ApplyMerged(map, final)) {
        MG_Log("merge apply: apply step failed — restoring");
        MG_RestoreOursBlob(map, g_mgMergeRepoDir, g_mgMergeOursTip);
        MG_ClearMergeState();
        g_mgMergePushAfter = false;
        g_mgRepoBusy = false;
        return;
    }
    if (g_mgMediaTakeTheirs) {
        string tp, tm, tb, ta, tmsg;
        int64 tt;
        bool tookMedia = false;
        if (MG_ReadCommit(g_mgMergeRepoDir, g_mgMergeTheirsTip, tp, tm, tb, ta, tmsg, tt)) {
            tookMedia = MG_ApplyTheirsMedia(map, g_mgMergeRepoDir + "/objects/blobs/" + tb + ".gbx", tb);
        }
        if (!tookMedia) {
            UI::ShowNotification("MapGit", "Couldn't bring in their MediaTracker clips — yours were kept.");
        }
    }
    yield();

    MGManifest@ rebuilt = MG_WithoutAutoBlocks(MG_BuildManifest(map));
    MGManifest@ expected = MG_WithoutAutoBlocks(final);
    string tmpR = IO::FromStorageFolder("merge-verify-rebuilt.json");
    MG_WriteManifest(rebuilt, tmpR);
    string tmpF = IO::FromStorageFolder("merge-verify-final.json");
    MG_WriteManifest(expected, tmpF);
    yield();
    string hashR = MG_Sha256File(tmpR);
    string hashF = MG_Sha256File(tmpF);
    if (hashR != hashF) {
        MG_Log("merge apply: VERIFICATION FAILED (rebuilt " + MG_Short(hashR) + " != expected " + MG_Short(hashF) +
               ") — restoring. Rebuilt: " + rebuilt.blocks.Length + " blocks / " + rebuilt.items.Length +
               " items; expected: " + expected.blocks.Length + " / " + expected.items.Length);
        MG_RestoreOursBlob(map, g_mgMergeRepoDir, g_mgMergeOursTip);
        MG_ClearMergeState();
        g_mgMergePushAfter = false;
        g_mgRepoBusy = false;
        g_mgMergeStatus = "verification failed — restored";
        return;
    }
    MG_Log("merge apply: verified (" + MG_Short(hashR) + ")");

    g_mgMergeSecondParent = g_mgMergeTheirsTip;
    g_mgCommitMsg = T("Combined '", "Merge '") + g_mgMergeSource + T("' into '", "' into '") + g_mgMergeBranch + "'";
    string srcBranch = g_mgMergeSource;
    string repoDir = g_mgMergeRepoDir;
    string branch = g_mgMergeBranch;
    string pendingGit = g_mgMergePendingRemoteGit;
    bool pushAfter = g_mgMergePushAfter;
    MG_ClearMergeState();
    g_mgMergeStatus = "merged '" + srcBranch + "'";
    MG_CommitCoro();

    // Advance sync bookkeeping after a successful merge commit when we know the remote git tip.
    if (pendingGit.Length > 0) {
        string tip = MG_TipSha(repoDir, branch);
        if (tip.Length > 0) GH_WriteRemoteState(repoDir, branch, tip, pendingGit);
    }
    g_mgRemoteSentence = "";
    g_mgNotifiedRemoteGit = "";

    if (pushAfter) {
        g_mgRepoBusy = false;
        GH_PushCoro();
    } else {
        g_mgRepoBusy = false;
    }
}

// ------------------------- merge UI -------------------------

void MG_ResolutionButton(MGMergeConflict@ c, int res, const string&in label) {
    bool active = (c.resolution == res);
    if (active) UI::BeginDisabled();
    if (UI::Button(label + "##c" + c.key + res)) {
        c.resolution = res;
        int next = MG_NextUnresolvedConflict(g_mgConflictFocus);
        if (next >= 0 && g_mgConflicts[g_mgConflictFocus].resolution != 0) MG_SetConflictFocus(next);
        else MG_RefreshConflictPreviews();
    }
    if (active) UI::EndDisabled();
}

array<string> g_mgMergeSources; // branches + optional origin/<branch>

void MG_RebuildMergeSources() {
    g_mgMergeSources.RemoveRange(0, g_mgMergeSources.Length);
    for (uint i = 0; i < g_mgBranches.Length; i++) g_mgMergeSources.InsertLast(g_mgBranches[i]);
    CGameCtnChallenge@ map = GetMap();
    if (map is null) return;
    string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
    string branch = MG_CurrentBranch(repoDir);
    string originTip = GH_OriginTipSha(repoDir, branch);
    string localTip = MG_TipSha(repoDir, branch);
    if (originTip.Length > 0 && originTip != localTip) {
        string originOpt = "origin/" + branch;
        bool have = false;
        for (uint i = 0; i < g_mgMergeSources.Length; i++) {
            if (g_mgMergeSources[i] == originOpt) { have = true; break; }
        }
        if (!have) g_mgMergeSources.InsertLast(originOpt);
    }
}

void MG_MergeOriginCoro() {
    if (g_mgRepoBusy) return;
    startnew(MG_MergeOriginWork);
}

void MG_MergeOriginWork() {
    g_mgRepoBusy = true;
    try {
        CGameCtnChallenge@ map = GetMap();
        if (map is null) { g_mgRepoBusy = false; return; }
        string repoDir = MG_ReposRoot() + "/" + MG_RepoIdFor(MG_MapFileOf(map));
        string branch = MG_CurrentBranch(repoDir);
        MG_MergeFromTips(repoDir, MG_TipSha(repoDir, branch), GH_OriginTipSha(repoDir, branch),
                         "origin/" + branch, branch, false, "");
    } catch {
        MG_Log("merge: EXCEPTION - " + getExceptionInfo());
        MG_ClearMergeState();
        g_mgRepoBusy = false;
    }
}

void RenderMergeSection() {
    UI::Separator();
    UI::Text(T("Combine version lines", "Merge") + ":");
    if (!g_mgMergeActive) {
        MG_RebuildMergeSources();
        if (g_mgMergeSources.Length > 1) {
            if (g_mgMergeSel < 0 || g_mgMergeSel >= int(g_mgMergeSources.Length)) g_mgMergeSel = 0;
            if (UI::BeginCombo("##mg-merge-src", g_mgMergeSources[g_mgMergeSel])) {
                for (uint i = 0; i < g_mgMergeSources.Length; i++) {
                    if (UI::Selectable(g_mgMergeSources[i], int(i) == g_mgMergeSel)) g_mgMergeSel = int(i);
                }
                UI::EndCombo();
            }
            UI::BeginDisabled(g_mgRepoBusy);
            UI::SameLine();
            if (UI::Button(T("Combine", "Merge"))) {
                string src = g_mgMergeSources[g_mgMergeSel];
                if (src.StartsWith("origin/")) MG_MergeOriginCoro();
                else MG_MergeCoro();
            }
            UI::EndDisabled();
        } else {
            UI::TextDisabled("  (create a second version line above, or Update to fetch origin)");
        }
    } else {
        if (g_mgMergeStatus.Length > 0) UI::Text(g_mgMergeStatus);
        if (g_mgConflicts.Length > 0) {
            bool allResolved = true;
            for (uint i = 0; i < g_mgConflicts.Length; i++) {
                if (g_mgConflicts[i].resolution == 0) { allResolved = false; break; }
            }
            bool showAll = UI::Checkbox("Show all conflicts at once", g_mgShowAllConflicts);
            MG_SetShowAllConflicts(showAll);
            UI::SameLine();
            RenderConflictViewModeButtons();
            for (uint i = 0; i < g_mgConflicts.Length; i++) {
                MGMergeConflict@ c = g_mgConflicts[i];
                bool focused = int(i) == g_mgConflictFocus;
                UI::Text((focused ? "\\$ff0> " : "  ") + "#" + (i + 1) + " " + MG_KindName(c.kind) + "  " + c.key +
                         "   [ours: " + c.oursSummary + "  theirs: " + c.theirsSummary + "]" +
                         (c.previewPlaced ? " \\$8f0[model]" : (c.previewFallback ? " \\$f84[wireframe]" : "")));
                if (c.hasOursPos) {
                    UI::SameLine();
                    if (UI::Button("\\$0f2go ours##o" + i)) {
                        if (!focused) MG_SetConflictFocus(int(i));
                        g_mgLastCamTarget = vec3(-99999, -99999, -99999);
                        MG_JumpCamera(c.oursPos);
                    }
                    if (UI::IsItemHovered()) UI::SetTooltip("Ours (green outline): " + c.oursSummary);
                }
                if (c.hasTheirsPos) {
                    UI::SameLine();
                    if (UI::Button("\\$f42go theirs##t" + i)) {
                        if (!focused) MG_SetConflictFocus(int(i));
                        g_mgLastCamTarget = vec3(-99999, -99999, -99999);
                        MG_JumpCamera(c.theirsPos);
                    }
                    if (UI::IsItemHovered()) UI::SetTooltip("Theirs (red ghost model or wireframe): " + c.theirsSummary);
                }
                UI::SameLine();
                MG_ResolutionButton(c, 1, "Ours");
                UI::SameLine();
                MG_ResolutionButton(c, 2, "Theirs");
                if ((c.kind == 0 || c.kind == 1) && !MG_ConflictHasStart(c)) {
                    UI::SameLine();
                    MG_ResolutionButton(c, 3, "Both");
                }
                if (c.kind != 6) {
                    UI::SameLine();
                    MG_ResolutionButton(c, 4, "None");
                }
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
                MG_ClearConflictPreviews();
                MG_ClearMergeState();
                g_mgMergePushAfter = false;
            }
        }
        if (g_mgAppliedChanges.Length > 0 && g_mgConflicts.Length == 0) {
            for (uint i = 0; i < g_mgAppliedChanges.Length && i < 10; i++) {
                UI::TextDisabled("  " + g_mgAppliedChanges[i]);
            }
        }
    }
}

