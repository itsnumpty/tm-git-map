// TolerantHash.as — content hash tolerant to last-bit float re-computation noise
// inside embedded item GBXes. Byte-scans for runs of plausible floats, quantizes
// to ~1/1024 relative precision, and SHA-256 hashes the normalized buffer.

string MG_TolerantFingerprintBytes(MemoryBuffer@ data) {
    if (data is null) return "";
    data.Seek(0);
    uint len = data.GetSize();
    if (len == 0) return Crypto::Sha256("");

    MemoryBuffer@ norm = MemoryBuffer(len);
    data.Seek(0);
    for (uint i = 0; i < len; i++) {
        norm.Write(data.ReadUInt8());
    }

    uint i = 0;
    while (i + 8 <= len) {
        uint w0 = MG_ReadU32(norm, i);
        uint w1 = MG_ReadU32(norm, i + 4);
        if (MG_IsPlausibleFloat(w0) && MG_IsPlausibleFloat(w1)) {
            while (i + 4 <= len) {
                uint raw = MG_ReadU32(norm, i);
                uint q = 0;
                if (!MG_TryQuantize(raw, q)) break;
                MG_WriteU32(norm, i, q);
                i += 4;
            }
        } else {
            i += 1;
        }
    }

    norm.Seek(0);
    string bytes = norm.ReadString(norm.GetSize());
    return Crypto::Sha256(bytes);
}

string MG_TolerantFingerprintFile(const string&in path) {
    if (!IO::FileExists(path)) return "";
    IO::File f(path, IO::FileMode::Read);
    MemoryBuffer@ data = f.Read(f.Size());
    f.Close();
    return MG_TolerantFingerprintBytes(data);
}

uint MG_ReadU32(MemoryBuffer@ buf, uint offset) {
    buf.Seek(offset);
    return buf.ReadUInt32();
}

void MG_WriteU32(MemoryBuffer@ buf, uint offset, uint v) {
    buf.Seek(offset);
    buf.Write(v);
}

float MG_BitsToFloat(uint raw) {
    MemoryBuffer@ tmp = MemoryBuffer(4);
    tmp.Write(raw);
    tmp.Seek(0);
    return tmp.ReadFloat();
}

uint MG_FloatToBits(float f) {
    MemoryBuffer@ tmp = MemoryBuffer(4);
    tmp.Write(f);
    tmp.Seek(0);
    return tmp.ReadUInt32();
}

bool MG_IsPlausibleFloat(uint raw) {
    float f = MG_BitsToFloat(raw);
    if (f != f) return false; // NaN
    // ±inf check: abs is huge
    float abs = Math::Abs(f);
    if (abs > 1e30f) return false;
    return abs >= 1e-6f && abs <= 1e9f;
}

bool MG_TryQuantize(uint raw, uint&out quantized) {
    quantized = 0;
    if (!MG_IsPlausibleFloat(raw)) return false;
    float f = MG_BitsToFloat(raw);
    float q = Math::Round(f * 1024.0f) / 1024.0f;
    quantized = MG_FloatToBits(q);
    return true;
}
