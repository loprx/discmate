import Foundation

enum DiagnosticReportTests {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-diagnostics-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "/Users/private-person/Downloads/私人合同.pdf?token=secret-token"
        let store = DiagnosticReportStore(directory: root, appVersion: secret, appBuild: "1.2.3")
        precondition(DiagnosticDriveModel.knownModel(secret) == .unknown)
        precondition(DiagnosticDriveModel.knownModel("Lenovo Ultraslim DVD") == .lenovoUltraslimDVD)
        let first = store.startTask(kind: .dataBurn, media: .dvdPlusR,
                                    driveModel: .knownModel(secret), fileCount: 2, totalBytes: 4_000_000_000)
        let error = NSError(domain: secret, code: -536870198, userInfo: [
            NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: secret,
            NSUnderlyingErrorKey: NSError(domain: secret, code: 123, userInfo: [NSLocalizedDescriptionKey: secret])
        ])
        store.record(taskID: first, event: .preparing,
                     evidence: DiagnosticEvidence(verifyAfterWriteRequested: false))
        store.record(taskID: first, event: .deviceStatusObserved,
                     evidence: DiagnosticEvidence(verifyAfterWriteAccepted: false))
        store.record(taskID: first, event: .writing, progress: 0.5)
        store.record(taskID: first, event: .preparing, evidence: DiagnosticEvidence(refresh:
            DiagnosticRefreshEvidence(source: .deviceNotification, appeared: 1, disappeared: 0, status: 4, duplicate: 3,
                                      deferredByTask: true, deferredByBusy: false)))
        store.record(taskID: first, event: .backendFailed, error: error, backendError: [
            "DRErrorStatusErrorKey": "-536870198", "DRErrorStatusErrorStringKey": secret,
            "filename": secret, "serial": secret, "sha256": secret
        ])
        store.finish(taskID: first, outcome: .needsRecovery)
        let second = store.startTask(kind: .append)
        store.record(taskID: second, event: .preparing)
        let data = try await store.exportData(taskID: first)
        let text = String(decoding: data, as: UTF8.self)
        for value in [secret, "private-person", "私人合同", "secret-token", second.uuidString, "userInfo", "sha256", "filename"] {
            precondition(!text.contains(value), "Privacy failure: \(value)")
        }
        precondition(text.contains("-536870198") && text.contains("backendFailed") && text.contains("needsRecovery"))
        precondition(text.contains("unknown") && text.contains("1.2.3"))
        let decoded = try decode(data)
        precondition(decoded.id == first && decoded.fileCount == 2 && decoded.totalBytes == 4_000_000_000)
        precondition(decoded.events.contains { $0.evidence?.verifyAfterWriteRequested == false })
        precondition(decoded.events.contains { $0.evidence?.verifyAfterWriteAccepted == false })
        precondition(decoded.events.last?.errorCodes == [
            DiagnosticErrorCode(source: .other, code: -536870198), DiagnosticErrorCode(source: .discRecording, code: -536870198)
        ])
        precondition(!decoded.events.contains { $0.kind == .readbackAddedSourcesMatched })
        precondition(decoded.events.allSatisfy { $0.elapsedSeconds >= 0 })
        precondition(decoded.events.contains { $0.evidence?.refresh?.status == 4 &&
            $0.evidence?.refresh?.duplicate == 3 && $0.evidence?.refresh?.deferredByTask == true &&
            $0.evidence?.refresh?.source == .deviceNotification })
        let requestStore = DiagnosticReportStore(directory: root.appendingPathComponent("refresh-request"))
        let manualRequest = requestStore.startTask(kind: .refreshRequest)
        requestStore.record(taskID: manualRequest, event: .refreshRequested,
                     evidence: DiagnosticEvidence(refresh: DiagnosticRefreshEvidence(source: .manual, deferredByTask: true)))
        requestStore.record(taskID: manualRequest, event: .refreshCoalesced)
        requestStore.record(taskID: manualRequest, event: .refreshDispatched)
        requestStore.finish(taskID: manualRequest, outcome: .completed)
        let manualReport = try decode(await requestStore.exportData(taskID: manualRequest))
        precondition(manualReport.task == .refreshRequest && manualReport.outcome == .completed)
        precondition(manualReport.events.map(\.kind).suffix(3) == [.refreshRequested, .refreshCoalesced, .refreshDispatched])
        precondition(manualReport.events.contains { $0.evidence?.refresh?.deferredByTask == true })
        let summaryStore = DiagnosticReportStore(directory: root.appendingPathComponent("first-summary"))
        let summary = summaryStore.startTask(kind: .firstBurnSummary, media: .dvdPlusR,
                                             fileCount: 2, totalBytes: 4096)
        summaryStore.record(taskID: summary, event: .summaryViewed)
        summaryStore.finish(taskID: summary, outcome: .completed)
        let summaryData = try await summaryStore.exportData(taskID: summary)
        let summaryReport = try decode(summaryData)
        precondition(summaryReport.task == .firstBurnSummary && summaryReport.outcome == .completed)
        precondition(summaryReport.fileCount == 2 && summaryReport.totalBytes == 4096)
        precondition(summaryReport.events.map(\.kind) == [.started, .summaryViewed])
        precondition(!String(decoding: summaryData, as: UTF8.self).contains(secret))
        precondition(DiagnosticErrorCode.extract(error: NSError(domain: "DiscMate.Process", code: 42),
            backendError: nil) == [DiagnosticErrorCode(source: .process, code: 42)])
        precondition(DiagnosticErrorCode.extract(error: NSError(domain: NSOSStatusErrorDomain, code: -119930868),
            backendError: nil) == [DiagnosticErrorCode(source: .osStatus, code: -119930868)])

