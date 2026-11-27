import Foundation

protocol UDFEncoding {}

extension UDFEncoding {
    static func get16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    static func get32(_ data: Data, _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << (8 * $1) }
    }
    static func get64(_ data: Data, _ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[at + $1]) << (8 * $1) }
    }
    static func put16(_ data: inout Data, _ at: Int, _ value: UInt16) {
        for i in 0..<2 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    static func put32(_ data: inout Data, _ at: Int, _ value: UInt32) {
        for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    static func put64(_ data: inout Data, _ at: Int, _ value: UInt64) {
        for i in 0..<8 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    static func retag(_ data: inout Data, location: UInt32, crcLength: Int? = nil) {
        put32(&data, 12, location)
        if let crcLength { put16(&data, 10, UInt16(crcLength)) }
        var crc: UInt16 = 0
        for byte in data[16..<(16 + Int(get16(data, 10)))] {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021 }
        }
        put16(&data, 8, crc)
        data[4] = UInt8(truncatingIfNeeded: (0..<16).filter { $0 != 4 }.reduce(0) { $0 + Int(data[$1]) })
    }
}
