import DiscRecording
import Foundation

enum DiscWriteStateTests {
    static func run() throws {
        func state(_ type: String = DRDeviceMediaTypeDVDPlusR, blank: Bool? = false, append: Bool? = true,
                   free: NSNumber? = 100_000, used: Int? = nil, supports: Bool? = true,
                   busy: Bool = false, presence: String = DRDeviceMediaStateMediaPresent) -> DiscWriteState {
            var media: [String: Any] = [DRDeviceMediaTypeKey: type]
            media[DRDeviceMediaIsBlankKey] = blank
            media[DRDeviceMediaIsAppendableKey] = append
            media[DRDeviceMediaBlocksFreeKey] = free
            media[DRDeviceMediaBlocksUsedKey] = used
            var caps = [String: Bool]()
            caps[DRDeviceCanWriteDVDPlusRKey] = supports
            return .classify(status: [DRDeviceMediaInfoKey: media, DRDeviceMediaStateKey: presence,
                                      DRDeviceIsBusyKey: busy], driveInfo: [DRDeviceWriteCapabilitiesKey: caps])
        }
        precondition(state() == .appendCandidate && state(blank: true, append: false) == .blankCandidate)
        precondition(state(free: 0) == .full && state(append: false) == .notAppendable)
        precondition(state(DRDeviceMediaTypeDVDROM, blank: true) == .readOnly)
        precondition(state(supports: false) == .unsupportedDrive && state(supports: nil) == .unknown)
        precondition(state(blank: true, used: 50) == .unknown && state(blank: nil) == .unknown)
        precondition(state(free: nil) == .unknown && state(free: -1) == .unknown && state(append: nil) == .unknown)
        precondition(state(busy: true) == .busy && state(presence: DRDeviceMediaStateInTransition) == .unknown)
        precondition(state(presence: DRDeviceMediaStateNone) == .noDisc)
        let candidate = state()
        precondition(candidate.forDataAppend(type: DRDeviceMediaTypeDVDPlusR, freeBlocks: 100_000,
            snapshot: nil, unsupportedFilesystem: false) == .appendCandidate)
        precondition(candidate.forDataAppend(type: DRDeviceMediaTypeDVDPlusR, freeBlocks: 100_000,
            snapshot: nil, unsupportedFilesystem: true) == .unsupportedFormat)
        precondition(candidate.forDataAppend(type: DRDeviceMediaTypeDVDPlusRDoubleLayer, freeBlocks: 100_000,
            snapshot: nil, unsupportedFilesystem: false) == .unsupportedFormat)
        let track = RecordedTrack(number: 1, session: 1, start: 0, blocks: 1000, blank: false,
            damaged: false, nextWritable: nil, freeBlocks: 0)
        func scanned(_ free: UInt32 = 30_000, nwa: UInt32? = 1000, open: Bool = true,
                     incomplete: Bool = false, damaged: Bool = false) -> DiscWriteState {
            let next = RecordedTrack(number: 2, session: 2, start: 1000, blocks: 30_000, blank: true,
                damaged: damaged, nextWritable: nwa, freeBlocks: free)
            let root = ISOEntry(name: "", lba: 20, bytes: 2048, directory: true)
            let snapshot = SessionSnapshot(identity: MediaIdentity(bsd: "fixture", registryID: 1, bytes: 31_000 * 2048),
                tracks: [track, next], latest: track, volume: ISOVolume(root: root, joliet: true), rootEntries: [],
                descriptorHash: "", appendable: open, incompleteSession: incomplete)
            return candidate.forDataAppend(type: DRDeviceMediaTypeDVDPlusR, freeBlocks: 30_000,
                snapshot: snapshot, unsupportedFilesystem: false)
        }
        precondition(scanned() == .appendReady && scanned(open: false) == .notAppendable)
        precondition(scanned(incomplete: true) == .incompleteSession && scanned(0) == .full)
        precondition(scanned(nwa: nil) == .noWritableTrack && scanned(damaged: true) == .noWritableTrack)
        precondition(scanned(nwa: 500) == .noWritableTrack && scanned(nwa: 2000) == .noWritableTrack)
        precondition(scanned(16_385) == .insufficientSpace)
        print("PASS disc write states: ROM, closed, full, unknown, drive capability, session state, NWA and space")
    }
}