        let preflight = store.startTask(kind: .erase, media: .dvdPlusRW)
        store.record(taskID: preflight, event: .preparing)
        store.record(taskID: preflight, event: .preflightIdentityRejected,
                     error: LegacyPreflightFailure.changedMedium as NSError)
        store.finish(taskID: preflight, outcome: .failed)
        let preflightData = try await store.exportData(taskID: preflight)
        let preflightReport = try decode(preflightData)
        precondition(preflightReport.events.map(\.kind) == [.started, .preparing, .preflightIdentityRejected])
        precondition(preflightReport.outcome == .failed)
        precondition(!String(decoding: preflightData, as: UTF8.self).contains(secret))

        let clipboard = store.startTask(kind: .clipboardImport, fileCount: 1, totalBytes: UInt64(secret.utf8.count))
        store.record(taskID: clipboard, event: .clipboardPasteShortcut)
        store.record(taskID: clipboard, event: .clipboardTextStaged)
        store.finish(taskID: clipboard, outcome: .completed)
        let clipboardData = try await store.exportData(taskID: clipboard)
        let clipboardReport = try decode(clipboardData)
        precondition(clipboardReport.task == .clipboardImport && clipboardReport.fileCount == 1)
        precondition(clipboardReport.events.map(\.kind) == [.started, .clipboardPasteShortcut, .clipboardTextStaged])
        precondition(!String(decoding: clipboardData, as: UTF8.self).contains(secret))
        let clipboardFailure = store.startTask(kind: .clipboardImport)
        store.record(taskID: clipboardFailure, event: .clipboardImportFailed,
                     error: NSError(domain: secret, code: 13, userInfo: [NSLocalizedDescriptionKey: secret]))
        store.finish(taskID: clipboardFailure, outcome: .failed)
        let failureData = try await store.exportData(taskID: clipboardFailure)
        let failureReport = try decode(failureData)
        precondition(failureReport.outcome == .failed)
        precondition(!String(decoding: failureData, as: UTF8.self).contains(secret))

        // Reject malicious numeric fields and preserve genuine hexadecimal codes.
        for candidate: Any in ["123 \(secret)", "12.5", "１", "18446744073709551616", true, " 1", "1\n"] {
            precondition(DiagnosticErrorCode.extract(error: nil, backendError: ["DRErrorStatusErrorKey": candidate]).isEmpty)
        }
        precondition(DiagnosticErrorCode.extract(error: nil, backendError: ["DRErrorStatusErrorKey": "0xE00002CA"]).first?.code == 3_758_097_098)

