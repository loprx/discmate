import Foundation
import DiscRecording

/// Real local ISO authoring + an independent libarchive reader. Never opens a
/// device. The builder receives directory metadata, never the old ISO's URL.
enum FolderIntegrationTests {
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("discmate-folder-iso-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        try await primaryOnlyAppend(in: root)
        try pureUDFTree(in: root)
        let old = root.appendingPathComponent("old")
        let oldContents = ["Documents/old.txt": "old root content", "Documents/nested/same.txt": "nested content",
                           "Other/same.txt": "same basename different directory", "中文目录/旧.txt": "旧正文",
                           "EmptyOldFile.txt": ""]
        var expected: [String: FileProof] = [:]
        for (path, text) in oldContents {
            let url = old.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            expected[path] = try FileProof.capture(url)
        }
        try fm.createDirectory(at: old.appendingPathComponent("EmptyOld"), withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.iso")
        try command("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", first.path, old.path], root: root)
        let firstBytes = try size(first)
        let firstTrack = RecordedTrack(number: 1, session: 1, start: 0, blocks: UInt32(firstBytes / 2048),
            blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let initial = try snapshot(first, recorded: [firstTrack])
        // The original source tree is unavailable to both incremental builds.
        try fm.removeItem(at: old)
        let sources = root.appendingPathComponent("sources")
        let newContents = ["Documents/new.txt": "new merged file", "资料/中文.txt": "新增正文",
                           "资料/nested/same.txt": "another same basename", "资料/zero.txt": ""]
        for (path, text) in newContents {
            let url = sources.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            expected[path] = try FileProof.capture(url)
        }
        try fm.createDirectory(at: sources.appendingPathComponent("Documents/new-empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sources.appendingPathComponent("资料/空目录"), withIntermediateDirectories: true)
        // A new author cannot bypass the common capacity/alignment checks.
        struct InvalidImageFormat: AppendImageFormat {
            func validate(_ sources: AppendSourceTree, oldFiles: [ISOEntry]) throws {}
            func author(_ context: AppendImageContext, proof: inout AppendProof) throws {
                try Data([0]).write(to: context.image)
            }
        }
        let rejected = root.appendingPathComponent("invalid-author")
        do {
            _ = try AppendImagePreparation.build(snapshot: initial, verified: [],
                sources: [sources.appendingPathComponent("Documents")], directory: rejected,
                selectFormat: { _ in InvalidImageFormat() })
            preconditionFailure("unaligned image accepted from a replacement author")
        } catch let failure as AppendPreflightFailure {
            precondition(failure.reason == .capacity && !fm.fileExists(atPath: rejected.path))
        }
        let prepared = try IncrementalISO.build(snapshot: initial, verified: [],
            sources: [sources.appendingPathComponent("Documents"), sources.appendingPathComponent("资料")],
            directory: root.appendingPathComponent("prepared-one"))
        precondition(prepared.addedFileCount == newContents.count && prepared.preservedFileCount == oldContents.count)
        precondition(prepared.imageBytes < 2 * 1024 * 1024)
        try prepared.validateSourcesUnchanged()
        let diagnostics = DiagnosticReportStore(directory: root.appendingPathComponent("reports"), appVersion: "0.3.8", appBuild: "1")
        let taskID = diagnostics.startTask(kind: .appendPreparation)
        diagnostics.record(taskID: taskID, event: .appendSourcesChecked, evidence: AppendDiagnostics.summary(prepared))
        diagnostics.record(taskID: taskID, event: .appendSourcesRevalidated, evidence: AppendDiagnostics.summary(prepared))
        diagnostics.finish(taskID: taskID, outcome: .completed)
        let reportData = try await diagnostics.exportData(taskID: taskID)
        let reportDecoder = JSONDecoder(); reportDecoder.dateDecodingStrategy = .iso8601
        let report = try reportDecoder.decode(DiagnosticReport.self, from: reportData)
        precondition(report.id == taskID && report.appVersion == "0.3.8" && report.outcome == .completed)
        precondition(report.events.last?.evidence?.append?.addedFiles == newContents.count)
        precondition(report.events.last?.evidence?.append?.preservedFiles == oldContents.count)
        precondition(report.events.last?.evidence?.append?.addedDirectories == 4)
        let reportText = String(decoding: reportData, as: UTF8.self)
        precondition(!reportText.contains(root.path) && !reportText.contains("Documents") && !reportText.contains("中文.txt"))
        let view = root.appendingPathComponent("latest-one.iso")
        try combine(old: first, prepared: prepared, into: view)
        let written = RecordedTrack(number: 2, session: 2, start: prepared.proof.expectedStart,
            blocks: UInt32(prepared.imageBytes / 2048), blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let second = try snapshot(view, recorded: [firstTrack, written])
        try prepared.proof.validateDirectory(second)
        try assertExtract(view, expected: expected,
            directories: ["EmptyOld", "Documents/new-empty", "资料/空目录"], root: root)
        for oldEntry in initial.fileEntries { precondition(second.fileEntries.contains(oldEntry), "Old extent moved: \(oldEntry.name)") }
        precondition(Set(second.treeEntries.map(\.name)).contains("资料/nested/same.txt"))
        let layout = try ISOTrackLayout.load(prepared.image, bytes: prepared.imageBytes)
        precondition(layout.estimateLength() == prepared.imageBytes / 2048)

        // Second incremental session adds only empty directories; old/new file
        // sources disappear and every earlier payload must still be referenced.
        try fm.removeItem(at: sources)
        let empty = root.appendingPathComponent("OnlyEmpty")
        try fm.createDirectory(at: empty.appendingPathComponent("NestedEmpty"), withIntermediateDirectories: true)
        let next = try IncrementalISO.build(snapshot: second, verified: [], sources: [empty], directory: root.appendingPathComponent("prepared-two"))
        precondition(next.proof.files.isEmpty && next.addedDirectoryCount == 2)
        let thirdView = root.appendingPathComponent("latest-two.iso")
        try combine(old: view, prepared: next, into: thirdView)
        let thirdTrack = RecordedTrack(number: 3, session: 3, start: next.proof.expectedStart,
            blocks: UInt32(next.imageBytes / 2048), blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let third = try snapshot(thirdView, recorded: [firstTrack, written, thirdTrack])
        try next.proof.validateDirectory(third)
        try next.proof.validate([], session: 3, start: next.proof.expectedStart, addedOnly: true)
        for entry in second.fileEntries { precondition(third.fileEntries.contains(entry)) }
        try assertExtract(thirdView, expected: expected,
            directories: ["EmptyOld", "Documents/new-empty", "资料/空目录", "OnlyEmpty/NestedEmpty"], root: root)
        let decoded = try JSONDecoder().decode(AppendProof.self, from: JSONEncoder().encode(next.proof))
        try decoded.validateDirectory(third)
        let readbackID = diagnostics.startTask(kind: .readback)
        diagnostics.record(taskID: readbackID, event: .readbackDirectoryMatched, evidence: AppendDiagnostics.summary(next))
        diagnostics.finish(taskID: readbackID, outcome: .completed)
        let directoryReport = try reportDecoder.decode(DiagnosticReport.self, from: await diagnostics.exportData(taskID: readbackID))
        precondition(directoryReport.events.last?.kind == .readbackDirectoryMatched)
        precondition(directoryReport.events.last?.evidence?.append?.addedFiles == 0)
        precondition(directoryReport.events.last?.evidence?.append?.addedDirectories == 2)
        print("PASS two folder ISO appends: recursive/Chinese/empty/merged directories, identical basenames, old sources deleted, independent libarchive hashes, unchanged old extents and empty-only proof")
    }

    private static func primaryOnlyAppend(in root: URL) async throws {
        let fm = FileManager.default
        let old = root.appendingPathComponent("primary-files")
        try fm.createDirectory(at: old.appendingPathComponent("docs/empty"), withIntermediateDirectories: true)
        var expected: [String: FileProof] = [:]
        for name in ["____0002.md", "docs/note.txt"] {
            let url = old.appendingPathComponent(name)
            try Data("original \(name)".utf8).write(to: url)
            expected[name] = try FileProof.capture(url)
        }
        let image = root.appendingPathComponent("primary-only.iso")
        try command("/usr/bin/hdiutil", ["makehybrid", "-iso", "-o", image.path, old.path], root: root)
        try fm.removeItem(at: old)
        let track = RecordedTrack(number: 1, session: 1, start: 0, blocks: UInt32(try size(image) / 2048),
            blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let imported = try snapshot(image, recorded: [track])
        precondition(imported.volume?.joliet == false && imported.appendState == .appendReady)
        precondition(Set(imported.fileEntries.map(\.name)) == Set(expected.keys))
        let new = root.appendingPathComponent("server(1).py")
        try Data("new payload".utf8).write(to: new)
        expected[new.lastPathComponent] = try FileProof.capture(new)
        let plan = try IncrementalISO.build(snapshot: imported, verified: [], sources: [new],
            directory: root.appendingPathComponent("primary-prepared"))
        let view = root.appendingPathComponent("primary-combined.iso")
        try combine(old: image, prepared: plan, into: view)
        let written = RecordedTrack(number: 2, session: 2, start: plan.proof.expectedStart,
            blocks: UInt32(plan.imageBytes / 2048), blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let result = try snapshot(view, recorded: [track, written])
        precondition(result.volume?.joliet == true && imported.fileEntries.allSatisfy(result.fileEntries.contains))
        try plan.proof.validateDirectory(result)
        try assertExtract(view, expected: expected, directories: ["docs/empty"], root: root)
        let primaryView = try FileHandle(forReadingFrom: view)
        defer { try? primaryView.close() }
        func readPrimary(_ sector: UInt32, _ length: UInt32) throws -> Data {
            try primaryView.seek(toOffset: UInt64(sector) * 2048)
            return try primaryView.read(upToCount: Int(length)) ?? Data()
        }
        let pvd = try ISO9660.descriptor(readPrimary(written.start + 16, 2048))!
        let primaryPaths = try RecordedDirectoryTree.scan(root: pvd.root, tracks: [track, written],
            capacityBytes: imported.identity.bytes) {
            try ISO9660.directory(readPrimary($0.lba, $0.bytes), joliet: false)
        }
        precondition(!pvd.joliet && imported.fileEntries.allSatisfy(primaryPaths.contains))
        precondition(Set(primaryPaths.filter(\.directory).map(\.name)).isSuperset(of: imported.directoryPaths))
        let layout = try ISOTrackLayout.load(plan.image, bytes: plan.imageBytes)
        precondition(layout.estimateLength() == plan.imageBytes / 2048)

        // Give the old primary file an alias that hdiutil would not choose.
        // A writer that simply regenerates all short names will lose it.
        let bridge = root.appendingPathComponent("bridge.iso")
        let bridgeSource = root.appendingPathComponent("bridge-dir")
        try fm.createDirectory(at: bridgeSource, withIntermediateDirectories: false)
        let unicodeName = "接口说明文档.md"
        try fm.copyItem(at: new, to: bridgeSource.appendingPathComponent(unicodeName))
        try command("/usr/bin/hdiutil", ["makehybrid", "-iso", "-udf", "-udf-version", "1.02", "-o", bridge.path, bridgeSource.path], root: root)
        let bridgeTrack = RecordedTrack(number: 1, session: 1, start: 0, blocks: UInt32(try size(bridge) / 2048),
            blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        var original = try Data(contentsOf: bridge)
        let rootOffset = Int(try ISO9660.both32(original, 16 * 2048 + 158)) * 2048
        let parent = rootOffset + Int(original[rootOffset])
        let record = parent + Int(original[parent])
        // Some bridge discs declare the actual directory length in the PVD.
        // Non-directory bytes after that boundary must not become ISO records.
        let used = UInt32(record - rootOffset + Int(original[record]))
        for i in 0..<4 {
            original[16*2048 + 166 + i] = UInt8(truncatingIfNeeded: used >> (8*i))
            original[16*2048 + 170 + i] = UInt8(truncatingIfNeeded: used >> (8*(3-i)))
        }
        original[rootOffset + Int(used)] = 1
        let identifier = Data("BRIDGE".utf8) + Data([0, 1]) + Data(repeating: 0, count: 24)
        original.replaceSubrange(16*2048+40..<16*2048+72, with: identifier)
        original[record + 33] = 88
        try original.write(to: bridge)
        let importedBridge = try snapshot(bridge, recorded: [bridgeTrack])
        precondition(importedBridge.appendState == .appendReady && importedBridge.filesystem == .isoUdfBridge)
        var hybridBytes = try Data(contentsOf: bridge)
        func sector(_ lba: UInt32) throws -> Data {
            let start = Int(lba) * 2048
            guard start + 2048 <= hybridBytes.count else { throw DiscFailure("测试镜像越界") }
            return hybridBytes.subdata(in: start..<(start + 2048))
        }
        let udf = try UDFVolumeProbe.inspect(sessionStart: 0, capacityBlocks: UInt64(bridgeTrack.blocks),
                                             allowISOBridge: true, readSector: sector)
        let udfFiles = try UDFDirectoryReader.entries(volume: udf, capacityBlocks: UInt64(bridgeTrack.blocks), readSector: sector)
        guard let isoFile = importedBridge.fileEntries.first, let udfFile = udfFiles.first else { fatalError("missing bridge file") }
        precondition(udfFiles.count == 1 && udfFile.path == unicodeName && isoFile.name != unicodeName)
        precondition(udfFile.bytes == isoFile.bytes && udfFile.extents == [.init(lba: isoFile.lba, bytes: isoFile.bytes)])
        let added = root.appendingPathComponent("test(1).py")
        try Data(repeating: 42, count: 21_791).write(to: added)
        let hybridPlan = try IncrementalISO.build(snapshot: importedBridge, verified: [], sources: [added],
            directory: root.appendingPathComponent("hybrid-prepared"))
        let combinedBridge = root.appendingPathComponent("combined-bridge.iso")
        try combine(old: bridge, prepared: hybridPlan, into: combinedBridge)
        let session = RecordedTrack(number: 2, session: 2, start: hybridPlan.proof.expectedStart,
            blocks: UInt32(hybridPlan.imageBytes / 2048), blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let resultBridge = try snapshot(combinedBridge, recorded: [bridgeTrack, session])
        try hybridPlan.proof.validateDirectory(resultBridge)
        let hybridLayout = try ISOTrackLayout.load(hybridPlan.image, bytes: hybridPlan.imageBytes)
        precondition(hybridLayout.estimateLength() == hybridPlan.imageBytes / 2048)
        var missingUDF = resultBridge
        missingUDF.bridge = nil
        do {
            try hybridPlan.proof.validateDirectory(missingUDF)
            fatalError("Missing UDF namespace passed bridge readback")
        } catch is DiscFailure {}
        precondition(resultBridge.bridge?.rawISOIdentifier == identifier)
        precondition(resultBridge.bridge?.primaryIDs[isoFile.lba] == importedBridge.bridge?.primaryIDs[isoFile.lba])
        precondition(resultBridge.bridge?.files.contains(where: { $0.name == unicodeName && $0.lba == isoFile.lba }) == true)
        try assertExtract(combinedBridge, expected: [unicodeName: FileProof.capture(new), added.lastPathComponent: FileProof.capture(added)],
                          directories: [], root: root)
        if let sevenZip = ProcessInfo.processInfo.environment["DISCMATE_TEST_7Z"] {
            // Select the latest UDF anchor in the standalone test file, as we
            // selected ISO descriptors for libarchive. All extents stay actual.
            let handle = try FileHandle(forUpdating: combinedBridge)
            let image = try Data(contentsOf: hybridPlan.image)
            var anchor = image.subdata(in: 256 * 2048..<257 * 2048)
            HybridUDF.retag(&anchor, location: 256)
            try handle.seek(toOffset: 256 * 2048); try handle.write(contentsOf: anchor)
            try handle.seek(toOffset: 16 * 2048); try handle.write(contentsOf: image[16 * 2048..<22 * 2048])
            try handle.close()
            let out = root.appendingPathComponent("independent-udf")
            try command(sevenZip, ["x", "-tUdf", "-o" + out.path, combinedBridge.path], root: root)
            for (name, source) in [(unicodeName, new), (added.lastPathComponent, added)] {
                let actual = try FileProof.capture(out.appendingPathComponent(name)), expected = try FileProof.capture(source)
                precondition(actual.sha256 == expected.sha256 && actual.bytes == expected.bytes)
            }
            print("PASS independent 7-Zip UDF extraction and old/new payload hashes")
        }
        let jolietBridge = root.appendingPathComponent("joliet-bridge.iso")
        try command("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-udf", "-o", jolietBridge.path, bridgeSource.path], root: root)
        let hybridTrack = RecordedTrack(number: 1, session: 1, start: 0, blocks: UInt32(try size(jolietBridge) / 2048),
            blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let jolietHybrid = try snapshot(jolietBridge, recorded: [hybridTrack])
        precondition(jolietHybrid.volume?.joliet == true && jolietHybrid.appendState == .unsupportedBridge && !jolietHybrid.importableISO)
        guard let nsr = (16..<48).first(where: { ["NSR02", "NSR03"].contains(String(decoding: hybridBytes[($0 * 2048 + 1)..<($0 * 2048 + 6)], as: UTF8.self)) }) else {
            fatalError("missing UDF marker")
        }
        hybridBytes[nsr * 2048 + 1] = 0
        let unknownURL = root.appendingPathComponent("unknown-extension.iso")
        try hybridBytes.write(to: unknownURL)
        let unknown = try snapshot(unknownURL, recorded: [bridgeTrack])
        precondition(unknown.filesystem == .isoWithUnknownExtension && unknown.appendState == .unsupportedFormat)
        let diagnostics = DiagnosticReportStore(directory: root.appendingPathComponent("primary-reports"))
        for source in [imported, importedBridge, jolietHybrid, unknown] {
            let id = diagnostics.startTask(kind: .appendPreparation)
            diagnostics.record(taskID: id, event: .preparing, evidence: DiagnosticEvidence(disc:
                DiagnosticDiscEvidence(filesystem: source.filesystem, writeState: source.appendState)))
            do {
                try source.appendState.require(.appendReady)
                diagnostics.record(taskID: id, event: .appendSourcesChecked, evidence: AppendDiagnostics.summary(source.bridge == nil ? plan : hybridPlan))
                diagnostics.finish(taskID: id, outcome: .completed)
            } catch {
                let failure = AppendDiagnostics.rejection(error)
                diagnostics.record(taskID: id, event: .appendPreflightRejected, error: failure.error, evidence: failure.evidence)
                diagnostics.finish(taskID: id, outcome: .failed)
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let data = try await diagnostics.exportData(taskID: id)
            let report = try decoder.decode(DiagnosticReport.self, from: data)
            precondition(report.id == id && report.events.contains { $0.evidence?.disc?.filesystem == source.filesystem && $0.evidence?.disc?.writeState == source.appendState })
            precondition(report.outcome == (source.appendState == .appendReady ? .completed : .failed))
            if source.appendState != .appendReady {
                precondition(report.events.last?.evidence?.append?.failure == .unavailable)
                precondition(report.events.last?.errorCodes.isEmpty == false)
            }
            precondition(!String(decoding: data, as: UTF8.self).contains("____0002.md"))
            precondition(!String(decoding: data, as: UTF8.self).contains(unicodeName))
        }
        print("PASS primary ISO and UDF 1.02 bridge append: old ISO alias, UDF names, unchanged extent, independent ISO extraction, unsupported revision rejected")
    }

    private static func size(_ file: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).uint64Value
    }

    private static func pureUDFTree(in root: URL) throws {
        let folder = root.appendingPathComponent("udf-tree")
        let assets = folder.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for index in 0..<89 {
            try Data("old content \(index)".utf8).write(to: assets.appendingPathComponent("resource-\(index)-abcdefghijk.txt"))
        }
        let first = root.appendingPathComponent("old-udf.iso")
        try command("/usr/bin/hdiutil", ["makehybrid", "-udf", "-udf-version", "1.02", "-o", first.path, folder.path], root: root)
        let added = root.appendingPathComponent("追加图片.bin")
        try Data(repeating: 0x5a, count: 484_601).write(to: added)
        try testUDFAppend(first: first, added: added, root: root)
    }

    static func testUDFAppend(first: URL, added: URL, root: URL) throws {
        let before = try Data(contentsOf: first)
        let track = RecordedTrack(number: 1, session: 1, start: 0, blocks: UInt32(before.count / 2048),
                                  blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let original = try snapshot(first, recorded: [track])
        precondition(original.filesystem == .udf102 && original.appendState == .appendReady)
        let plan = try IncrementalISO.build(snapshot: original, verified: [], sources: [added],
                                           directory: root.appendingPathComponent("udf-plan"))
        _ = try ISOTrackLayout.load(plan.image, bytes: plan.imageBytes)
        let merged = root.appendingPathComponent("combined-udf.img")
        let start = plan.proof.expectedStart
        var combined = before
        combined.append(Data(count: Int(start) * 2048 - before.count))
        combined.append(try Data(contentsOf: plan.image))
        try combined.write(to: merged)
        let second = RecordedTrack(number: 2, session: 2, start: start, blocks: UInt32(plan.imageBytes / 2048),
                                   blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let after = try snapshot(merged, recorded: [track, second])
        try plan.proof.validateDirectory(after)
        var missingFilesystem = after
        missingFilesystem.udf = nil
        do {
            try plan.proof.validateDirectory(missingFilesystem)
            fatalError("Pure UDF readback accepted a missing UDF volume")
        } catch is DiscFailure {}
        for entry in original.fileEntries {
            guard let saved = after.fileEntries.first(where: { $0.name == entry.name }), saved == entry else {
                throw DiscFailure("UDF old extent changed")
            }
            let offset = Int(entry.lba) * 2048, end = offset + Int(entry.bytes)
            precondition(combined[offset..<end] == before[offset..<end])
        }
        guard let newFile = after.fileEntries.first(where: { $0.name == added.lastPathComponent }) else {
            throw DiscFailure("UDF new file missing")
        }
        let at = Int(newFile.lba) * 2048
        let source = try Data(contentsOf: added)
        precondition(combined[at..<(at + Int(newFile.bytes))] == source)
        print("PASS pure UDF append: old files=\(original.fileEntries.count), directories=\(original.directoryPaths.count), new bytes=\(source.count), old extents and all bytes matched")
    }

    // Optional replay of the four-track November VAT sample. Both arguments
    // are local files; optical devices are never accepted by this test.
    static func replayVAT(_ image: URL, output: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == 73712*2048 else {
            throw DiscFailure("需要对应四会话样本的普通镜像文件。")
        }
        let layout: [(UInt32, UInt32)] = [(0,65264),(67312,304),(69664,1696),(73408,304)]
        var tracks = layout.enumerated().map { index, span in
            RecordedTrack(number: UInt32(index+1), session: UInt32(index+1), start: span.0, blocks: span.1,
                          blank:false, damaged:false, nextWritable:nil, freeBlocks:0)
        }
        let before = try snapshot(image, recorded: tracks)
        precondition(before.vat != nil && before.fileEntries.count == 5 && before.appendState == .appendReady)
        let vat = before.vat!
        for damageTail in [true, false] {
            do {
                _ = try VATSession.inspect(volume: vat.volume, latest: before.latest, tracks: tracks) { sector in
                    guard var block = vat.metadata[sector] else { throw DiscFailure("missing test metadata") }
                    if sector == vat.tail {
                        if damageTail { block[4] ^= 1 }
                        else {
                            VATSession.put32(&block, vat.tableOffset + Int(vat.rootIndex)*4, UInt32.max)
                            VATSession.retag(&block, location: vat.tail-vat.volume.partitionStart)
                        }
                    }
                    return block
                }
                fatalError("Damaged VAT or unmapped root accepted")
            } catch {}
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:temp, withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:temp) }
        let sample = temp.appendingPathComponent("VAT追加.txt")
        try Data("DiscMate VAT offline readback\n".utf8).write(to:sample)
        let plan = try IncrementalISO.build(snapshot:before, verified:[], sources:[sample],
                                            directory:temp.appendingPathComponent("task"))
        _ = try ISOTrackLayout.load(plan.image, bytes: plan.imageBytes)
        try combine(old:image,prepared:plan,into:output)
        let blocks = UInt32(try size(plan.image)/2048)
        tracks.append(.init(number:5,session:5,start:plan.proof.expectedStart,blocks:blocks,blank:false,
                            damaged:false,nextWritable:nil,freeBlocks:0))
        let after = try snapshot(output,recorded:tracks)
        try plan.proof.validateDirectory(after)
        precondition(after.vat != nil && after.fileEntries.count == 6)
        for saved in before.fileEntries {
            precondition(after.fileEntries.contains(saved))
        }
        print("PASS VAT append: five original extents preserved, sixth file imported from next session")
    }

    private static func snapshot(_ image: URL, recorded: [RecordedTrack]) throws -> SessionSnapshot {
        let file = try FileHandle(forReadingFrom: image); defer { try? file.close() }
        func read(_ lba: UInt32, _ bytes: UInt32, _ tracks: [RecordedTrack]) throws -> Data {
            precondition(tracks.contains { $0.contains(lba, bytes: bytes) })
            try file.seek(toOffset: UInt64(lba) * 2048)
            let data = try file.read(upToCount: Int(bytes)) ?? Data()
            precondition(data.count == Int(bytes))
            return data
        }
        let latest = recorded.last!, start = latest.start + latest.blocks + 2048
        let capacity: UInt32 = 2_295_104
        let pending = RecordedTrack(number: latest.number + 1, session: latest.session + 1, start: start,
            blocks: capacity - start, blank: true, damaged: false, nextWritable: start, freeBlocks: capacity - start)
        return try DVDSessionReader.scanSession(identity: .init(bsd: "offline-folders-only", registryID: 0, bytes: UInt64(capacity) * 2048),
            tracks: recorded + [pending], latest: latest, discStatus: 1, lastState: 0, read: read)
    }

    private static func combine(old: URL, prepared: PreparedIncrementalISO, into target: URL) throws {
        try FileManager.default.copyItem(at: old, to: target)
        let file = try FileHandle(forUpdating: target); defer { try? file.close() }
        let image = try Data(contentsOf: prepared.image)
        try file.seek(toOffset: UInt64(prepared.proof.expectedStart) * 2048); try file.write(contentsOf: image)
        // Select latest descriptors in an ordinary file for libarchive, exactly
        // as the existing root-file offline fixture; no hardware is modified.
        try file.seek(toOffset: 16 * 2048); try file.write(contentsOf: image.subdata(in: 16 * 2048..<19 * 2048))
    }

    private static func assertExtract(_ image: URL, expected: [String: FileProof], directories: [String], root: URL) throws {
        let out = root.appendingPathComponent("extract-\(UUID())")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        try command("/usr/bin/tar", ["-xf", image.path, "-C", out.path], root: root)
        for (path, proof) in expected {
            let actual = try FileProof.capture(out.appendingPathComponent(path))
            precondition(actual.bytes == proof.bytes && actual.sha256 == proof.sha256, "Extract mismatch: \(path)")
        }
        for path in directories {
            let values = try out.appendingPathComponent(path).resourceValues(forKeys: [.isDirectoryKey])
            precondition(values.isDirectory == true, "Missing empty directory: \(path)")
        }
    }

    private static func command(_ executable: String, _ arguments: [String], root: URL) throws {
        let log = root.appendingPathComponent("command-\(UUID()).log")
        try Data().write(to: log)
        let file = try FileHandle(forWritingTo: log); defer { try? file.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = file; process.standardError = file
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiscFailure("Offline fixture command failed: \(String(decoding: try Data(contentsOf: log), as: UTF8.self))")
        }
    }
}
