import Foundation

struct DiscFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct RecordedTrack: Equatable, Sendable {
    let number: UInt32
    let session: UInt32
    let start: UInt32
    let blocks: UInt32
    let blank: Bool
    let damaged: Bool
    let nextWritable: UInt32?
    let freeBlocks: UInt32
    var untouchedWritable: Bool {
        blank && !damaged && nextWritable == start && freeBlocks == blocks && blocks > 0
    }

    func contains(_ lba: UInt32, bytes: UInt32) -> Bool {
        let count = (UInt64(bytes) + 2047) / 2048
        return !blank && !damaged && lba >= start && UInt64(lba) + count <= UInt64(start) + UInt64(blocks)
    }
}

struct ISOEntry: Equatable, Sendable {
    let name: String
    let lba: UInt32
    let bytes: UInt32
    let directory: Bool
}

struct ISOVolume: Sendable {
    let root: ISOEntry
    let joliet: Bool
}

enum ISO9660 {
    static let sectorBytes = 2048
    static func both32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 8 <= data.count else { throw DiscFailure("ISO 数值被截断。") }
        let a = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
        let b = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[offset + 4 + $1]) }
        guard a == b else { throw DiscFailure("ISO 双字节序字段不一致。") }
        return a
    }
    static func descriptor(_ data: Data) throws -> ISOVolume? {
        guard data.count == sectorBytes, data.subdata(in: 1..<6) == Data("CD001".utf8), data[6] == 1 else {
            throw DiscFailure("该会话不是可识别的 ISO 9660 文件系统。")
        }
        guard data[0] == 1 || data[0] == 2 else { return nil }
        let joliet = data[0] == 2 && data[88] == 0x25 && data[89] == 0x2f && [0x40, 0x43, 0x45].contains(data[90])
        if data[0] == 2 && !joliet { return nil }
        guard Array(data[128..<132]) == [0, 8, 8, 0] else { throw DiscFailure("仅支持 2048 字节 ISO 逻辑块。") }
        let root = try record(Data(data[156..<190]), joliet: joliet)
        guard root.directory, root.bytes > 0 else { throw DiscFailure("ISO 根目录无效。") }
        return ISOVolume(root: root, joliet: joliet)
    }
    static func record(_ data: Data, joliet: Bool) throws -> ISOEntry {
        guard data.count >= 34, Int(data[0]) == data.count, 33 + Int(data[32]) <= data.count,
              data[1] == 0, data[26] == 0, data[27] == 0, data[25] & 0x80 == 0 else {
            throw DiscFailure("不支持截断、多区段文件或交错存储的 ISO 目录项。")
        }
        let raw = data.subdata(in: 33..<(33 + Int(data[32])))
        let name: String
        if raw == Data([0]) { name = "." }
        else if raw == Data([1]) { name = ".." }
        else {
            guard let decoded = String(data: raw, encoding: joliet ? .utf16BigEndian : .ascii) else {
                throw DiscFailure("ISO 文件名编码无效。")
            }
            var value = decoded
            if value.hasSuffix(";1") { value.removeLast(2) }
            if !joliet { value = value.lowercased() }
            guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\0") else {
                throw DiscFailure("ISO 文件名包含非法路径。")
            }
            name = value
        }
        return ISOEntry(name: name, lba: try both32(data, 2), bytes: try both32(data, 10), directory: data[25] & 2 != 0)
    }
    // The primary namespace can be read even when it is only a fallback view
    // of richer metadata. Import only ordinary files/directories whose names
    // and extents really describe the contents we would carry forward.
    static func canImportPrimaryRecord(_ raw: Data, entry: ISOEntry) -> Bool {
        guard raw[25] == (entry.directory ? 2 : 0) else { return false }
        let nameBytes = Int(raw[32])
        var offset = 33 + nameBytes + (nameBytes.isMultiple(of: 2) ? 1 : 0)
        while offset < raw.count {
            if raw[offset...].allSatisfy({ $0 == 0 }) { break }
            guard offset + 4 <= raw.count else { return false }
            let length = Int(raw[offset + 2]), end = offset + length
            guard length >= 4, end <= raw.count else { return false }
            switch String(decoding: raw[offset..<(offset + 2)], as: UTF8.self) {
            case "SP", "ER", "RR", "TF", "ST", "AA":
                break  // Ordinary SUSP declarations, dates and Finder attributes.
            case "PX":
                guard length >= 12, let mode = try? both32(raw, offset + 4),
                      mode & 0o170000 == (entry.directory ? 0o040000 : 0o100000) else { return false }
            case "NM":
                guard length >= 5, raw[offset + 4] == 0,
                      String(data: raw[(offset + 5)..<end], encoding: .utf8) == entry.name else { return false }
            default:
                // Links, alternate/continued namespaces and special files
                // require a different importer; keep the disc readable.
                return false
            }
            offset = end
        }
        return true
    }

    static func directory(_ data: Data, joliet: Bool,
                          inspect: ((Data, ISOEntry) -> Void)? = nil) throws -> [ISOEntry] {
        var offset = 0; var entries: [ISOEntry] = []; var names = Set<String>()
        while offset < data.count {
            let length = Int(data[offset])
            if length == 0 { offset = (offset / sectorBytes + 1) * sectorBytes; continue }
            guard length >= 34, offset + length <= data.count, offset % sectorBytes + length <= sectorBytes else {
                throw DiscFailure("ISO 目录项越过扇区边界。")
            }
            let raw = data.subdata(in: offset..<(offset + length))
            let entry = try record(raw, joliet: joliet)
            inspect?(raw, entry)
            if entry.name != ".", entry.name != ".." {
                guard names.insert(entry.name).inserted else { throw DiscFailure("ISO 目录包含重名文件。") }
                entries.append(entry)
            }
            offset += length
        }
        return entries
    }
    static func latestCompleted(_ tracks: [RecordedTrack], emptyLastSession: UInt32?) throws -> RecordedTrack {
        let completed = tracks.filter { !$0.blank && $0.session != emptyLastSession }
        guard let last = completed.max(by: { ($0.session, $0.number) < ($1.session, $1.number) }),
              !last.damaged, last.blocks > 16 else { throw DiscFailure("找不到完整且可读取的数据会话。") }
        guard completed.filter({ $0.session == last.session }).count == 1 else {
            throw DiscFailure("当前仅支持每会话一个数据轨道的 DVD+R。")
        }
        return last
    }

    static func blankReservation(_ tracks: [RecordedTrack], disc: DMDisc, capacity: UInt64) -> RecordedTrack? {
        guard disc.status == 1, disc.lastState == 1, tracks.count >= 3 else { return nil }
        let prior = tracks[tracks.count - 3]
        let reserved = tracks[tracks.count - 2]
        let tail = tracks[tracks.count - 1]
        guard prior.session < 65535, prior.session + 1 == reserved.session, reserved.session == disc.sessions,
              reserved.number == disc.firstTrack, tail.number == disc.lastTrack, reserved.number < 64,
              tail.session == reserved.session, reserved.number + 1 == tail.number else { return nil }
        guard reserved.untouchedWritable, tail.untouchedWritable, reserved.start % 16 == 0,
              reserved.blocks > 16, reserved.blocks % 16 == 0,
              UInt64(reserved.start) + UInt64(reserved.blocks) + 16 == UInt64(tail.start),
              UInt64(tail.start) + UInt64(tail.blocks) <= capacity else { return nil }
        for recorded in tracks.dropLast(2) {
            guard !recorded.blank, !recorded.damaged, recorded.nextWritable == nil,
                  UInt64(recorded.start) + UInt64(recorded.blocks) <= UInt64(reserved.start) else { return nil }
        }
        return reserved
    }

    /// An interrupted DVD+R close may leave a readable data track followed by
    /// an open incremental track in the same session. Exclude that open track
    /// from every read bound and never advertise the disc as appendable.
    static func readableTracks(_ tracks: [RecordedTrack], lastState: UInt32) throws -> [RecordedTrack] {
        guard lastState == 1 else { return tracks }
        guard let open = tracks.last, open.nextWritable != nil, !open.blank, !open.damaged,
              let data = tracks.dropLast().last, data.session == open.session,
              !data.blank, !data.damaged, data.nextWritable == nil,
              tracks.filter({ $0.session == open.session }).count == 2 else {
            throw DiscFailure("末次会话未封闭，且不能安全确定已记录数据轨道；已停止只读恢复。")
        }
        return Array(tracks.dropLast())
    }
}