        // Frequent identical progress coalesces; invalid progress never traps or
        // emits NaN. A long task remains bounded and retains its original start.
        for _ in 0..<500 { store.record(taskID: second, event: .writing, progress: 0.1234) }
        var snapshot = try await decode(store.exportData(taskID: second))
        precondition(snapshot.events.count == 3)
        for progress in [Double.nan, .infinity, -.infinity, -1, 2] {
            store.record(taskID: second, event: .writing, progress: progress)
        }
        for index in 0..<350 { store.record(taskID: second, event: index.isMultiple(of: 2) ? .waiting : .finishing) }
        store.record(taskID: second, event: .backendDone)
        snapshot = try await decode(store.exportData(taskID: second))
        precondition(snapshot.events.count == DiagnosticReportStore.maximumEvents)
        precondition(snapshot.omittedEventCount > 0 && snapshot.events.first?.kind == .started)
        precondition(snapshot.events.last?.kind == .backendDone)
        precondition(snapshot.outcome == .inProgress, "Backend Done must not imply device/readback completion")

        // Restart reads the same sanitized archive and does not change an
        // unfinished task to success. Export includes exactly one selected task.
        let restarted = DiagnosticReportStore(directory: root)
        let recovered = await restarted.reports()
        precondition(recovered.count == 5 && recovered.first?.outcome == .failed)
        let recoveredData = try await restarted.exportData(taskID: first)
        precondition(recoveredData == data)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("history.json").path)
        precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        for _ in 0..<40 { _ = store.startTask(kind: .deviceRefresh) }
        let bounded = await store.reports()
        precondition(bounded.count == DiagnosticReportStore.maximumReports)
        do { _ = try await store.exportData(taskID: first); preconditionFailure("Evicted task unexpectedly exported") }
        catch DiagnosticExportError.taskUnavailable { }

        // A tampered persisted string cannot bypass the whitelist at load time.
        let tamperedDir = root.appendingPathComponent("tampered")
        try FileManager.default.createDirectory(at: tamperedDir, withIntermediateDirectories: true)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["appVersion"] = secret
        try JSONSerialization.data(withJSONObject: [json]).write(to: tamperedDir.appendingPathComponent("history.json"))
        let tampered = DiagnosticReportStore(directory: tamperedDir)
        let tamperedReports = await tampered.reports()
        let tamperedIssue = await tampered.persistenceIssue()
        precondition(tamperedReports.isEmpty && tamperedIssue)
        let unavailable = DiagnosticReportStore(directory: root.appendingPathComponent("history.json/subdirectory"))
        let transient = unavailable.startTask(kind: .erase)
        _ = try await unavailable.exportData(taskID: transient)
        let unavailableIssue = await unavailable.persistenceIssue()
        precondition(unavailableIssue)
        try await evidenceTests(root: root, secret: secret)
        try await retentionTests(root: root)
        try await appendPreflightTests(root: root, secret: secret)
        try await mediaReturnReportTests(root: root, secret: secret)
        print("PASS diagnostics: privacy whitelist, numeric errors, preview export selection, persistence, bounded history/progress and storage failure")
    }

    private static func mediaReturnReportTests(root: URL, secret: String) async throws {
        let store = DiagnosticReportStore(directory: root.appendingPathComponent("media-return"),
                                          appVersion: "0.3.8", appBuild: "2026101603")
        let id = store.startTask(kind: .append, media: .dvdPlusR)
        store.record(taskID: id, event: .backendDone)
        store.record(taskID: id, event: .backendReleased)
        store.record(taskID: id, event: .registryObserved,
                     evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(registryMediaPresent: false)))
        store.record(taskID: id, event: .mediaReturnedDuringCompletion,
                     evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(registryMediaPresent: true)))
        store.finish(taskID: id, outcome: .completed)
        let data = try await store.exportData(taskID: id)
        let report = try decode(data)
        precondition(report.id == id && report.outcome == .completed)
        precondition(report.events.map(\.kind).suffix(4) ==
                     [.backendDone, .backendReleased, .registryObserved, .mediaReturnedDuringCompletion])
        precondition(!report.events.contains { $0.kind == .ejectRequested || $0.kind == .ejectCompleted })
        precondition(!String(decoding: data, as: UTF8.self).contains(secret))
        let restored = DiagnosticReportStore(directory: root.appendingPathComponent("media-return"))
        let replay = try await decode(restored.exportData(taskID: id))
        precondition(replay.events.last?.kind == .mediaReturnedDuringCompletion)
    }

    private static func appendPreflightTests(root: URL, secret: String) async throws {
        let store = DiagnosticReportStore(directory: root.appendingPathComponent("append-preflight"), appVersion: "0.3.8", appBuild: "1")
        let success = store.startTask(kind: .appendPreparation)
        let counts = DiagnosticAppendEvidence(failure: nil, addedFiles: 3, addedDirectories: 2,
            preservedFiles: 4, preservedDirectories: 1, addedBytes: 123, sessionAllowanceBytes: 32 * 1024 * 1024)
        store.record(taskID: success, event: .appendSourcesChecked, evidence: DiagnosticEvidence(append: counts))
        store.record(taskID: success, event: .appendSourcesRevalidated, evidence: DiagnosticEvidence(append: counts))
        store.finish(taskID: success, outcome: .completed)
        let report = try await decode(store.exportData(taskID: success))
        precondition(report.appVersion == "0.3.8" && report.outcome == .completed)
        precondition(report.events.last?.evidence?.append == counts)
        for reason: DiagnosticAppendFailure in [.conflict, .unsupportedSource, .invalidName, .sourceChanged, .capacity, .invalidTree, .unavailable, .other] {
            let id = store.startTask(kind: .appendPreparation)
            let evidence = DiagnosticAppendEvidence(failure: reason, addedFiles: nil, addedDirectories: nil,
                preservedFiles: nil, preservedDirectories: nil, addedBytes: nil, sessionAllowanceBytes: nil)
            store.record(taskID: id, event: .appendPreflightRejected,
                error: NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSLocalizedDescriptionKey: secret]),
                evidence: DiagnosticEvidence(append: evidence))
            store.finish(taskID: id, outcome: .failed)
            let data = try await store.exportData(taskID: id)
            let failed = try decode(data)
            precondition(failed.id == id && failed.outcome == .failed)
            precondition(failed.events.last?.kind == .appendPreflightRejected)
            precondition(failed.events.last?.evidence?.append?.failure == reason)
            precondition(failed.events.last?.errorCodes == [.init(source: .posix, code: 13)])
            precondition(!String(decoding: data, as: UTF8.self).contains(secret))
        }
        let invalid = DiagnosticAppendEvidence(failure: nil, addedFiles: -1, addedDirectories: nil,
            preservedFiles: nil, preservedDirectories: nil, addedBytes: nil, sessionAllowanceBytes: nil)
        precondition(DiagnosticEvidence(append: invalid).append == nil)
        let reopened = DiagnosticReportStore(directory: root.appendingPathComponent("append-preflight"))
        let restored = try await decode(reopened.exportData(taskID: success))
        precondition(restored.events.last?.evidence?.append == counts)
        print("PASS append diagnostics: success/failure classification, counts, numeric errors, redaction and restart")
    }

    private static func retentionTests(root: URL) async throws {
        let store = DiagnosticReportStore(directory: root.appendingPathComponent("retention"))
        let id = store.startTask(kind: .append)
        store.record(taskID: id, event: .writing, progress: 0,
                     evidence: DiagnosticEvidence(backendState: .trackWrite, actualSpeedKBps: 1_024))
        store.record(taskID: id, event: .writing, progress: 0.01,
                     backendError: ["DRErrorStatusErrorKey": -536870198],
                     evidence: DiagnosticEvidence(backendState: .trackWrite, actualSpeedKBps: 1_000))
        for index in 1...400 {
            store.record(taskID: id, event: .writing, progress: Double(index) / 400,
                         evidence: DiagnosticEvidence(backendState: .trackWrite, actualSpeedKBps: Double(2_000 + index)))
        }
        store.record(taskID: id, event: .verifying, progress: 0,
                     evidence: DiagnosticEvidence(backendState: .verifying, actualSpeedKBps: 512))
        for index in 1...400 {
            store.record(taskID: id, event: .verifying, progress: Double(index) / 400,
                         evidence: DiagnosticEvidence(backendState: .verifying, actualSpeedKBps: Double(3_000 + index)))
        }
        store.record(taskID: id, event: .backendDone, evidence: DiagnosticEvidence(backendState: .done))
        store.finish(taskID: id, outcome: .completed)
        let data = try await store.exportData(taskID: id)
        let report = try decode(data)
        precondition(report.events.count == DiagnosticReportStore.maximumEvents && report.omittedEventCount > 0)
        precondition(report.events.first?.kind == .started && report.events.last?.kind == .backendDone)
        let writing = report.events.filter { $0.kind == .writing }
        let verifying = report.events.filter { $0.kind == .verifying }
        precondition(writing.first?.progressPercent == 0 && writing.first?.evidence?.actualSpeedKBps == 1_024)
        precondition(verifying.first?.progressPercent == 0 && verifying.first?.evidence?.actualSpeedKBps == 512)
        precondition(writing.last?.progressPercent == 100 && verifying.last?.progressPercent == 100)
        precondition(report.events.contains { $0.errorCodes.contains { $0.code == -536870198 } })
        let recordedTotal = 1 + 1 + 1 + 400 + 1 + 400 + 1
        precondition(report.events.count + report.omittedEventCount == recordedTotal)
        print("PASS diagnostic retention: 800 rate changes preserve phase beginnings/endings, original errors, terminal state and omission accounting")
    }

    private static func evidenceTests(root: URL, secret: String) async throws {
        // Fixed sense: validity bit belongs to INFORMATION, not to key/ASC/ASCQ.
        // Padding/vendor bytes deliberately contain private data; none is kept.
        var fixed = Data(repeating: 0, count: 18)
        fixed[0] = 0xF0; fixed[2] = 0xE3; fixed[7] = 10; fixed[12] = 0x0C; fixed[13] = 0x09
        fixed.append(Data(secret.utf8))
        let sense = DiagnosticSense.parse(fixed)!
        precondition(sense.responseCode == 0x70 && sense.key == 3 && sense.asc == 0x0C && sense.ascq == 0x09)
        fixed[0] = 0x71
        precondition(DiagnosticSense.parse(fixed)?.responseCode == 0x71)
        for code: UInt8 in [0x72, 0x73] {
            let descriptor = Data([code, 0x05, 0x24, 0, 0, 0, 0, 0])
            let parsed = DiagnosticSense.parse(descriptor)!
            precondition(parsed.responseCode == code && parsed.key == 5 && parsed.asc == 0x24 && parsed.ascq == 0)
        }
        for length in 0..<18 { precondition(DiagnosticSense.parse(Data(fixed.prefix(length))) == nil) }
        var malformed = fixed; malformed[7] = 5
        precondition(DiagnosticSense.parse(malformed) == nil)
        malformed[7] = 255
        precondition(DiagnosticSense.parse(malformed) == nil)
        for code: UInt8 in [0, 0x6F, 0x74, 0xF2, 0xF3] {
            malformed = fixed; malformed[0] = code
            precondition(DiagnosticSense.parse(malformed) == nil)
        }
        precondition(DiagnosticSense.parse(Data([0x72, 5, 0x24, 0, 0, 0, 0, 1])) == nil)
        precondition(DiagnosticSense.extract(backendError: ["DRErrorStatusSenseKey": secret]) == nil)
        precondition(DiagnosticBackendState.fromSystemState(secret) == .unknown)
        precondition(DiagnosticBackendState.fromSystemState("DRStatusStateSessionClose") == .sessionClose)
        for speed in [Double.nan, .infinity, -.infinity, -1, 0, 1_000_001, Double.greatestFiniteMagnitude] {
            let evidence = DiagnosticEvidence(requestedSpeedKBps: speed, actualSpeedKBps: speed)
            precondition(evidence.requestedSpeedKBps == nil && evidence.actualSpeedKBps == nil)
        }
        precondition(DiagnosticEvidence(actualSpeedKBps: 1_000_000).actualSpeedKBps == 1_000_000)
        precondition(DiagnosticEvidence(actualSpeedKBps: 0.5).actualSpeedKBps == 0.5)
        precondition(DiagnosticEvidence().requestedSpeedAutomatic == nil)
        let automatic = DiagnosticEvidence(requestedSpeedKBps: 65_535, requestedSpeedAutomatic: true)
        precondition(automatic.requestedSpeedAutomatic == true && automatic.requestedSpeedKBps == nil)

        let directory = root.appendingPathComponent("evidence")
        let store = DiagnosticReportStore(directory: directory)
        let id = store.startTask(kind: .dataBurn)
        let device = DiagnosticDeviceEvidence(busy: true, trayOpen: false, mediaAbsent: false,
                                              identityConfirmed: true, registryMediaPresent: true)
        let first = DiagnosticEvidence(backendState: .trackWrite, requestedSpeedKBps: 5_540,
                                       actualSpeedKBps: 4_000, device: device)
        store.record(taskID: id, event: .writing, progress: 0.5, evidence: first)
        store.record(taskID: id, event: .writing, progress: 0.5, evidence: first)
        let second = DiagnosticEvidence(backendState: .trackWrite, requestedSpeedKBps: 5_540,
                                        actualSpeedKBps: 3_000, device: device)
        store.record(taskID: id, event: .writing, progress: 0.5, evidence: second)
        store.record(taskID: id, event: .finishing, evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(
            busy: false, trayOpen: true, mediaAbsent: true, identityConfirmed: true, registryMediaPresent: false)))
        let failure = DiagnosticEvidence(backendState: .failed)
        store.record(taskID: id, event: .backendFailed, backendError: ["DRErrorStatusSenseKey": fixed], evidence: failure)
        fixed[13] = 0x07
        store.record(taskID: id, event: .backendFailed, backendError: ["DRErrorStatusSenseKey": fixed], evidence: failure)
        let data = try await store.exportData(taskID: id)
        let report = try decode(data)
        precondition(report.events.count == 6, "Changed rates, device state and sense must survive deduplication")
        precondition(report.events[1].evidence == first && report.events[2].evidence == second)
        precondition(report.events.last?.evidence?.sense?.ascq == 7)
        precondition(report.events[3].evidence?.device?.busy == false)
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.contains(secret) && !text.contains(fixed.base64EncodedString()))
        precondition(text.contains("registryMediaPresent") && text.contains("requestedSpeedKBps"))
        let reloaded = DiagnosticReportStore(directory: directory)
        let restored = try await reloaded.exportData(taskID: id)
        precondition(restored == data)

        // Optional evidence allows loading reports written before these fields.
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var events = legacy["events"] as! [[String: Any]]
        events = events.map { var value = $0; value.removeValue(forKey: "evidence"); return value }
        legacy["events"] = events
        let legacyDirectory = root.appendingPathComponent("legacy-evidence")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [legacy]).write(to: legacyDirectory.appendingPathComponent("history.json"))
        let legacyReports = await DiagnosticReportStore(directory: legacyDirectory).reports()
        precondition(legacyReports.count == 1 && legacyReports[0].events.allSatisfy { $0.evidence == nil })
        var oldRefresh = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var oldEvents = oldRefresh["events"] as! [[String: Any]]
        if var evidence = oldEvents[2]["evidence"] as? [String: Any],
           var refresh = evidence["refresh"] as? [String: Any] {
            refresh.removeValue(forKey: "source")
            evidence["refresh"] = refresh
            oldEvents[2]["evidence"] = evidence
        }
        oldRefresh["events"] = oldEvents
        let oldRefreshDirectory = root.appendingPathComponent("old-refresh")
        try FileManager.default.createDirectory(at: oldRefreshDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [oldRefresh]).write(to: oldRefreshDirectory.appendingPathComponent("history.json"))
        let oldRefreshReport = await DiagnosticReportStore(directory: oldRefreshDirectory).reports()
        precondition(oldRefreshReport.count == 1 && oldRefreshReport[0].events[2].evidence?.refresh?.source == nil)

        // Replay the observed post-eject gap without touching hardware: USB
        // remained visible while the optical driver and media node were absent.
        // The report must distinguish that state from a missing USB device and
        // retain each transition without exporting a serial, path or filename.
        let registryStore = DiagnosticReportStore(directory: root.appendingPathComponent("registry"))
        let registryTask = registryStore.startTask(kind: .deviceRefresh, driveModel: .lenovoUltraslimDVD)
        let usbOnly = DiagnosticOpticalRegistryEvidence(discRecordingDevices: 0,
            lenovoUSBDevices: 1, opticalPeripherals: 0, dvdMedia: 0)
        let ready = DiagnosticOpticalRegistryEvidence(discRecordingDevices: 1,
            lenovoUSBDevices: 1, opticalPeripherals: 1, dvdMedia: 1)
        registryStore.record(taskID: registryTask, event: .registryObserved,
            evidence: DiagnosticEvidence(opticalRegistry: usbOnly))
        registryStore.record(taskID: registryTask, event: .deviceUnavailable)
        registryStore.record(taskID: registryTask, event: .registryObserved,
            evidence: DiagnosticEvidence(opticalRegistry: ready))
        registryStore.record(taskID: registryTask, event: .deviceAvailable)
        registryStore.finish(taskID: registryTask, outcome: .completed)
        let registryData = try await registryStore.exportData(taskID: registryTask)
        let registryReport = try decode(registryData)
        precondition(registryReport.events.compactMap { $0.evidence?.opticalRegistry } == [usbOnly, ready])
        precondition(!String(decoding: registryData, as: UTF8.self).contains(secret))
        precondition(DiagnosticEvidence(opticalRegistry: DiagnosticOpticalRegistryEvidence(
            discRecordingDevices: 1_025, lenovoUSBDevices: 0, opticalPeripherals: 0, dvdMedia: 0)).opticalRegistry == nil)
        let restoredRegistryData = try await DiagnosticReportStore(directory: root.appendingPathComponent("registry"))
            .exportData(taskID: registryTask)
        precondition(restoredRegistryData == registryData)
        let registryFailure = registryStore.startTask(kind: .deviceRefresh)
        registryStore.record(taskID: registryFailure, event: .registryObserved,
            error: NSError(domain: NSPOSIXErrorDomain, code: 5))
        registryStore.finish(taskID: registryFailure, outcome: .completed)
        let failedProbe = try await decode(registryStore.exportData(taskID: registryFailure))
        precondition(failedProbe.events.last?.errorCodes == [DiagnosticErrorCode(source: .posix, code: 5)])
        precondition(failedProbe.events.last?.evidence?.opticalRegistry == nil,
                     "A failed registry probe must not manufacture a zero-count snapshot")

        // Auto speed and unavailable speed are different observations. Unknown
        // device identity/media remain nil, never a fabricated false value.
        let autoID = store.startTask(kind: .dataBurn)
        let auto = DiagnosticEvidence(requestedSpeedAutomatic: true)
        store.record(taskID: autoID, event: .preparing, evidence: auto)
        store.record(taskID: autoID, event: .preparing, evidence: DiagnosticEvidence())
        store.record(taskID: autoID, event: .registryObserved, evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence()))
        store.record(taskID: autoID, event: .deviceStatusObserved, evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(mediaAbsent: false)))
        for event: DiagnosticEventKind in [.panelCreationFailed, .backendObservationUnavailable, .panelFinished, .backendReleased] {
            store.record(taskID: autoID, event: event)
        }
        let autoData = try await store.exportData(taskID: autoID)
        let autoReport = try decode(autoData)
        precondition(autoReport.events.count == 9)
        precondition(autoReport.events[1].evidence?.requestedSpeedAutomatic == true)
        precondition(autoReport.events[2].evidence?.requestedSpeedAutomatic == nil)
        let unknown = autoReport.events[3].evidence?.device
        precondition(unknown != nil && unknown?.busy == nil && unknown?.mediaAbsent == nil && unknown?.identityConfirmed == nil && unknown?.registryMediaPresent == nil)
        precondition(autoReport.events[4].evidence?.device?.mediaAbsent == false)
        // Existing evidence records predate the optional automatic flag too.
        let oldRate = report.events[1].evidence
        precondition(oldRate?.requestedSpeedAutomatic == nil && oldRate?.requestedSpeedKBps == 5_540)
        let autoRestart = DiagnosticReportStore(directory: directory)
        let autoRestored = try await autoRestart.exportData(taskID: autoID)
        precondition(autoRestored == autoData)

        let discID = store.startTask(kind: .append)
        let disc = DiagnosticDiscEvidence(latestSession: 3, latestStartLBA: 5_024,
            nextWritableLBA: 7_536, freeBlocks: 2_000_000, rootEntryCount: 2,
            appendable: true, imageBytes: 921_600)
        let discEvidence = DiagnosticEvidence(disc: disc)
        store.record(taskID: discID, event: .preparing, backendError: [
            "DRErrorStatusSenseKey": fixed, "fileName": secret, "serial": secret, "hash": secret
        ], evidence: discEvidence)
        store.record(taskID: discID, event: .preparing, progress: 0, evidence: discEvidence)
        for index in 1...300 {
            store.record(taskID: discID, event: .preparing, progress: Double(index) / 300,
                evidence: DiagnosticEvidence(backendState: .preparing, actualSpeedKBps: Double(index)))
        }
        let discData = try await store.exportData(taskID: discID)
        let discReport = try decode(discData)
        let preservedDisc = discReport.events.first { $0.evidence?.disc != nil }
        precondition(preservedDisc?.evidence?.disc == disc && preservedDisc?.evidence?.sense != nil)
        precondition(discReport.events.contains { $0.evidence?.disc == disc && $0.evidence?.sense == nil && $0.progressPercent == 0 })
        precondition(!String(decoding: discData, as: UTF8.self).contains(secret))
        let discRestarted = DiagnosticReportStore(directory: directory)
        let discRestoredData = try await discRestarted.exportData(taskID: discID)
        precondition(discRestoredData == discData)
        precondition(report.events.allSatisfy { $0.evidence?.disc == nil }, "Older evidence must preserve unknown disc metadata")

        // Codable input is checked again at the persistence boundary.
        for evidence: [String: Any] in [
            ["actualSpeedKBps": -1], ["requestedSpeedKBps": 1_000_001],
            ["backendState": secret], ["sense": ["responseCode": 0x70, "key": 255, "asc": 0, "ascq": 0]],
            ["sense": ["responseCode": 0x74, "key": 1, "asc": 0, "ascq": 0]]
        ] {
            var changed = legacy
            var changedEvents = events
            changedEvents[0]["evidence"] = evidence
            changed["events"] = changedEvents
            try JSONSerialization.data(withJSONObject: [changed]).write(to: legacyDirectory.appendingPathComponent("history.json"))
            let invalid = DiagnosticReportStore(directory: legacyDirectory)
            let reports = await invalid.reports()
            let issue = await invalid.persistenceIssue()
            precondition(reports.isEmpty && issue)
        }
        print("PASS diagnostic evidence: safe backend states, bounded rates, fixed/descriptor sense, device flags, dedup, privacy and legacy persistence")
    }

    private static func decode(_ data: Data) throws -> DiagnosticReport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticReport.self, from: data)
    }
}
