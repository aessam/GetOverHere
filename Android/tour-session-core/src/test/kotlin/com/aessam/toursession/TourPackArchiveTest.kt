package com.aessam.toursession

import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** Mirrors TourPackArchiveTests.swift (ADR-080); the pinned hex must stay identical on both platforms. */
class TourPackArchiveTest {
    private val packHex = "474f48500100000000000137000000036f1c5c6a0000400080000000000000a10000000000000003000c4669787475726520546f757200040007736c6964652d310100f2115e599cbc8e5e3a6ea06d5ec14ec034429ac8569d758a033013e5f44609000000000000000d00000000000a696d6167652f6a7065670007736c6964652d3201aa5cd9acfab25f643fb1cedb67f8770417ac9ce0b02cfe72a62fa1ec20e9f60a0000000000000005000000010009696d6167652f706e670007736c6964652d330100f2115e599cbc8e5e3a6ea06d5ec14ec034429ac8569d758a033013e5f44609000000000000000d00000002000a696d6167652f6a70656700096d61702d7374796c65039e7feab6660f23cb63046272f63f9bf3dd2a83f92d5af0962878464a8c038783000000000000000d0000000300106170706c69636174696f6e2f6a736f6e00f2115e599cbc8e5e3a6ea06d5ec14ec034429ac8569d758a033013e5f44609000000000000000d00000000000001d79e7feab6660f23cb63046272f63f9bf3dd2a83f92d5af0962878464a8c038783000000000000000d00000000000001e4aa5cd9acfab25f643fb1cedb67f8770417ac9ce0b02cfe72a62fa1ec20e9f60a000000000000000500000000000001f1474f4820736c696465206f6e657b2276657273696f6e223a387d000102fffee2ee223a7a0ece6175060f972ffc9fee61f5402f184741a09f0e47a748956c99"

    private fun fixture(): ByteArray = packHex.hexToByteArray()
    private fun mutated(change: (ByteArray) -> Unit): ByteArray = fixture().also(change)
    private fun reason(file: ByteArray): String =
        assertThrows(TourPackException::class.java) { TourPackArchive.read(file) }.reason

    @Test fun pinnedRoundtrip() {
        assertEquals(packHex, TourSessionFixtures.tourPackFixture().lowercaseHex())
        val (layout, assets) = TourPackArchive.read(fixture())
        assertEquals(4, layout.manifest.assets.size)
        assertEquals("two slides share bytes, stored once", 3, layout.entries.size)
        assertEquals(471L, layout.dataOffset)
        assertEquals(534L, layout.totalLength)
        val expected = TourSessionFixtures.tourPackFixtureAssets().associate {
            MessageDigest.getInstance("SHA-256").digest(it).lowercaseHex() to it.lowercaseHex()
        }
        assertEquals(expected, assets.mapValues { it.value.lowercaseHex() })
    }

    @Test fun streamingPrefix() {
        val file = fixture()
        val prefixLength = TourPackArchive.prefixLength(file.copyOfRange(0, TourPackArchive.HEADER_LENGTH))
        assertEquals(471, prefixLength)
        assertEquals(TourPackArchive.read(file).first, TourPackArchive.parsePrefix(file.copyOfRange(0, prefixLength), file.size.toLong()))
    }

    @Test fun rejections() {
        assertEquals("badMagic", reason(mutated { it[0] = 0x58 }))
        assertEquals("unsupportedVersion", reason(mutated { it[4] = 2 }))
        assertEquals("reservedBitsSet", reason(mutated { it[5] = 1 }))
        assertEquals("fileLengthMismatch", reason(fixture().copyOfRange(0, 533)))
        assertEquals("trailerMismatch", reason(mutated { it[533] = (it[533].toInt() xor 1).toByte() }))
        // Index starts at 16 + 311: swapping whole entries breaks offsets; swapping hashes breaks the order.
        assertEquals("offsetMismatch", reason(mutated { swap(it, 327, 375, 48) }))
        assertEquals("indexNotSorted", reason(mutated { swap(it, 327, 375, 32) }))
        assertEquals("manifestIndexMismatch", reason(mutated { it[454] = (it[454].toInt() xor 1).toByte() }))
        val resealed = mutated { bytes ->
            bytes[471] = (bytes[471].toInt() xor 1).toByte()
            TourPackArchive.trailer(bytes.copyOfRange(0, 502)).copyInto(bytes, 502)
        }
        assertEquals("assetHashMismatch", reason(resealed))
    }

    @Test fun writerRejections() {
        val (layout, _) = TourPackArchive.read(fixture())
        assertEquals("missingAsset", assertThrows(TourPackException::class.java) { TourPackArchive.write(layout.manifest, emptyMap()) }.reason)
        val hash = layout.entries[0].sha256Hex
        val conflicting = TourPackManifestPayload(UUID.randomUUID(), 1, "x", listOf(
            TourAssetDescriptor("a", TourAssetKind.SLIDE, hash, 13, 0, "image/jpeg"),
            TourAssetDescriptor("b", TourAssetKind.SLIDE, hash, 14, 1, "image/jpeg"),
        ))
        assertEquals("inconsistentLength", assertThrows(TourPackException::class.java) { TourPackArchive.prefix(conflicting) }.reason)
    }

    private fun swap(bytes: ByteArray, first: Int, second: Int, length: Int) {
        val copy = bytes.copyOfRange(first, first + length)
        bytes.copyInto(bytes, first, second, second + length)
        copy.copyInto(bytes, second)
    }
}
