import Foundation
import DiscRecording

struct AppendWriteRequest {
    let snapshot: SessionSnapshot
    let prepared: PreparedIncrementalISO
    let drivePath: String?
    let speed: BurnSpeedSelection
    let verify: Bool
}

enum AppendWriteEvent {
    case progress(BurnProgress, diagnostic: DiagnosticEventKind, title: String, starting: Bool)
    case deviceOperation(DiagnosticEventKind, NSError?)
    case unmounting, unmounted, readingBack
    case closeResult(DiagnosticEventKind, Int32, UInt16, DiagnosticEvidence)
    case readbackFailed(NSError)
}

enum AppendWriteOutcome {
    case awaitingReload
    case readBack(SessionSnapshot)
}

protocol AppendWriter {
    func confirmation(_ request: AppendWriteRequest, rates: [Double]) -> (title: String, detail: String)
    @MainActor func write(_ request: AppendWriteRequest, event: (AppendWriteEvent) -> Void) async throws -> AppendWriteOutcome
}

/// Binds the selected writer and target before the confirmation is shown.
struct AppendWriteOperation {
    private let writer: any AppendWriter
    private let request: AppendWriteRequest

    init(_ request: AppendWriteRequest, select: (SessionSnapshot) -> any AppendWriter = AppendWriters.select) {
        self.request = request
        self.writer = select(request.snapshot)
    }

    func confirmation(rates: [Double]) -> (title: String, detail: String) {
        writer.confirmation(request, rates: rates)
    }

    @MainActor func write(event: (AppendWriteEvent) -> Void) async throws -> AppendWriteOutcome {
        try await writer.write(request, event: event)
    }
}

enum AppendWriters {
    static func select(_ snapshot: SessionSnapshot) -> any AppendWriter {
        if let reserved = snapshot.reservedTrack { return ReservedTrackWriter(reserved: reserved) }
        return DiscRecordingAppendWriter()
    }
}

struct DiscRecordingAppendWriter: AppendWriter {
    private static let titles = [
        DRStatusStatePreparing: "准备刻录", DRStatusStateSessionOpen: "正在开启新会话",
        DRStatusStateTrackWrite: "正在写入", DRStatusStateSessionClose: "正在关闭会话",
        DRStatusStateFinishing: "系统正在执行结束动作", DRStatusStateVerifying: "正在进行系统校验",
        DRStatusStateDone: "系统任务已结束，等待设备确认"
    ]

    func confirmation(_ request: AppendWriteRequest, rates: [Double]) -> (title: String, detail: String) {
        let title = "开始追加 \(request.prepared.addedFileCount) 个文件、\(request.prepared.addedDirectoryCount) 个目录？"
        let detail = "新增镜像 \(OperationEstimate.size(request.prepared.imageBytes))；保留 \(request.prepared.preservedFileCount) 个旧文件的原区段，不重写旧内容。盘片空间会永久占用，并保留后续追加能力。\n刻录速率：\(request.speed.label())；实际速度由设备调整。\n\n\(OperationEstimate.burn(request.prepared.imageBytes, verifyAfterWrite: request.verify))。\(request.verify ? "包含系统写后校验" : "跳过系统写后校验")，完成后自动推出。旧文件正文未在本轮校验；独立读回需重新合仓后手动执行。\n\n开始后请勿断开光驱、电源或强行退出；当前追加流程不支持安全中途取消。文件夹已在本机一张 DVD+R 验证；自动结束长期稳定性仍待验证。"
        return (title, detail)
    }

    @MainActor func write(_ request: AppendWriteRequest, event: (AppendWriteEvent) -> Void) async throws -> AppendWriteOutcome {
        let plan = request.prepared
        try await DiscBurnService.burn(snapshot: request.snapshot, proof: plan.proof,
            source: .isoImage(plan.image, bytes: plan.imageBytes, sha256: plan.imageSHA256),
            speed: request.speed, verifyAfterWrite: request.verify, sourceValidation: plan) { update in
                event(.progress(update, diagnostic: update.diagnosticEventKind,
                                title: Self.titles[update.state] ?? "系统正在处理刻录任务", starting: update.state == "Starting"))
            }
        return .awaitingReload
    }
}

struct ReservedTrackWriter: AppendWriter {
    let reserved: RecordedTrack

    func confirmation(_ request: AppendWriteRequest, rates: [Double]) -> (title: String, detail: String) {
        let title = "续写第 \(reserved.session) 会话的预留轨道？"
        let detail = "新增 \(request.prepared.addedFileCount) 个文件，保留 \(request.prepared.preservedFileCount) 个旧文件的原区段。关闭轨道会永久占用约 \(OperationEstimate.size(UInt64(reserved.blocks) * 2048))。\n速率：\(request.speed.label(supported: rates))。将核对源文件、写入镜像、关闭会话并读回新增文件。请保持光驱连接，完成后光盘留在仓内。"
        return (title, detail)
    }

    @MainActor func write(_ request: AppendWriteRequest, event: (AppendWriteEvent) -> Void) async throws -> AppendWriteOutcome {
        guard let path = request.drivePath else { throw DiscFailure("原光驱不可用。") }
        let snapshot = request.snapshot, prepared = request.prepared
        try await Task.detached { try ManualSessionClose(snapshot: snapshot, drivePath: path).checkTarget() }.value
        event(.unmounting)
        try await SessionMountService().unmountForSessionClose(snapshot.identity) { event(.deviceOperation($0, $1)) }
        event(.unmounted)
        let completion = try await Task.detached {
            try ReservedAppend.write(snapshot: snapshot, prepared: prepared, path: path, speed: request.speed)
        }.value
        let evidence = completion.evidence
        guard completion.result == 0 else {
            let uncertain = evidence.sessionClose?.attempted == true || (evidence.sessionClose?.releaseResult ?? 0) != 0
            event(.closeResult(uncertain ? .sessionCloseUnconfirmed : .sessionCloseRejected,
                               completion.result, completion.speed, evidence))
            if uncertain { throw BurnRecoveryRequired(detail: "预留轨道操作中断，盘片状态待确认（\(completion.result)）。请先重新检查设备。") }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(completion.result),
                          userInfo: [NSLocalizedDescriptionKey: "预留轨道写前复核或设置失败（\(completion.result)），未写盘。"])
        }
        event(.closeResult(.sessionCloseConfirmed, 0, completion.speed, evidence))
        event(.readingBack)
        do {
            let fresh = try await Task.detached {
                try await ReservedAppend.readback(path: path, driveID: completion.driveID, proof: prepared.proof)
            }.value
            return .readBack(fresh)
        } catch {
            event(.readbackFailed(error as NSError))
            throw DiscFailure("光驱已确认会话关闭，读回尚未通过：\(error.localizedDescription)")
        }
    }
}
