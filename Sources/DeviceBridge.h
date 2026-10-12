#include <stdint.h>
#include <stddef.h>
typedef struct { uint64_t registryID, bytes; uint32_t blockSize; } DMMedia;
typedef struct { uint32_t status, lastState, sessions, firstTrack, lastTrack; } DMDisc;
typedef struct { uint32_t number, session, start, blocks, blank, damaged, nwaValid, nwa, freeBlocks; } DMTrack;
int dm_media(const char *bsd, DMMedia *result);
int dm_disc(int fd, DMDisc *result);
int dm_track(int fd, uint32_t number, DMTrack *result);
int dm_mount_matches(const char *path, const char *bsd);
int dm_registry_identity(const char *path, uint64_t *identity);
int dm_registry_has_media(const char *path, int32_t *present);
int dm_registry_media(const char *path, uint64_t driveID, char *bsd, size_t capacity, DMMedia *result);
void *dm_authorize_mount(const char *helper, int32_t *status);
void dm_release_authorization(void *authorization);
int32_t dm_authorized_mount(void *authorization, const char *helper, const char *bsd, const char *identity, const char *start, char *output, size_t capacity);
