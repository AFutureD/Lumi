import Foundation

public enum FrameCodecError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case invalidLength
}

public enum LengthPrefixedFrameCodec {
    public static let headerLength = 4
    public static let maximumFrameLength = 8 * 1024 * 1024

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maximumFrameLength else {
            throw FrameCodecError.frameTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: headerLength)
        framed.append(payload)
        return framed
    }

    public static func decodeAvailableFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []

        while buffer.count >= headerLength {
            let frameStart = buffer.startIndex
            let payloadStart = buffer.index(frameStart, offsetBy: headerLength)
            let header = buffer[frameStart..<payloadStart]
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= maximumFrameLength else {
                throw FrameCodecError.frameTooLarge(Int(length))
            }

            let totalLength = headerLength + Int(length)
            guard buffer.count >= totalLength else { break }

            let payloadEnd = buffer.index(frameStart, offsetBy: totalLength)
            frames.append(Data(buffer[payloadStart..<payloadEnd]))
            buffer.removeFirst(totalLength)
        }

        return frames
    }
}
