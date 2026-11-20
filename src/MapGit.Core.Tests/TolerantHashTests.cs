using System.Buffers.Binary;
using MapGit.Core.Manifest;
using Xunit;

namespace MapGit.Core.Tests;

public class TolerantHashTests
{
    private static byte[] Words(params uint[] words)
    {
        var b = new byte[words.Length * 4];
        for (var i = 0; i < words.Length; i++)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(i * 4), words[i]);
        }

        return b;
    }

    [Fact]
    public void last_bit_float_noise_yields_same_fingerprint()
    {
        // Actual observed churn from Ninconpoop's embedded item (F11): a run of floats
        // whose bits change in the last bits on every save, e.g. 0x3ECFD8A2 vs 0x3ECFD8A8.
        var a = TolerantHash.Fingerprint(Words(0x3ECFD8A2, 0xBF69F4EE, 0xDEADBEEF));
        var b = TolerantHash.Fingerprint(Words(0x3ECFD8A8, 0xBF69F4ED, 0xDEADBEEF));
        Assert.Equal(a, b);
    }

    [Fact]
    public void unaligned_float_structs_are_quantized_at_their_own_alignment()
    {
        // The real churn region in the item file: 9 consecutive floats starting at an
        // offset that is NOT 4-aligned. Reconstructed here with 2 junk bytes of prefix.
        var baseRun = new byte[]
        {
            0xAB, 0xCD, // junk prefix (unaligned)
            0x41, 0xEC, 0x7F, 0x3F, // 0.9994
            0x50, 0x9D, 0xF6, 0x3A, // 0.00197
            0x71, 0x7E, 0xC8, 0xBC, // -0.0249
            0x0E, 0x9E, 0x06, 0xBC, // -0.00822 (volatile)
            0xEE, 0xF4, 0x69, 0xBF, // -0.93749 (volatile)
            0x4E, 0xCE, 0xCF, 0xBE, // -0.40600 (volatile)
            0x67, 0x7C, 0xBD, 0xBC, // -0.02436 (volatile)
            0xA2, 0xD8, 0xCF, 0x3E, // 0.40600 (volatile)
            0xDE, 0xE1, 0x69, 0xBF, // -0.93749 (volatile)
            0x00, 0x00, 0x00, 0x00,
            0xEF, 0xBE,
        };
        var resavedRun = (byte[])baseRun.Clone();
        // last-bit noise in the LOW byte of volatile floats #4..#9 (indices 14,18,22,26,30,34)
        resavedRun[14] = 0x11; // 0x0E -> 0x11 (0xBC069E0E -> 0xBC069E11)
        resavedRun[18] = 0xE7; // 0xEE -> 0xE7
        resavedRun[22] = 0x4F; // 0x4E -> 0x4F
        resavedRun[26] = 0x65; // 0x67 -> 0x65
        resavedRun[30] = 0xA3; // 0xA2 -> 0xA3
        resavedRun[34] = 0xDD; // 0xDE -> 0xDD

        Assert.Equal(TolerantHash.Fingerprint(baseRun), TolerantHash.Fingerprint(resavedRun));
    }

    [Fact]
    public void real_float_differences_yield_different_fingerprints()
    {
        var a = TolerantHash.Fingerprint(Words(0x3F000000)); // 0.5
        var b = TolerantHash.Fingerprint(Words(0x3F800000)); // 1.0
        Assert.NotEqual(a, b);
    }

    [Fact]
    public void non_float_data_is_hashed_exactly()
    {
        var a = TolerantHash.Fingerprint([(byte)1, (byte)2, (byte)3, (byte)4, (byte)5]);
        var b = TolerantHash.Fingerprint([(byte)1, (byte)2, (byte)3, (byte)4, (byte)6]);
        Assert.NotEqual(a, b);
    }
}
