import DiscRecording
import Foundation

struct DiscWriteRejected: LocalizedError {
    let state: DiscWriteState
    var errorDescription: String? { "无法按所选方式写入。当前状态为“\(state.title)”。" }
}

extension DiscWriteState {
    func require(_ expected: Self) throws {
        guard self == expected else { throw DiscWriteRejected(state: self) }
    }
    var title: String {
        switch self {
        case .noDisc: return "未放入光盘"
        case .unknown: return "光盘写入状态待确认"
        case .busy: return "光驱忙，写入状态待确认"
        case .readOnly: return "只读光盘"
        case .unsupportedDrive: return "当前光驱不支持写入这种盘片"
        case .full: return "光盘没有剩余可写空间"
        case .notAppendable: return "此盘当前不可追加"
        case .blankCandidate: return "检测到空白盘，可查看刻录摘要"
        case .appendCandidate: return "已有数据，追加条件待核实"
        case .unsupportedFormat: return "DiscMate 暂不支持向这种格式追加数据"
        case .unsupportedBridge: return "ISO/UDF 混合光盘可读取，DiscMate 暂不支持保留两套目录追加"
        case .incompleteSession: return "末次会话未正常结束，追加已暂停"
        case .noWritableTrack: return "未确认有效的下一写入位置，追加已暂停"
        case .insufficientSpace: return "剩余空间不足以容纳追加会话"
        case .appendReady: return "已确认追加位置和可用空间"
        }
    }

    var permitsWritePreparation: Bool {
        self == .blankCandidate || self == .appendCandidate || self == .appendReady
    }

    static func freeBlocks(_ media: NSDictionary?) -> UInt32? {
        guard let number = media?[DRDeviceMediaBlocksFreeKey] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt32(number.stringValue)
    }

    private static let writeKeys = [
        DRDeviceMediaTypeCDR: DRDeviceCanWriteCDRKey,
        DRDeviceMediaTypeCDRW: DRDeviceCanWriteCDRWKey,
        DRDeviceMediaTypeDVDR: DRDeviceCanWriteDVDRKey,
        DRDeviceMediaTypeDVDRDualLayer: DRDeviceCanWriteDVDRDualLayerKey,
        DRDeviceMediaTypeDVDRW: DRDeviceCanWriteDVDRWKey,
        DRDeviceMediaTypeDVDRWDualLayer: DRDeviceCanWriteDVDRWDualLayerKey,
        DRDeviceMediaTypeDVDRAM: DRDeviceCanWriteDVDRAMKey,
        DRDeviceMediaTypeDVDPlusR: DRDeviceCanWriteDVDPlusRKey,
        DRDeviceMediaTypeDVDPlusRDoubleLayer: DRDeviceCanWriteDVDPlusRDoubleLayerKey,
        DRDeviceMediaTypeDVDPlusRW: DRDeviceCanWriteDVDPlusRWKey,
        DRDeviceMediaTypeDVDPlusRWDoubleLayer: DRDeviceCanWriteDVDPlusRWDoubleLayerKey,
        DRDeviceMediaTypeBDR: DRDeviceCanWriteBDRKey,
        DRDeviceMediaTypeBDRE: DRDeviceCanWriteBDREKey,
        DRDeviceMediaTypeHDDVDR: DRDeviceCanWriteHDDVDRKey,
        DRDeviceMediaTypeHDDVDRDualLayer: DRDeviceCanWriteHDDVDRDualLayerKey,
        DRDeviceMediaTypeHDDVDRAM: DRDeviceCanWriteHDDVDRAMKey,
        DRDeviceMediaTypeHDDVDRW: DRDeviceCanWriteHDDVDRWKey,
        DRDeviceMediaTypeHDDVDRWDualLayer: DRDeviceCanWriteHDDVDRWDualLayerKey,
    ]

    static func presence(_ status: NSDictionary) -> Bool? {
        switch status[DRDeviceMediaStateKey] as? String {
        case DRDeviceMediaStateNone: return false
        case DRDeviceMediaStateMediaPresent: return true
        default: return nil
        }
    }

    static func classify(status: NSDictionary, driveInfo: NSDictionary) -> Self {
        guard let present = presence(status) else { return .unknown }
        guard present else { return .noDisc }
        if (status[DRDeviceIsBusyKey] as? NSNumber)?.boolValue == true { return .busy }
        guard let media = status[DRDeviceMediaInfoKey] as? NSDictionary,
              let type = media[DRDeviceMediaTypeKey] as? String else { return .unknown }
        if [DRDeviceMediaTypeCDROM, DRDeviceMediaTypeDVDROM, DRDeviceMediaTypeBDROM, DRDeviceMediaTypeHDDVDROM].contains(type) {
            return .readOnly
        }
        let blank = (media[DRDeviceMediaIsBlankKey] as? NSNumber)?.boolValue
        let appendable = (media[DRDeviceMediaIsAppendableKey] as? NSNumber)?.boolValue
        if freeBlocks(media) == 0 { return .full }
        if blank == false && appendable == false { return .notAppendable }
        guard let key = writeKeys[type],
              let capabilities = driveInfo[DRDeviceWriteCapabilitiesKey] as? NSDictionary,
              let supported = capabilities[key] as? NSNumber else { return .unknown }
        guard supported.boolValue else { return .unsupportedDrive }
        guard (status[DRDeviceIsBusyKey] as? NSNumber)?.boolValue == false,
              let blank, freeBlocks(media) != nil else { return .unknown }
        if blank {
            if let used = media[DRDeviceMediaBlocksUsedKey] as? NSNumber, used.int64Value > 0 { return .unknown }
            return .blankCandidate
        }
        return appendable == true ? .appendCandidate : .unknown
    }

    func forDataAppend(type: String?, freeBlocks: UInt32?, snapshot: SessionSnapshot?, unsupportedFilesystem: Bool) -> Self {
        guard self == .appendCandidate else { return self }
        guard type == DRDeviceMediaTypeDVDPlusR, !unsupportedFilesystem else { return .unsupportedFormat }
        if let freeBlocks, !IncrementalISO.hasSpaceForSession(freeBlocks) { return .insufficientSpace }
        return snapshot?.appendState ?? .appendCandidate
    }
}
