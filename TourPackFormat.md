# Tour pack format (`.gohtour`, GOHP v1) — design (ADR-080)

Status: design, 2026-10-18. Nothing implemented.

## Goal

A guide prepares a tour before going live (slides + offline map), exports one file, and shares it out of band
(AirDrop, Files, Messages, Mail when small enough). Guests open it once. During the tour only hashes move:
the live session's signed manifest names each asset by SHA-256, and a guest that already holds those hashes
is ready immediately. Anything missing still transfers over the air (ADR-078/079), and under ADR-081 any
node holding a hash can serve it.

## What already exists (no change needed)

- Every asset is content-addressed: `TourAssetDescriptor { assetID, kind, sha256, byteLength, order, mimeType }`
  in `TourPackManifestPayload { packID, manifestVersion, displayName, assets }`, byte-identical in both cores.
- The guest cache (`FileTourAssetCache`, Android `files/asset-cache/complete/<sha256>`) is keyed only by SHA-256.
  Measured: with a warm cache the guide reported "1 ready" after 1 s instead of 315 s.
- Readiness does not depend on `packID`; only the hashes must match.

## What is missing

1. **Preparing a tour before going live.** Today content belongs to the live session
   (`ChannelService.swift:378`: `beginPack(packID: sessionID)`), so there is nothing to export ahead of time.
   Add a guide-side **tour library**: prepared tours persisted locally (title, slides, map), each with a stable
   `packID`. Going live from a prepared tour publishes the same descriptors (same hashes) in the session manifest.
2. **The file format** (below), writer on the guide, reader/importer on the guest, in both cores.
3. **OS integration**: iOS exported UTI + document type + share sheet; Android `ACTION_VIEW`/`ACTION_SEND`
   intent filter + share intent.

## GOHP v1 byte layout (big-endian, same `BinaryWriter` conventions as GOH2)

```
Header (16 bytes)
  magic            4  "GOHP"
  version          1  0x01
  flags            1  0x00 (reserved, must be 0)
  reserved         2  0x0000
  manifestLength   4  1 ... 1 MiB
  entryCount       4  1 ... 4,096

Manifest           manifestLength bytes: TourPackManifestPayload.encode() exactly as today

Index              entryCount × 48 bytes, sorted by sha256 ascending, no duplicates
  sha256          32  raw digest (the manifest uses hex; the index uses raw bytes)
  byteLength       8  must equal the manifest descriptor's byteLength
  offset           8  absolute file offset of the asset bytes

Data               asset bytes, concatenated in index order, no padding
                   offset[0] = 16 + manifestLength + 48 × entryCount
                   offset[i+1] = offset[i] + byteLength[i]

Trailer (32 bytes) SHA-256 of every preceding byte (header..data)
```

Rules the reader enforces (reject the whole file on any violation, before writing anything to the cache):
- Exact magic/version/flags; lengths within limits; total size = header + manifest + index + data + 32.
- Index sorted, unique, contiguous offsets, no overlap, no gap.
- The index's set of hashes equals the manifest's set of `sha256` values (each asset listed once even if
  two descriptors share bytes).
- Limits: entry ≤ 512 MiB, total ≤ 2 GiB, manifest ≤ 1 MiB, entries ≤ 4,096 (the manifest allows 65,535;
  a pack is a subset). Constants live in both cores.

Why this shape:
- No zip: there is no public unzip API on iOS, and a custom zip parser is more attack surface than a flat
  index. Assets are already compressed (JPEG/PNG pages, PMTiles), so compression would gain nothing.
- No paths: files are named by hash, so there is no path traversal.
- Streaming: the index sits before the data, so an importer copies each entry with a running SHA-256
  without loading the file; the trailer catches truncation and corruption of the whole file.
- The manifest bytes are reused unchanged, so the existing parity tests already cover them.

## Import (guest)

1. Validate header, manifest, index and limits (cheap, before reading the data).
2. For each entry: stream bytes to `partial/<sha256>`, hashing as you go; on a match, atomically move to
   `complete/<sha256>`. A mismatch deletes the partial and fails the import.
3. Verify the trailer at the end; if it fails, remove what this import added.
4. Record a local library entry (pack ID, display name, version, hashes) so the guest UI can show
   "Tour ready: <name>".

Trust: a pack is untrusted input. There is no long-term guide key: the GOS1 signing key is ephemeral per tour
(ADR-038). So a pack is not authenticated before the tour. During the tour a cached file is used only when its
hash appears in the authenticated session manifest, so a forged pack can only add unused cache entries.
Packs never contain room codes, credentials or session keys.

## During the tour

- The protocol does not change: the manifest is sent on join, and slide changes select by asset ID.
- A guest with the pack reports ready right away; the guide's "N ready" count shows it.
- Optional (QST-2): put `packID` + version in the room record so the join list can show "Tour ready" before
  joining. That is a room-record wire change in both cores.

## Export (guide)

- Library → tour → Share. Write the file into a temporary directory, then hand it to the share sheet
  (UIActivityViewController / `ACTION_SEND` with a `FileProvider` URI).
- Show the size; when it exceeds about 20 MB, show "too large for Mail, use AirDrop or Files".

## Tests and gates

- Both cores: writer and reader with a byte-identical fixture (CLI `pack-fixture`, `inspect-pack`), added to
  `scripts/verify_tour_session.sh`; roundtrip of every asset kind; rejection tests for truncation, a reordered
  index, overlap/gap, a manifest/index hash mismatch, a bad trailer, oversize, version 2.
- Device gate (both real UIs): guide exports, the guest opens the file via the share sheet / Files, joins with
  Wi-Fi off; "1 ready" within 5 s and 0 asset bytes on the radio (bridge counters); then a guest without the
  pack still completes the transfer.

## Open questions

- QST-1 Tour library: new prepared-tours screen on the guide, or "Save as tour" from a live tour?
- QST-2 Advertise `packID` in the room record so guests see "Tour ready" before joining (wire change)?
- QST-3 Should a later version add a long-term publisher key so a guest can tell who made a pack before the
  tour? Not needed for safety.
- QST-4 Mail size threshold to warn at (20 MB proposed).
