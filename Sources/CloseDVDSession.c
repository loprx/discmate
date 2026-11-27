#include "DeviceBridge.h"
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <IOKit/storage/IODVDTypes.h>
#include <libkern/OSByteOrder.h>
#include <stdbool.h>
#include <string.h>

// Private MMC transport shared by the two narrowly scoped DVD+R operations.
typedef IOReturn (*Transport)(void *, uint8_t [10], void *, size_t, DMCloseResult *);

static IOReturn execute(void *context, uint8_t cdb[10], void *buffer, size_t count, DMCloseResult *r) {
    SCSITaskDeviceInterface **device = context;
    r->opcode = cdb[0];
    r->serviceResponse = r->taskStatus = 0xff;
    memset(r->sense, 0, sizeof(r->sense));
    SCSITaskInterface **task = (*device)->CreateSCSITask(device);
    if (!task) return kIOReturnNoResources;
    SCSITaskSGElement range = {(uintptr_t)buffer, count};
    IOReturn rc = (*task)->SetCommandDescriptorBlock(task, cdb, cdb[0] == 0xbb ? 12 : 10);
    if (!rc && count) rc = (*task)->SetScatterGatherEntries(task, &range, 1, count, cdb[0] == 0x2a ? kSCSIDataTransfer_FromInitiatorToTarget : kSCSIDataTransfer_FromTargetToInitiator);
    if (!rc) rc = (*task)->SetTimeoutDuration(task, cdb[0] == 0x5b ? 180000 : 30000);
    if (!rc) {
        SCSI_Sense_Data sense = {0};
        SCSITaskStatus status = kSCSITaskStatus_No_Status;
        SCSIServiceResponse response = 0;
        UInt64 transferred = 0;
        if (cdb[0] == 0x5b || cdb[0] == 0x2a) r->attempted = 1;
        rc = (*task)->ExecuteTaskSync(task, &sense, &status, &transferred);
        IOReturn responseError = (*task)->GetSCSIServiceResponse(task, &response);
        r->taskStatus = status;
        if (!responseError) r->serviceResponse = response;
        memcpy(r->sense, &sense, sizeof(sense) < sizeof(r->sense) ? sizeof(sense) : sizeof(r->sense));
        if (!rc) rc = responseError;
        if (!rc && (status != kSCSITaskStatus_GOOD || response != kSCSIServiceResponse_TASK_COMPLETE ||
                    transferred != count)) rc = kIOReturnIOError;
    }
    (*task)->Release(task);
    return rc;
}

static uint16_t word(uint8_t high, uint8_t low) { return (uint16_t)((high << 8) | low); }

static IOReturn readDisc(Transport send, void *ctx, DVDDiscInfo *disc, DMCloseResult *r) {
    // Only the fixed 12-byte prefix is needed, including extended session/track numbers.
    uint8_t cdb[10] = {0x51,0,0,0,0,0,0,0,12,0};
    memset(disc, 0, sizeof(*disc));
    IOReturn rc = send(ctx, cdb, disc, 12, r);
    if (!rc && OSSwapBigToHostInt16(disc->dataLength) < 10) rc = kIOReturnUnderrun;
    return rc;
}

static IOReturn checkedClose(Transport send, void *ctx, uint16_t session, uint16_t track,
                             uint32_t start, uint32_t blocks, const uint8_t *descriptor, DMCloseResult *r) {
    if (!session || !track || track >= 64 || blocks <= 16 || start > UINT32_MAX - blocks)
        return kIOReturnBadArgument;
    uint8_t profile[8] = {0};
    uint8_t config[10] = {0x46,0,0,0,0,0,0,0,8,0};
    IOReturn rc = send(ctx, config, profile, sizeof(profile), r);
    if (rc) return rc;
    if (word(profile[6],profile[7]) != 0x001b) return kIOReturnUnsupported;
    DVDDiscInfo disc;
    rc = readDisc(send, ctx, &disc, r);
    if (rc) return rc;
    if (disc.discStatus != 1 || disc.stateOfLastBorder != 1 ||
        word(disc.numberOfBordersMSB, disc.numberOfBordersLSB) != session ||
        word(disc.firstRZoneNumberInLastBorderMSB, disc.firstRZoneNumberInLastBorderLSB) != track ||
        word(disc.lastRZoneNumberInLastBorderMSB, disc.lastRZoneNumberInLastBorderLSB) != track+1)
        return kIOReturnNotPermitted;

    for (uint16_t number = track; number <= track + 1; ++number) {
        DVDRZoneInfo zone = {0};
        uint8_t cdb[10] = {0x52,1,0,0,0,(uint8_t)number,0,0,sizeof(zone),0};
        rc = send(ctx, cdb, &zone, sizeof(zone), r);
        if (rc) return rc;
        if (OSSwapBigToHostInt16(zone.dataLength) < sizeof(zone)-2 ||
            word(zone.borderNumberMSB, zone.borderNumberLSB) != session ||
            word(zone.rzoneNumberMSB, zone.rzoneNumberLSB) != number || zone.blank || zone.damage)
            return kIOReturnNotPermitted;
        uint32_t zoneStart = OSSwapBigToHostInt32(zone.rzoneStartAddress);
        if (number == track) {
            if (zone.nextWritableAddressValid || zoneStart != start ||
                OSSwapBigToHostInt32(zone.rzoneSize) != blocks) return kIOReturnNotPermitted;
        } else if (!zone.nextWritableAddressValid || zoneStart < start + blocks ||
                   OSSwapBigToHostInt32(zone.nextWritableAddress) < zoneStart) return kIOReturnNotPermitted;
    }
    // Exclusive access can unpublish IOMedia. Recheck the physical disc via
    // the held client against the exact volume descriptor from the confirmed session.
    uint8_t sector[2048];
    uint8_t read[10] = {0x28,0,0,0,0,0,0,0,1,0};
    OSWriteBigInt32(read, 2, start + 16);
    rc = send(ctx, read, sector, sizeof(sector), r);
    if (rc) return rc;
    if (memcmp(sector, descriptor, sizeof(sector))) return kIOReturnNotAttached;
    uint8_t closeSession[10] = {0x5b,0,0x02,0,0,0,0,0,0,0};
    rc = send(ctx, closeSession, NULL, 0, r);
    if (rc) return rc;
    rc = readDisc(send, ctx, &disc, r);
    if (rc) return rc;
    uint16_t reported = word(disc.numberOfBordersMSB, disc.numberOfBordersLSB);
    if ((disc.discStatus == 1 || disc.discStatus == 2) && disc.stateOfLastBorder == 3 && reported == session) return 0;
    if (disc.discStatus == 1 && disc.stateOfLastBorder == 0 && reported == session + 1) return 0;
    return kIOReturnNotReady;
}

