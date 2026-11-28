import CryptoKit
import Foundation

/// UDF 2.01, physical map 0 + virtual map 1. Imports only a flat embedded
/// root, ordinary extended file entries and a terminal embedded VAT.
struct VATSession: UDFEncoding, Sendable {
  var metadata: [UInt32: Data] = [:]
  let volume: UDFVolumeProbe
  let entries: [ISOEntry]
  let recognition: [Data]
  let anchor: Data
  let vat: Data
  let root: Data
  let rootIndex: UInt32
  let template: Data
  let tail: UInt32
  let tableOffset: Int

  static func inspect(
    volume: UDFVolumeProbe, latest: RecordedTrack, tracks: [RecordedTrack],
    read: (UInt32) throws -> Data
  ) throws -> Self {
    let unsupported = UDFAppendUnsupported(revision: volume.revision, partitionMapType: 2)
    let part = volume.partitionStart
    guard latest.blocks > 257,
      let end = UInt32(exactly: UInt64(latest.start) + UInt64(latest.blocks) - 1),
      end >= part
    else { throw unsupported }
    let vat = try read(end)
    try UDFVolumeProbe.checkTag(vat, id: 261, address: end - part)
    guard vat[27] == 248, get16(vat, 34) & 7 == 3, get32(vat, 168) == 0,
      get64(vat, 56) == UInt64(get32(vat, 172)), (152...1872).contains(get32(vat, 172)),
      Int(get16(vat, 10)) >= 160 + Int(get32(vat, 172))
    else { throw unsupported }
    let header = Int(get16(vat, 176))
    let limit = 176 + Int(get32(vat, 172))
    let offset = 176 + header
    guard header == 152 + Int(get16(vat, 178)), offset <= limit, (limit - offset) % 4 == 0,
      get32(vat, 316) == 1, get16(vat, 320) <= 0x0201,
      get16(vat, 322) <= 0x0201, get16(vat, 324) == 0x0201
    else { throw unsupported }
    func virtual(_ index: UInt32) throws -> Data {
      guard UInt64(index) < UInt64((limit - offset) / 4) else { throw unsupported }
      let relative = get32(vat, offset + Int(index) * 4)
      guard relative < volume.partitionBlocks,
        let address = UInt32(exactly: UInt64(part) + UInt64(relative)),
        tracks.contains(where: { $0.contains(address, bytes: 2048) })
      else { throw unsupported }
      return try read(address)
    }
    let fsd = try virtual(volume.fileSetBlock)
    try UDFVolumeProbe.checkTag(fsd, id: 256, address: volume.fileSetBlock)
    let rootIndex = get32(fsd, 404)
    guard get16(fsd, 408) == 1, get32(fsd, 448) == 0, get32(fsd, 464) == 0 else {
      throw unsupported
    }
    let root = try virtual(rootIndex)
    try UDFVolumeProbe.checkTag(root, id: 266, address: rootIndex)
    let rootBytes = get32(root, 212)
    guard root[27] == 4, get16(root, 34) & 7 == 3, get32(root, 208) == 0,
      rootBytes <= 1832, get64(root, 56) == UInt64(rootBytes),
      get64(root, 64) == UInt64(rootBytes), get32(root, 152) == 0
    else { throw unsupported }
    var cursor = 216
    var entries = [ISOEntry]()
    var names = Set<String>()
    var indices = Set<UInt32>()
    var template: Data?
    while cursor < 216 + Int(rootBytes) {
      guard cursor + 38 <= 216 + Int(rootBytes) else { throw unsupported }
      let nameBytes = Int(root[cursor + 19])
      let flags = root[cursor + 18]
      let length = (38 + nameBytes + 3) / 4 * 4
      guard get16(root, cursor + 36) == 0, cursor + length <= 216 + Int(rootBytes) else {
        throw unsupported
      }
      let fid = Data(root[cursor..<cursor + length])
      try UDFVolumeProbe.checkTag(fid, id: 257, address: rootIndex)
      cursor += length
      if flags == 10 && nameBytes == 0 && get32(fid, 24) == rootIndex { continue }
      let index = get32(fid, 24)
      guard flags == 0, nameBytes > 1, get16(fid, 28) == 1, indices.insert(index).inserted,
        [8, 16].contains(fid[38]),
        let name = String(
          data: fid[39..<38 + nameBytes],
          encoding: fid[38] == 8 ? .isoLatin1 : .utf16BigEndian),
        !name.contains("/"), AppendSourceTree.validPath(name),
        names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted
      else { throw unsupported }
      let file = try virtual(index)
      try UDFVolumeProbe.checkTag(file, id: 266, address: index)
      let size = get32(file, 216)
      guard file[27] == 5, get16(file, 34) & 7 == 1, get16(file, 48) == 1, get32(file, 208) == 0,
        get32(file, 136) == 0, get32(file, 152) == 0,
        get32(file, 212) == 16, get16(file, 224) == 0, size > 0, size < 0x4000_0000,
        get64(file, 56) == UInt64(size), get64(file, 64) == UInt64(size),
        let start = UInt32(exactly: UInt64(part) + UInt64(get32(file, 220))),
        tracks.contains(where: { $0.contains(start, bytes: size) })
      else { throw unsupported }
      entries.append(ISOEntry(name: name, lba: start, bytes: size, directory: false))
      template = file
    }
    guard let template, Int(get32(vat, 312)) == entries.count else { throw unsupported }
    let recognition = try (16...18).map { try read(latest.start + UInt32($0)) }
    guard recognition[2][1..<6] == Data("TEA01".utf8) else { throw unsupported }
    return Self(
      volume: volume, entries: entries, recognition: recognition,
      anchor: try read(latest.start + 256),
      vat: vat, root: root, rootIndex: rootIndex, template: template, tail: end, tableOffset: offset
    )
  }

