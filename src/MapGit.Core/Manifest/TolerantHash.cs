using System.Buffers.Binary;
using System.Security.Cryptography;

namespace MapGit.Core.Manifest;

/// <summary>
/// Content hash tolerant to last-bit float re-computation noise. The game rewrites a
/// handful of float values inside embedded item GBXes on every save (Phase 0 F11:
/// identical items differed in exactly 6 bytes — a run of floats whose bits change in
/// the last bits; the run was NOT aligned to the file start).
///
/// Strategy: a single forward scan at BYTE granularity. Wherever a run of consecutive
/// plausible floats is found (a float struct, at its own alignment), each float is
/// quantized to ~1/1024 relative precision. Everything else is hashed exactly.
/// Same content re-saved ⇒ same fingerprint; a genuinely different item differs in far
/// more than quantization noise ⇒ different fingerprint.
/// </summary>
public static class TolerantHash
{
    public static string Fingerprint(byte[] data)
    {
        var normalized = new byte[data.Length];
        data.CopyTo(normalized, 0);

        var i = 0;
        while (i + 8 <= normalized.Length)
        {
            if (IsPlausibleFloat(ReadU32(normalized, i)) && IsPlausibleFloat(ReadU32(normalized, i + 4)))
            {
                // A run of at least two consecutive plausible floats: consume it at this
                // (struct) alignment. Runs continue while words stay plausible.
                while (i + 4 <= normalized.Length && TryQuantize(ReadU32(normalized, i), out var q))
                {
                    WriteU32(normalized, i, q);
                    i += 4;
                }
            }
            else
            {
                i += 1;
            }
        }

        return CanonicalJson.HexLower(SHA256.HashData(normalized));
    }

    private static uint ReadU32(byte[] b, int i) => BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(i));

    private static void WriteU32(byte[] b, int i, uint v) => BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(i), v);

    private static bool IsPlausibleFloat(uint raw)
    {
        var f = BitConverter.Int32BitsToSingle(unchecked((int)raw));
        if (!float.IsFinite(f))
        {
            return false; // NaN / ±inf
        }

        var abs = MathF.Abs(f);
        return abs is >= 1e-6f and <= 1e9f; // plausible float magnitude (excludes ints, denormals, zero)
    }

    private static bool TryQuantize(uint raw, out uint quantized)
    {
        quantized = 0;
        if (!IsPlausibleFloat(raw))
        {
            return false;
        }

        var f = BitConverter.Int32BitsToSingle(unchecked((int)raw));
        var q = MathF.Round(f * 1024f) / 1024f;
        quantized = unchecked((uint)BitConverter.SingleToInt32Bits(q));
        return true;
    }
}