#include "ReservedTrack.inc"

static int32_t exclusiveSession(const char *path, uint64_t mediaID, uint16_t session, uint16_t track,
                            uint32_t start, uint32_t blocks, const uint8_t *descriptor, const DMReservation *reserved,
                            const uint8_t *image, size_t bytes, DMCloseResult *r) {
    *r = (DMCloseResult){.serviceResponse = 0xff, .taskStatus = 0xff};
    uint64_t driveID = 0;
    DMMedia media;
    char bsd[64];
    if (dm_registry_identity(path, &driveID) || dm_registry_media(path, driveID, bsd, sizeof(bsd), &media) ||
        media.registryID != mediaID) return kIOReturnNotAttached;
    // Walk from this exact medium to its authoring service, never pick the first drive on the bus.
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(mediaID));
    while (service && !IOObjectConformsTo(service, "IODVDServices")) {
        io_service_t parent = IO_OBJECT_NULL;
        IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent);
        IOObjectRelease(service);
        service = parent;
    }
    if (!service) return kIOReturnNoDevice;
    IOCFPlugInInterface **plugin = NULL;
    MMCDeviceInterface **mmc = NULL;
    SInt32 score = 0;
    IOReturn rc = IOCreatePlugInInterfaceForService(service, kIOMMCDeviceUserClientTypeID,
                                                     kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (rc || !plugin) return rc ? rc : kIOReturnUnsupported;
    HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOMMCDeviceInterfaceID), (LPVOID *)&mmc);
    if (query || !mmc) {
        IODestroyPlugInInterface(plugin);
        return query ? query : kIOReturnUnsupported;
    }
    SCSITaskDeviceInterface **device = (*mmc)->GetSCSITaskDeviceInterface(mmc);
    rc = kIOReturnNoDevice;
    if (device) {
        if (!dm_registry_media(path, driveID, bsd, sizeof(bsd), &media) && media.registryID == mediaID) {
            rc = (*device)->ObtainExclusiveAccess(device);
            if (!rc) {
                r->exclusive = 1;
                rc = reserved ? writeReservation(execute, device, *reserved, descriptor, image, bytes, r)
                              : checkedClose(execute, device, session, track, start, blocks, descriptor, r);
                r->releaseStatus = (*device)->ReleaseExclusiveAccess(device);
            }
        }
        (*device)->Release(device);
    }
    (*mmc)->Release(mmc);
    IODestroyPlugInInterface(plugin);
    r->ioStatus = rc;
    return rc ? rc : r->releaseStatus;
}

int32_t dm_close_dvd_session(const char *path, uint64_t mediaID, uint16_t session, uint16_t track,
                            uint32_t start, uint32_t blocks, const uint8_t *descriptor, DMCloseResult *r) {
    return exclusiveSession(path, mediaID, session, track, start, blocks, descriptor, NULL, NULL, 0, r);
}

int32_t dm_resume_reserved(const char *path, uint64_t mediaID, DMReservation target, const uint8_t *descriptor,
                          const uint8_t *image, size_t bytes, DMCloseResult *r) {
    return exclusiveSession(path, mediaID, 0, 0, 0, 0, descriptor, &target, image, bytes, r);
}
