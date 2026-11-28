import Foundation

struct UDFAppendUnsupported: LocalizedError, CustomNSError {
    let revision: UInt16
    let partitionMapType: UInt8
    static var errorDomain: String { "DiscMate.UDF" }
    var errorCode: Int { 1001 }
    var errorDescription: String? {
        let version = String(format: "%x.%02x", revision >> 8, revision & 0xff)
        if partitionMapType == 2 {
            return "这张 UDF \(version) 光盘使用虚拟分区（VAT）。可在访达浏览当前挂载的文件；DiscMate 尚不支持追加到这种分区。"
        }
        return "检测到 UDF \(version) 光盘（分区映射类型 \(partitionMapType)）；当前版本不能安全导入这张盘的目录或分配方式。本次未写盘。"
    }
}

/// Read-only recognition of the UDF layout that an append writer must preserve.
/// Addresses here are physical 2048-byte sectors; no media writes are exposed.
struct UDFVolumeProbe: Sendable {
    let revision: UInt16
    let blockBytes: UInt32
    let partitionMapType: UInt8
    let partitionStart: UInt32
    let partitionBlocks: UInt32
    let partitionNumber: UInt16
    let fileSetBlock: UInt32
    let label: String?

    static func inspect(sessionStart: UInt32, capacityBlocks: UInt64, allowISOBridge: Bool = false, allowVAT: Bool = false,
                        readSector: (UInt32) throws -> Data) throws -> UDFVolumeProbe {
        func sector(_ offset: UInt32) throws -> Data {
            let address = UInt64(sessionStart) + UInt64(offset)
            guard address < capacityBlocks, address <= UInt32.max else { throw DiscFailure("UDF 描述符地址越界。") }
            let data = try readSector(UInt32(address))
            guard data.count == 2048 else { throw DiscFailure("UDF 描述符读取不完整。") }
            return data
        }
        var offset: UInt32 = 16
        var first = try sector(offset)
        if allowISOBridge, first[1..<6] == Data("CD001".utf8) {
            // Bridge volumes place UDF recognition after the ISO descriptor set.
            while offset < 48, first[1..<6] == Data("CD001".utf8), first[6] == 1 {
                let terminator = first[0] == 255
                offset += 1
                first = try sector(offset)
                if terminator { break }
                guard first[1..<6] == Data("CD001".utf8) else { throw DiscFailure("ISO 卷描述符缺少结束标记。") }
            }
        }
        guard first.subdata(in: 1..<6) == Data("BEA01".utf8) else { throw DiscFailure("没有 UDF 卷识别序列。") }
        let recognition = try sector(offset + 1)
        guard ["NSR02", "NSR03"].contains(String(decoding: recognition[1..<6], as: UTF8.self)) else {
            throw DiscFailure("不支持当前 UDF 卷识别序列。")
        }
        let anchorAddress = UInt64(sessionStart) + 256
        guard anchorAddress <= UInt32.max, anchorAddress < capacityBlocks else { throw DiscFailure("UDF 锚点地址越界。") }
        let anchor = try sector(256)
        try checkTag(anchor, id: 2, address: UInt32(anchorAddress))
        let sequenceBytes = number32(anchor, 16), sequenceStart = number32(anchor, 20)
        guard sequenceBytes > 0, sequenceBytes <= 64 * 2048, sequenceBytes % 2048 == 0,
              UInt64(sequenceStart) + UInt64(sequenceBytes / 2048) <= capacityBlocks,
              UInt64(sequenceStart) + UInt64(sequenceBytes / 2048) <= UInt32.max else {
            throw DiscFailure("UDF 卷描述符序列越界。")
        }
        var logical: Data?, partition: Data?
        for index in 0..<(sequenceBytes / 2048) {
            let address = sequenceStart + index
            let data = try readSector(address)
            guard data.count == 2048 else { throw DiscFailure("UDF 卷描述符读取不完整。") }
            let identifier = number16(data, 0)
            if identifier == 8 { break }
            if identifier == 6 || identifier == 5 {
                try checkTag(data, id: identifier, address: address)
                if identifier == 6 { guard logical == nil else { throw DiscFailure("UDF 逻辑卷描述符重复。") }; logical = data }
                else { guard partition == nil else { throw DiscFailure("UDF 分区描述符重复。") }; partition = data }
            }
        }
        guard let logical, let partition else { throw DiscFailure("UDF 卷或分区描述符缺失。") }
        let mapLength = number32(logical, 264), mapCount = number32(logical, 268)
        guard logical[217..<240] == Data("*OSTA UDF Compliant".utf8) + Data(repeating: 0, count: 4),
              mapLength >= 2, mapLength <= 1608, mapCount >= 1, mapCount <= 16 else {
            throw DiscFailure("UDF 域或分区映射无效。")
        }
        let mapType = logical[440]
        // Physical map followed by the registered UDF virtual partition map.
        let virtual = mapCount == 2 && mapLength == 70 && mapType == 1 && logical[441] == 6 &&
           logical[446] == 2 && logical[447] == 64 &&
           logical[451..<474] == Data("*UDF Virtual Partition".utf8) + Data(repeating: 0, count: 1)
        if virtual && !(allowVAT && number16(logical, 240) == 0x0201 && number16(logical, 482) == 1 && number16(logical, 484) == number16(partition, 22)) {
            throw UDFAppendUnsupported(revision: number16(logical, 240), partitionMapType: 2)
        }
        let start = number32(partition, 188), blocks = number32(partition, 192)
        guard number32(logical, 212) == 2048, blocks > 0,
              UInt64(start) + UInt64(blocks) <= capacityBlocks else {
            throw DiscFailure("UDF 块大小或分区范围不受支持。")
        }
        guard (virtual || (mapCount == 1 && mapLength == 6)), mapType == 1, logical[441] == 6,
              number16(logical, 442) == 1, number16(logical, 444) == number16(partition, 22),
              number32(logical, 248) >= 2048, number16(logical, 256) == (virtual ? 1 : number16(partition, 22)),
              number32(logical, 252) < blocks else {
            throw DiscFailure("当前 UDF 分区映射无法安全定位文件目录。")
        }
        let nameLength = Int(logical[211])
        let label: String?
        if (2...127).contains(nameLength), [8, 16].contains(logical[84]) {
            label = String(data: logical[85..<(84 + nameLength)], encoding: logical[84] == 8 ? .isoLatin1 : .utf16BigEndian)
        } else { label = nil }
        return UDFVolumeProbe(revision: number16(logical, 240), blockBytes: 2048,
                              partitionMapType: virtual ? 2 : mapType, partitionStart: start, partitionBlocks: blocks,
                              partitionNumber: number16(partition, 22), fileSetBlock: number32(logical, 252), label: label)
    }

    private static func number16(_ data: Data, _ at: Int) -> UInt16 {
        UInt16(data[at]) | UInt16(data[at + 1]) << 8
    }
    private static func number32(_ data: Data, _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << (8 * $1) }
    }
    static func checkTag(_ data: Data, id: UInt16, address: UInt32) throws {
        guard data.count >= 16, number16(data, 0) == id, number32(data, 12) == address else {
            throw DiscFailure("UDF 描述符类型或地址不一致。")
        }
        let checksum = (0..<16).filter { $0 != 4 }.reduce(0) { $0 + Int(data[$1]) } & 0xff
        guard checksum == Int(data[4]) else { throw DiscFailure("UDF 描述符校验和不一致。") }
        let bytes = Int(number16(data, 10))
        guard bytes <= data.count - 16 else { throw DiscFailure("UDF 描述符长度越界。") }
        var crc: UInt16 = 0
        for byte in data[16..<(16 + bytes)] {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021 }
        }
        guard crc == number16(data, 8) else { throw DiscFailure("UDF 描述符 CRC 不一致。") }
    }
}
