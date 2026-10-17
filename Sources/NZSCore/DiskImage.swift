import Foundation

/// The user's ADF. Every loader on this disk reads standard 11-sector MFM tracks,
/// so a "track" T (= cylinder*2 + head, as computed by the loaders at $769DC and
/// kernel $0EDA) is simply ADF bytes T*5632 ..< (T+1)*5632.  [verified: disassembly]
public struct DiskImage: Sendable {
    public static let trackSize = 5632
    public static let trackCount = 160
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == DiskImage.trackSize * DiskImage.trackCount else {
            throw NZSError.badDisk("expected 901120-byte ADF, got \(bytes.count)")
        }
        self.bytes = bytes
    }

    public init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](Data(contentsOf: url)))
    }

    public func tracks(_ first: Int, count: Int) -> ArraySlice<UInt8> {
        bytes[first * DiskImage.trackSize ..< (first + count) * DiskImage.trackSize]
    }
}

public enum NZSError: Error, CustomStringConvertible {
    case badDisk(String)
    case badData(String)
    public var description: String {
        switch self {
        case .badDisk(let s): return "bad disk: \(s)"
        case .badData(let s): return "bad data: \(s)"
        }
    }
}

extension Collection where Element == UInt8, Index == Int {
    @inline(__always) func be16(_ o: Int) -> UInt16 {
        UInt16(self[startIndex + o]) << 8 | UInt16(self[startIndex + o + 1])
    }
    @inline(__always) func be32(_ o: Int) -> UInt32 {
        UInt32(be16(o)) << 16 | UInt32(be16(o + 2))
    }
}
