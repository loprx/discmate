import Foundation

struct AppendImageContext {
    let snapshot: SessionSnapshot
    let start: UInt32
    let oldFiles: [ISOEntry]
    let directories: [String]
    let added: [FileProof]
    let staging: URL
    let image: URL

    func checkedBytes() throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: image.path)
        guard let size = attrs[.size] as? NSNumber else { throw DiscFailure("无法读取追加镜像大小。") }
        try IncrementalISO.validateTarget(snapshot, imageBytes: size.uint64Value)
        return size.uint64Value
    }

}

private extension AppendImageContext {
    func makeHybrid(bridge: BridgeSession? = nil, udf: UDFVolumeProbe? = nil) throws {
        let log = image.deletingLastPathComponent().appendingPathComponent("hdiutil.log")
        try IncrementalISO.makeHybrid(staging, image: image, log: log, bridge: bridge, udf: udf)
    }

    func authorISO(bridge: BridgeSession? = nil) throws {
        try makeHybrid(bridge: bridge)
        try IncrementalISO.relocate(image, start: start, old: oldFiles, new: added, directories: directories,
            bytes: checkedBytes(), preservedPrimaryDirectories: snapshot.volume?.joliet == true || bridge != nil
                ? nil : snapshot.directoryPaths, bridge: bridge)
    }
}

protocol AppendImageFormat {
    func files(in snapshot: SessionSnapshot) -> [ISOEntry]
    func validate(_ sources: AppendSourceTree, oldFiles: [ISOEntry]) throws
    func author(_ context: AppendImageContext, proof: inout AppendProof) throws
}

extension AppendImageFormat {
    func files(in snapshot: SessionSnapshot) -> [ISOEntry] { snapshot.fileEntries }
}

enum AppendFormats {
    static func select(_ snapshot: SessionSnapshot) -> any AppendImageFormat {
        if let vat = snapshot.vat { return VATAppendFormat(vat: vat) }
        if let udf = snapshot.udf { return PhysicalUDFAppendFormat(udf: udf) }
        if let bridge = snapshot.bridge { return BridgeAppendFormat(bridge: bridge) }
        return ISOAppendFormat()
    }
}

struct ISOAppendFormat: AppendImageFormat {
    func validate(_ sources: AppendSourceTree, oldFiles: [ISOEntry]) throws {}
    func author(_ context: AppendImageContext, proof: inout AppendProof) throws {
        try context.authorISO()
    }
}

struct BridgeAppendFormat: AppendImageFormat {
    let bridge: BridgeSession
    func files(in snapshot: SessionSnapshot) -> [ISOEntry] { bridge.files }
    func validate(_ sources: AppendSourceTree, oldFiles: [ISOEntry]) throws {
        guard sources.directories.isEmpty, oldFiles.count + sources.files.count <= 32,
              sources.files.allSatisfy({ (1..<0x4000_0000).contains($0.bytes) }) else {
            throw AppendPreflightFailure(.unsupportedSource, "混合盘追加目前支持根目录普通文件，合计最多 32 个，每个新增文件须大于零且小于 1 GiB。")
        }
    }
    func author(_ context: AppendImageContext, proof: inout AppendProof) throws {
        try context.authorISO(bridge: bridge)
        var ids: [String: Data] = [:]
        for file in bridge.files {
            guard let id = bridge.primaryIDs[file.lba] else { throw DiscFailure("缺少原有 ISO 文件名。") }
            ids[file.name] = id
        }
        proof.bridgePrimaryIDs = ids
    }
}

struct PhysicalUDFAppendFormat: AppendImageFormat {
    let udf: UDFVolumeProbe
    func validate(_ sources: AppendSourceTree, oldFiles: [ISOEntry]) throws {
        guard sources.files.allSatisfy({ (1..<0x4000_0000).contains($0.bytes) }) else {
            throw AppendPreflightFailure(.unsupportedSource, "UDF 追加目前支持非空且小于 1 GiB 的普通文件。")
        }
    }
    func author(_ context: AppendImageContext, proof: inout AppendProof) throws {
        try context.makeHybrid(udf: udf)
        try PureUDFSession.relocate(image: context.image, bytes: context.checkedBytes(), start: context.start, udf: udf,
                                    old: context.oldFiles, added: context.added, directories: context.directories)
        proof.udfLabel = udf.label
    }
}

struct VATAppendFormat: AppendImageFormat {
    let vat: VATSession
    func validate(_ sources: AppendSourceTree, oldFiles: [ISOEntry]) throws {
        guard sources.directories.isEmpty, sources.files.count == 1, (1...1_048_576).contains(sources.files[0].bytes) else {
            throw AppendPreflightFailure(.unsupportedSource, "VAT 追加当前支持一个不超过 1 MiB 的非空根目录文件。")
        }
    }
    func author(_ context: AppendImageContext, proof: inout AppendProof) throws {
        let snapshot = context.snapshot, start = context.start, image = context.image
        try vat.build(start: start, files: context.added, directory: context.staging, output: image)
        let bytes = try context.checkedBytes()
        proof.udfLabel = vat.volume.label
        // Re-open the authored session using only the captured old metadata
        // and staged bytes. No second hardware operation during preparation.
        let data = try Data(contentsOf: image)
        let next = RecordedTrack(number: snapshot.latest.number + 1, session: snapshot.latest.session + 1,
            start: start, blocks: UInt32(bytes / 2048), blank: false, damaged: false,
            nextWritable: nil, freeBlocks: 0)
        let fresh = try DVDSessionReader.scanSession(identity: snapshot.identity,
            tracks: snapshot.tracks.filter { !$0.blank } + [next], latest: next, discStatus: 1, lastState: 0) { sector, count, allowed in
            guard count == 2048, allowed.contains(where: { $0.contains(sector, bytes: count) }) else {
                throw DiscFailure("VAT 镜像引用了未记录区段。")
            }
            if next.contains(sector, bytes: count) {
                let i = Int(sector - start) * 2048
                return data.subdata(in: i..<i+2048)
            }
            guard let old = vat.metadata[sector] else { throw DiscFailure("VAT 镜像引用了未经识别的旧元数据。") }
            return old
        }
        try proof.validateDirectory(fresh)
        guard fresh.vat != nil, snapshot.fileEntries.allSatisfy(fresh.fileEntries.contains) else {
            throw DiscFailure("VAT 新会话未保留完整旧目录和原区段。")
        }
    }
}