  func build(start: UInt32, files: [FileProof], directory: URL, output: URL) throws {
    let invalid = AppendPreflightFailure(
      .unsupportedSource, "此 VAT 布局当前仅支持追加一个根目录普通文件（最多 1 MiB），目录和虚拟分配表须有剩余空间。")
    guard files.count == 1, let item = files.first, (1...1_048_576).contains(item.bytes),
      !item.path.contains("/"), AppendSourceTree.validPath(item.path), start > tail
    else { throw invalid }
    let source = directory.appendingPathComponent(item.path)
    let payload = try Data(contentsOf: source)
    let name = Data([16]) + (item.path.data(using: .utf16BigEndian) ?? Data())
    let size = payload.count
    let sectors = (size + 2047) / 2048
    let blocks = max(512, ((261 + sectors + 15) / 16) * 16)
    let part = volume.partitionStart
    guard size == item.bytes, name.count > 1, name.count <= 255, start >= part,
      UInt64(start) + UInt64(blocks) <= UInt64(part) + UInt64(volume.partitionBlocks),
      UInt64(start) + UInt64(blocks) <= UInt32.max
    else { throw invalid }
    var nextVAT = vat
    var nextRoot = root
    var file = template
    let limit = 176 + Int(Self.get32(vat, 172))
    guard
      let slot = stride(from: tableOffset, to: limit, by: 4).first(where: {
        Self.get32(vat, $0) == UInt32.max
      })
    else { throw invalid }
    let index = UInt32((slot - tableOffset) / 4)
    let previousID = Self.get64(vat, 160)
    guard previousID >= 16, previousID < UInt32.max - 1 else { throw invalid }
    let unique = previousID + 1
    let rootPos = start + 257
    let filePos = start + 258
    let dataPos = start + 259
    let end = start + UInt32(blocks) - 1
    var fid = Data(count: (38 + name.count + 3) / 4 * 4)
    fid.replaceSubrange(0..<16, with: root[216..<232])
    Self.put16(&fid, 16, 1)
    fid[19] = UInt8(name.count)
    Self.put32(&fid, 20, 2048)
    Self.put32(&fid, 24, index)
    Self.put16(&fid, 28, 1)
    Self.put32(&fid, 32, UInt32(unique))
    fid.replaceSubrange(38..<38 + name.count, with: name)
    Self.retag(&fid, location: rootIndex, crcLength: fid.count - 16)
    let used = Int(Self.get32(root, 212))
    let newSize = used + fid.count
    guard newSize <= 1832 else { throw invalid }
    nextRoot.replaceSubrange(216 + used..<216 + newSize, with: fid)
    Self.put64(&nextRoot, 56, UInt64(newSize))
    Self.put64(&nextRoot, 64, UInt64(newSize))
    Self.put32(&nextRoot, 212, UInt32(newSize))
    Self.put64(&file, 56, UInt64(size))
    Self.put64(&file, 64, UInt64(size))
    Self.put64(&file, 72, UInt64(sectors))
    Self.put64(&file, 200, unique)
    Self.put32(&file, 216, UInt32(size))
    Self.put32(&file, 220, dataPos - part)
    // Newly authored entries must not inherit another file's timestamps.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: Date())
    var stamp = Data(count: 12)
    Self.put16(&stamp, 0, 0x1000)
    Self.put16(&stamp, 2, UInt16(date.year!))
    for (i, n) in [date.month!, date.day!, date.hour!, date.minute!, date.second!].enumerated() {
      stamp[4 + i] = UInt8(n)
    }
    for at in [80, 92, 104, 116] { file.replaceSubrange(at..<at + 12, with: stamp) }
    for at in [92, 116] { nextRoot.replaceSubrange(at..<at + 12, with: stamp) }
    Self.retag(&nextRoot, location: rootIndex, crcLength: 200 + newSize)
    Self.retag(&file, location: index)
    Self.put32(&nextVAT, tableOffset + Int(rootIndex) * 4, rootPos - part)
    Self.put32(&nextVAT, slot, filePos - part)
    Self.put32(&nextVAT, 308, tail - part)
    Self.put32(&nextVAT, 312, UInt32(entries.count + 1))
    Self.put64(&nextVAT, 160, unique + 1)
    Self.retag(&nextVAT, location: end - part)
    var nextAnchor = anchor
    Self.retag(&nextAnchor, location: start + 256)
    var image = Data(count: blocks * 2048)
    func place(_ block: Int, _ data: Data) {
      image.replaceSubrange(block * 2048..<block * 2048 + data.count, with: data)
    }
    for (i, sector) in recognition.enumerated() { place(16 + i, sector) }
    place(256, nextAnchor)
    place(257, nextRoot)
    place(258, file)
    place(259, payload)
    place(blocks - 1, nextVAT)
    guard
      SHA256.hash(data: image[259 * 2048..<259 * 2048 + size]).map({ String(format: "%02x", $0) })
        .joined() == item.sha256
    else {
      throw DiscFailure("VAT 新文件镜像内容与源清单不一致。")
    }
    try image.write(to: output, options: .withoutOverwriting)
  }
}
