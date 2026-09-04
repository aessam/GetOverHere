import Darwin
import Foundation
import Testing
import TourSessionCore
@testable import GetOverHere

/// RSK-1 (ADR-047): every lane admits at most `pendingHandshakeBound` accepted-but-unauthenticated
/// connections. The next one is closed before a single handshake byte is written, and a slot is
/// released the moment the pending handshake returns or throws, so closing one pending peer admits
/// the next. The bound is above the 24-guest tour group so a simultaneous (re)join never rejects a
/// legitimate guest (`controlLaneScalesBeyondProcessorCount`).
@Suite(.serialized)
struct HandshakeBoundTests {
    /// Mirrors `LocalAuthenticatedSessionTransport.maximumPendingHandshakes` and the audio lane's slot count.
    private static let pendingHandshakeBound = 32

    @Test("Control lane closes the pending handshake beyond the bound immediately")
    @MainActor
    func controlLaneClosesPendingHandshakeBeyondBoundImmediately() async throws {
        let port: UInt16 = 50_043
        let guide = LocalSessionControlTransport(port: port)
        let sessionID = UUID()
        defer { guide.stop() }
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
        )
        try guide.startGuide()

        try await assertPendingHandshakeBeyondBoundIsClosed(port: port, bound: Self.pendingHandshakeBound)
    }

    @Test("Audio lane closes the pending handshake beyond the bound immediately")
    @MainActor
    func audioLaneClosesPendingHandshakeBeyondBoundImmediately() async throws {
        let port: UInt16 = 50_044
        let guide = UDPAudioPlane(port: port, codecProvider: BoundTestCodecProvider())
        let sessionID = UUID()
        defer { guide.stop() }
        guide.configureSession(
            sessionID: sessionID,
            participantID: UUID(),
            displayName: "Guide",
            platform: .iOS,
            credential: try SessionCredential.derive(shortCode: "23456789AB", sessionID: sessionID)
        )
        try guide.startBroadcasting(channelID: sessionID.uuidString, quality: .standard)

        try await assertPendingHandshakeBeyondBoundIsClosed(port: port, bound: Self.pendingHandshakeBound)
    }
}

/// Runs off the main actor: the raw `recv` calls block for up to their receive timeout, and the
/// transports under test hop to the main actor to register admitted peers.
@concurrent
private func assertPendingHandshakeBeyondBoundIsClosed(port: UInt16, bound: Int) async throws {
    var silent: [Int32] = []
    defer { silent.forEach { close($0) } }
    for _ in 0 ..< bound {
        silent.append(try rawConnect(port: port))
    }
    // Let the accept loop admit every pending peer before the one beyond the bound arrives.
    try await Task.sleep(for: .milliseconds(200))

    let beyond = try rawConnect(port: port)
    defer { close(beyond) }
    #expect(rawReceiveByte(fd: beyond, timeoutSeconds: 1) == 0, "pending handshake beyond the bound must be closed without a challenge")
    #expect(rawReceiveByte(fd: silent[0], timeoutSeconds: 1) > 0, "first pending handshake must receive the sealed challenge")

    // Closing one pending peer makes its handshake throw and releases the slot (accept-vs-release race: 200 ms).
    close(silent.removeFirst())
    try await Task.sleep(for: .milliseconds(200))
    let admitted = try rawConnect(port: port)
    defer { close(admitted) }
    #expect(rawReceiveByte(fd: admitted, timeoutSeconds: 2) > 0, "released slot must admit the next connection")
}

private enum RawSocketError: Error {
    case create
    case connect(Int32)
}

private func rawConnect(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RawSocketError.create }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        close(fd)
        throw RawSocketError.connect(code)
    }
    return fd
}

/// Returns the `recv` result for one byte: `> 0` a byte arrived, `0` the peer closed, `< 0` timeout/error.
private func rawReceiveByte(fd: Int32, timeoutSeconds: Int) -> Int {
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var byte: UInt8 = 0
    return Darwin.recv(fd, &byte, 1, 0)
}

private final class BoundTestCodecProvider: RealtimeAudioCodecProviderInterface {
    func sessionCapabilities() -> SessionCapabilities {
        [.opusEncoder, .opusDecoder]
    }

    func makeEncoder(codec: SessionAudioCodec) throws -> any RealtimeAudioEncoderInterface {
        try BoundTestEncoder(codec: codec)
    }

    func makeDecoder(configuration: SessionAudioCodecConfiguration) -> any RealtimeAudioDecoderInterface {
        BoundTestDecoder(configuration: configuration)
    }
}

private final class BoundTestEncoder: RealtimeAudioEncoderInterface {
    let codec: SessionAudioCodec
    let inputPCMByteCount = 4
    private let configuration: SessionAudioCodecConfiguration

    init(codec: SessionAudioCodec) throws {
        self.codec = codec
        configuration = try SessionAudioCodecConfiguration(
            codec: codec,
            sampleRate: 16_000,
            channelCount: 1,
            frameDurationMilliseconds: 20,
            bitRate: 20_000
        )
    }

    func encode(pcm16LittleEndian: Data) -> NativeEncodedAudioPacket? {
        NativeEncodedAudioPacket(configuration: configuration, bytes: pcm16LittleEndian)
    }
}

private final class BoundTestDecoder: RealtimeAudioDecoderInterface {
    let configuration: SessionAudioCodecConfiguration

    init(configuration: SessionAudioCodecConfiguration) {
        self.configuration = configuration
    }

    func decode(packet: Data) -> Data? {
        packet
    }
}
