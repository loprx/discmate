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

    private static func size(_ file: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).uint64Value
    }

    private static func snapshot(_ image: URL, recorded: [RecordedTrack]) throws -> SessionSnapshot {
        let file = try FileHandle(forReadingFrom: image); defer { try? file.close() }
        func read(_ lba: UInt32, _ bytes: UInt32) throws -> Data {
            try file.seek(toOffset: UInt64(lba) * 2048)
            let data = try file.read(upToCount: Int(bytes)) ?? Data()
            precondition(data.count == Int(bytes))
            return data
        }
        let volume = try ISO9660.descriptor(read(17, 2048))!
        precondition(volume.joliet)
        var all: [ISOEntry] = []
        func visit(_ entry: ISOEntry, prefix: String) throws {
            for child in try ISO9660.directory(read(entry.lba, entry.bytes), joliet: true) {
                let path = prefix.isEmpty ? child.name : prefix + "/" + child.name
                all.append(.init(name: path, lba: child.lba, bytes: child.bytes, directory: child.directory))
                if child.directory { try visit(child, prefix: path) }
            }
        }
        try visit(volume.root, prefix: "")
        let latest = recorded.last!, start = latest.start + latest.blocks + 2048
        let capacity: UInt32 = 2_295_104
        let pending = RecordedTrack(number: latest.number + 1, session: latest.session + 1, start: start,
            blocks: capacity - start, blank: true, damaged: false, nextWritable: start, freeBlocks: capacity - start)
        return SessionSnapshot(identity: .init(bsd: "offline-folders-only", registryID: 0, bytes: UInt64(capacity) * 2048),
            tracks: recorded + [pending], latest: latest, volume: volume,
            rootEntries: all.filter { !$0.name.contains("/") }, descriptorHash: "offline", appendable: true,
            recordedEntries: all)
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
