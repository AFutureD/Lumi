import Transport
import Foundation

public enum RelayFrameCodecError: Error, Sendable {
    case truncatedHeader
    case headerTooLarge(Int)
    case invalidNonce
}

/// The binary form of a routing frame on the wire — one WebSocket binary
/// message, or one length-prefixed record on a direct link:
///
///     u32 big-endian header length ‖ header JSON ‖ ciphertext bytes
///
/// The header is what the Relay reads to route (`version`, `hostID`,
/// `deviceID`, `sequence`, `kind`, `nonce` as Base64); the ciphertext is
/// raw, so a frame costs its sealed size plus a few hundred bytes instead of
/// a Base64 third more. Control messages from the Relay stay JSON text.
public enum RelayFrameCodec {
    /// A header past this is not a frame of ours.
    public static let maxHeaderBytes = 4 * 1024

    private struct Header: Codable {
        let version: ProtocolVersion
        let hostID: HostID
        let deviceID: DeviceID?
        let sequence: UInt64
        let kind: RelayFrameKind
        let nonce: Data?
    }

    public static func encode(_ frame: RelayRoutingFrame) throws -> Data {
        let header = try TransportCoding.makeEncoder().encode(Header(
            version: frame.version,
            hostID: frame.hostID,
            deviceID: frame.deviceID,
            sequence: frame.sequence,
            kind: frame.kind,
            nonce: frame.nonce
        ))
        var data = Data(capacity: 4 + header.count + (frame.ciphertext?.count ?? 0))
        var length = UInt32(header.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(header)
        if let ciphertext = frame.ciphertext { data.append(ciphertext) }
        return data
    }

    public static func decode(_ data: Data) throws -> RelayRoutingFrame {
        guard data.count >= 4 else { throw RelayFrameCodecError.truncatedHeader }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= maxHeaderBytes else { throw RelayFrameCodecError.headerTooLarge(length) }
        guard data.count >= 4 + length else { throw RelayFrameCodecError.truncatedHeader }
        let headerData = data.subdata(in: data.startIndex + 4 ..< data.startIndex + 4 + length)
        let header = try TransportCoding.makeDecoder().decode(Header.self, from: headerData)
        let body = data.subdata(in: data.startIndex + 4 + length ..< data.endIndex)
        return RelayRoutingFrame(
            version: header.version,
            hostID: header.hostID,
            deviceID: header.deviceID,
            sequence: header.sequence,
            kind: header.kind,
            nonce: header.nonce,
            ciphertext: body.isEmpty ? nil : body
        )
    }
}
