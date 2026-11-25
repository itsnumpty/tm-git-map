// Items.as — custom item/block files travel with each version.
// On save, the custom files the map uses are copied from the player's Items/Blocks folders
// into objects/items/<sha256>.gbx and listed in the commit json as "items": "rel=sha;...".
// Push uploads them under items/ in the version's GitHub files; Update, Join and combining
// install any a collaborator is missing. A player's existing files are never overwritten.

int MG_LastIndexOfChar(const string&in s, uint8 ch) {
    for (int i = int(s.Length) - 1; i >= 0; i--) {
        if (s[i] == ch) return i;
    }
    return -1;
}

// Map-side model name -> candidate file under the user game folder ("" if not custom).
string MG_CustomFileFor(const string&in name, string&out rel) {
    rel = "";
    string p = name.Replace("\\", "/");
    int blockAt = p.ToLower().IndexOf(".block.gbx");
    if (blockAt >= 0) p = p.SubStr(0, blockAt + 10); // "X.Block.Gbx_CustomBlock" -> "X.Block.Gbx"
    string lower = p.ToLower();
    if (!lower.EndsWith(".item.gbx") && !lower.EndsWith(".block.gbx")) return "";
    array<string> tries;
    if (lower.StartsWith("items/") || lower.StartsWith("blocks/")) {
        tries.InsertLast(p);
    } else {
        tries.InsertLast("Items/" + p);
        tries.InsertLast("Blocks/" + p);
    }
    for (uint i = 0; i < tries.Length; i++) {
        string full = IO::FromUserGameFolder(tries[i]);
        if (IO::FileExists(full)) { rel = tries[i]; return full; }
    }
    return "";
}

// Snapshots the custom files used by `m` into the repo. Returns the sorted "rel=sha;..." list.
string MG_SnapshotCustomFiles(MGManifest@ m, const string&in repoDir) {
    if (m is null) return "";
    array<string> names;
    for (uint i = 0; i < m.items.Length; i++) names.InsertLast(m.items[i].itemModel);
    for (uint i = 0; i < m.blocks.Length; i++) {
        if (m.blocks[i].name.ToLower().IndexOf(".block.gbx") >= 0) names.InsertLast(m.blocks[i].name);
    }
    for (uint i = 0; i < m.embeddedEntries.Length; i++) names.InsertLast(m.embeddedEntries[i].name);

    dictionary seen;
    array<string> entries;
    for (uint i = 0; i < names.Length; i++) {
        string rel;
        string full = MG_CustomFileFor(names[i], rel);
        if (full.Length == 0 || seen.Exists(rel.ToLower())) continue;
        seen.Set(rel.ToLower(), true);
        string sha = MG_Sha256File(full);
        IO::CreateFolder(repoDir + "/objects/items");
        string dest = repoDir + "/objects/items/" + sha + ".gbx";
        if (!IO::FileExists(dest)) MG_CopyFile(full, dest);
        entries.InsertLast(rel + "=" + sha);
        if (entries.Length % 8 == 0) yield();
    }
    entries.SortAsc();
    string joined = "";
    for (uint i = 0; i < entries.Length; i++) joined += (i > 0 ? ";" : "") + entries[i];
    return joined;
}

class MGCustomFile {
    string rel;
    string sha;
}

array<MGCustomFile@>@ MG_ParseCustomFiles(const string&in list) {
    array<MGCustomFile@>@ res = array<MGCustomFile@>();
    if (list.Length == 0) return res;
    string[] parts = list.Split(";");
    for (uint i = 0; i < parts.Length; i++) {
        int eq = MG_LastIndexOfChar(parts[i], 0x3D); // '='
        if (eq <= 0) continue;
        MGCustomFile@ f = MGCustomFile();
        f.rel = parts[i].SubStr(0, eq);
        f.sha = parts[i].SubStr(eq + 1);
        if (f.rel.IndexOf("..") >= 0) continue; // never write outside the game folder
        res.InsertLast(f);
    }
    return res;
}

// Installs the custom files a version lists that this player doesn't have.
// Returns the Items-relative paths of newly installed items (for reloading).
array<string>@ MG_InstallCustomFilesFor(const string&in repoDir, const string&in commitSha) {
    array<string>@ installedItems = array<string>();
    array<MGCustomFile@>@ files = MG_ParseCustomFiles(MG_ReadCommitExtra(repoDir, commitSha, "items"));
    int installed = 0;
    for (uint i = 0; i < files.Length; i++) {
        string dest = IO::FromUserGameFolder(files[i].rel);
        if (IO::FileExists(dest)) continue;
        string src = repoDir + "/objects/items/" + files[i].sha + ".gbx";
        if (!IO::FileExists(src)) {
            MG_Log("items: '" + files[i].rel + "' is used by their version but wasn't shared with it");
            continue;
        }
        try {
            int slash = MG_LastIndexOfChar(dest.Replace("\\", "/"), 0x2F);
            if (slash > 0) IO::CreateFolder(dest.SubStr(0, slash));
            MG_CopyFile(src, dest);
        } catch {
            MG_Log("items: could not install '" + files[i].rel + "': " + getExceptionInfo());
            continue;
        }
        installed++;
        MG_Log("items: installed '" + files[i].rel + "'");
        if (files[i].rel.StartsWith("Items/")) installedItems.InsertLast(files[i].rel.SubStr(6));
    }
    if (installed > 0) {
        UI::ShowNotification("MapGit", "Installed " + installed + " custom file" + (installed == 1 ? "" : "s") +
                             " your collaborators used.");
    }
    return installedItems;
}

// Loads a custom item straight from its file when the inventory doesn't know it yet
// (e.g. it was just installed).
CGameItemModel@ MG_LoadItemModelFromFile(const string&in itemModel) {
    string rel;
    if (MG_CustomFileFor(itemModel, rel).Length == 0) return null;
    try {
        int slash = MG_LastIndexOfChar(rel, 0x2F);
        if (slash > 0) {
            CSystemFidsFolder@ folder = Fids::GetUserFolder(rel.SubStr(0, slash));
            if (folder !is null) Fids::UpdateTree(folder);
        }
        CSystemFidFile@ fid = Fids::GetUser(rel);
        if (fid is null) return null;
        return cast<CGameItemModel>(Fids::Preload(fid));
    } catch {
        return null;
    }
}

// Custom item models `m` uses that can't be found anywhere right now.
array<string>@ MG_MissingCustomItems(CGameCtnChallenge@ map, MGManifest@ m) {
    array<string>@ missing = array<string>();
    dictionary seen;
    for (uint i = 0; i < m.items.Length; i++) {
        string model = m.items[i].itemModel;
        if (!model.ToLower().EndsWith(".item.gbx") || seen.Exists(model)) continue;
        seen.Set(model, true);
        if (MG_FindItemModel(map, model) is null) missing.InsertLast(model);
    }
    return missing;
}
