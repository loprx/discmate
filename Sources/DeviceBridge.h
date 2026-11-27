#include <stdint.h>
#include <stddef.h>
#ifdef __OBJC__
#import "SystemBurnPanels.h"
#endif
typedef struct { uint64_t registryID, bytes; uint32_t blockSize; } DMMedia;
typedef struct { uint32_t status, lastState, sessions, firstTrack, lastTrack; } DMDisc;
typedef struct { uint32_t number, session, start, blocks, blank, damaged, nwaValid, nwa, freeBlocks; } DMTrack;
typedef struct { uint32_t lenovoUSBDevices, opticalPeripherals, dvdMedia; } DMOpticalRegistryProbe;
int dm_media(const char *bsd, DMMedia *result);
int dm_disc(int fd, DMDisc *result);
int dm_track(int fd, uint32_t number, DMTrack *result);
int dm_mount_matches(const char *path, const char *bsd);
int dm_udf_mount_matches(const char *path, const char *bsd);
int dm_registry_identity(const char *path, uint64_t *identity);
int dm_registry_has_media(const char *path, int32_t *present);
int dm_registry_media(const char *path, uint64_t driveID, char *bsd, size_t capacity, DMMedia *result);
int dm_registry_recovery_state(const char *path, uint64_t *driveID, uint64_t *mediaID, char *bsd, size_t capacity);
int dm_registry_optical_probe(DMOpticalRegistryProbe *result);
void *dm_authorize_mount(const char *helper, int32_t *status);
void dm_release_authorization(void *authorization);
int32_t dm_authorized_mount(void *authorization, const char *helper, const char *bsd, const char *identity, const char *start, char *output, size_t capacity);

// Dedicated DVD+R recovery operation. No caller-supplied CDB or close mode.
typedef struct {
    int32_t ioStatus, releaseStatus;
    uint8_t opcode, serviceResponse, taskStatus, attempted, exclusive;
    uint8_t sense[32];
} DMCloseResult;
int32_t dm_close_dvd_session(const char *drivePath, uint64_t mediaID, uint16_t session,
    uint16_t track, uint32_t start, uint32_t blocks, const uint8_t *descriptor, DMCloseResult *result);

// Values are bound to the scanned previous data track and the two open fragments.
typedef struct {
    uint16_t session, track, previousTrack, speedKBps;
    uint32_t start, blocks, tailBlocks, previousStart, previousBlocks;
} DMReservation;
int32_t dm_resume_reserved(const char *path, uint64_t mediaID, DMReservation target,
    const uint8_t *previousDescriptor, const uint8_t *image, size_t bytes, DMCloseResult *result);
