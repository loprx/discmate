#include "../Sources/DeviceBridge.h"
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static int decimal(const char *text, uint64_t *value) {
    if (!text || !*text) return EINVAL;
    for (const char *p = text; *p; ++p) if (!isdigit((unsigned char)*p)) return EINVAL;
    char *end; errno = 0; *value = strtoull(text, &end, 10);
    return errno || *end ? EINVAL : 0;
}
static int inputs(int argc, char **argv, uint64_t *identity, uint64_t *start) {
    if (argc != 4 || strncmp(argv[1], "disk", 4) || strlen(argv[1]) > 24) return EINVAL;
    uint64_t index;
    if (decimal(argv[1] + 4, &index) || decimal(argv[2], identity) || decimal(argv[3], start)) return EINVAL;
    return !*identity || *start > INT32_MAX ? EINVAL : 0;
}
static int perform(const char *bsd, uint64_t identity, uint32_t expectedStart, char *mountpoint, size_t capacity) {
    DMMedia media = {0}; DMDisc disc = {0}; DMTrack latest = {0};
    int error = dm_media(bsd, &media);
    if (error) return error;
    if (media.registryID != identity) return ESTALE;
    char device[64], raw[64];
    snprintf(device, sizeof(device), "/dev/%s", bsd);
    snprintf(raw, sizeof(raw), "/dev/r%s", bsd);
    int fd = open(raw, O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
    if (fd < 0) return errno;
    error = dm_disc(fd, &disc);
    if (error) goto close_device;
    if (!disc.status || !disc.lastTrack || disc.lastTrack > 64 || (disc.lastState != 0 && disc.lastState != 3)) { error = EINVAL; goto close_device; }
    for (uint32_t n = 1; n <= disc.lastTrack; ++n) {
        DMTrack track = {0}; error = dm_track(fd, n, &track);
        if (error) goto close_device;
        if (track.number != n || (uint64_t)track.start + track.blocks > media.bytes / 2048) { error = EINVAL; goto close_device; }
        if (!track.blank && !(disc.lastState == 0 && track.session == disc.sessions)) latest = track;
    }
    if (!latest.number || latest.damaged || latest.start != expectedStart || latest.blocks <= 16) { error = ESTALE; goto close_device; }
    unsigned char pvd[2048];
    if (pread(fd, pvd, sizeof(pvd), ((off_t)latest.start + 16) * 2048) != sizeof(pvd)) { error = EIO; goto close_device; }
    if (memcmp(pvd, "\1CD001\1", 7) || memcmp(pvd + 128, "\0\10\10\0", 4)) { error = EINVAL; goto close_device; }
close_device:
    close(fd);
    if (error) return error;
    // Mountpoint is generated here, beneath the root-owned /Volumes directory.
    // The caller cannot supply a destination path or mount flags.
    struct stat directory;
    if (lstat("/Volumes", &directory) || !S_ISDIR(directory.st_mode) || directory.st_uid != 0 || (directory.st_mode & S_IWOTH)) return EPERM;
    if (snprintf(mountpoint, capacity, "/Volumes/DiscMate-Session-%u-%08x", latest.session, arc4random()) >= (int)capacity) return EINVAL;
    if (mkdir(mountpoint, 0755)) return errno;
    DMMedia current = {0};
    error = dm_media(bsd, &current);
    if (error || current.registryID != identity) { rmdir(mountpoint); return error ? error : ESTALE; }
    char sector[16]; snprintf(sector, sizeof(sector), "%u", latest.start);
    pid_t child = fork();
    if (child < 0) { error = errno; rmdir(mountpoint); return error; }
    if (!child) {
        dup2(STDOUT_FILENO, STDERR_FILENO);
        char *args[] = {"mount_cd9660", "-o", "rdonly,nosuid,nodev", "-s", sector, device, mountpoint, NULL};
        execv("/sbin/mount_cd9660", args);
        _exit(127);
    }
    int status;
    while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return errno; }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) { rmdir(mountpoint); return EIO; }
    return dm_mount_matches(mountpoint, bsd);
}
int main(int argc, char **argv) {
    uint64_t identity = 0, start = 0;
    int error = inputs(argc, argv, &identity, &start);
    if (!error && geteuid() != 0) error = EPERM;
    char mountpoint[128] = {0};
    if (!error) error = perform(argv[1], identity, (uint32_t)start, mountpoint, sizeof(mountpoint));
    if (error) { printf("ERROR\t%d\t%s\n", error, strerror(error)); return 1; }
    printf("OK\t%s\n", mountpoint);
    return 0;
}
