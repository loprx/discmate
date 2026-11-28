#include "DeviceBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IODVDMediaBSDClient.h>
#include <IOKit/storage/IODVDTypes.h>
#include <libkern/OSByteOrder.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <stdbool.h>

#include <unistd.h>

static int read_sector(int fd, uint32_t sector, unsigned char *data) {
    ssize_t count = pread(fd, data, 2048, (off_t)sector * 2048);
    return count < 0 ? errno : count == 2048 ? 0 : EIO;
}

// Some finalized single-track DVDs retain an earlier volume at LBA 0.
// Their terminal UDF anchor uses a session-relative tag location, while
// the corresponding primary anchor uses its absolute physical location.
static bool valid_anchor(const unsigned char *data) {
    if (OSReadLittleInt16(data, 0) != 2 || OSReadLittleInt16(data, 10) != 496) return false;
    unsigned sum = 0;
    for (unsigned i = 0; i < 16; ++i) if (i != 4) sum += data[i];
    uint16_t crc = 0;
    for (unsigned i = 16; i < 512; ++i) {
        crc ^= (uint16_t)data[i] << 8;
        for (unsigned j = 0; j < 8; ++j)
            crc = (uint16_t)((crc << 1) ^ ((crc & 0x8000) ? 0x1021 : 0));
    }
    return (sum & 255) == data[4] && crc == OSReadLittleInt16(data, 8);
}

int dm_sealed_iso_start(int fd, const DMDisc *disc, const DMTrack *track, uint32_t *start) {
    *start = track->start;
    if (disc->status != 2 || disc->lastState != 3 || disc->sessions != 1 ||
        disc->lastTrack != 1 || track->start || track->blank || track->damaged || track->blocks <= 257) return 0;
    unsigned char sector[2048], tail[2048];
    int error = read_sector(fd, 16, sector);
    if (error || memcmp(sector + 1, "BEA01", 5)) return error;
    uint32_t last = track->blocks - 1;
    error = read_sector(fd, last, tail);
    if (error || !valid_anchor(tail)) return error;
    uint32_t relative = OSReadLittleInt32(tail, 12);
    if (relative <= 256 || relative >= last) return 0;
    uint32_t candidate = last - relative;
    error = read_sector(fd, candidate + 256, sector);
    if (error || !valid_anchor(sector) || OSReadLittleInt32(sector, 12) != candidate + 256 ||
        memcmp(sector + 16, tail + 16, 16)) return error;
    error = read_sector(fd, candidate + 16, sector);
    if (!error && !memcmp(sector, "\1CD001\1", 7)) *start = candidate;
    return error;
}

// This bridge has no write, erase, eject, or arbitrary ioctl entry point.
int dm_registry_identity(const char *path, uint64_t *identity) {
    io_registry_entry_t entry = IORegistryEntryFromPath(kIOMainPortDefault, path);
    if (!entry) return ENXIO;
    kern_return_t result = IORegistryEntryGetRegistryEntryID(entry, identity);
    IOObjectRelease(entry);
    return result == KERN_SUCCESS ? 0 : EIO;
}

// Inspect only the registry tree: no command, open or ioctl on the drive.
// Check any IOMedia descendant, not a cached BSD name: finishing a burn may
// create a new media identity without a physical tray opening.
int dm_registry_has_media(const char *path, int32_t *present) {
    io_registry_entry_t entry = IORegistryEntryFromPath(kIOMainPortDefault, path);
    if (!entry) return ENXIO;
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status = IORegistryEntryCreateIterator(entry, kIOServicePlane,
        kIORegistryIterateRecursively, &iterator);
    IOObjectRelease(entry);
    if (status != KERN_SUCCESS) return EIO;
    *present = 0;
    io_object_t child;
    while ((child = IOIteratorNext(iterator))) {
        if (IOObjectConformsTo(child, "IOMedia")) *present = 1;
        IOObjectRelease(child);
    }
    int result = IOIteratorIsValid(iterator) ? 0 : EAGAIN;
    IOObjectRelease(iterator);
    return result;
}

// Passive, bounded registry evidence for a known test drive. No USB/SCSI
// command is sent. Matching names are used only in memory; callers export
// counts, never serials, paths or registry IDs. Unknown models remain unknown.
int dm_registry_optical_probe(DMOpticalRegistryProbe *out) {
    if (!out) return EINVAL;
    *out = (DMOpticalRegistryProbe){0, 0, 0};
    io_iterator_t devices = IO_OBJECT_NULL;
    kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOUSBHostDevice"), &devices);
    if (status != KERN_SUCCESS) return EIO;
    int error = 0;
    io_object_t device;
    while ((device = IOIteratorNext(devices))) {
        CFTypeRef vendor = IORegistryEntryCreateCFProperty(device, CFSTR("USB Vendor Name"), kCFAllocatorDefault, 0);
        CFTypeRef product = IORegistryEntryCreateCFProperty(device, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
        bool known = vendor && product && CFGetTypeID(vendor) == CFStringGetTypeID() &&
            CFGetTypeID(product) == CFStringGetTypeID() && CFEqual(vendor, CFSTR("Lenovo")) &&
            CFEqual(product, CFSTR("Ultraslim DVD"));
        if (vendor) CFRelease(vendor);
        if (product) CFRelease(product);
        if (known) {
            if (out->lenovoUSBDevices < UINT32_MAX) ++out->lenovoUSBDevices;
            io_iterator_t children = IO_OBJECT_NULL;
            if (IORegistryEntryCreateIterator(device, kIOServicePlane,
                kIORegistryIterateRecursively, &children) != KERN_SUCCESS) error = EAGAIN;
            else {
                io_object_t child;
                while ((child = IOIteratorNext(children))) {
                    if (IOObjectConformsTo(child, "IOSCSIPeripheralDeviceType05") &&
                        out->opticalPeripherals < UINT32_MAX) ++out->opticalPeripherals;
                    if (IOObjectConformsTo(child, "IODVDMedia") && out->dvdMedia < UINT32_MAX) ++out->dvdMedia;
                    IOObjectRelease(child);
                }
                if (!IOIteratorIsValid(children)) error = EAGAIN;
                IOObjectRelease(children);
            }
        }
        IOObjectRelease(device);
    }
    if (!IOIteratorIsValid(devices)) error = EAGAIN;
    IOObjectRelease(devices);
    return error;
}

int dm_media(const char *bsd, DMMedia *out) {
    io_service_t media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd));
    if (!media) return ENXIO;
    int error = ENOTSUP;
    CFMutableDictionaryRef props = NULL;
    if (IOObjectConformsTo(media, "IODVDMedia") &&
        IORegistryEntryCreateCFProperties(media, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
        CFTypeRef type = CFDictionaryGetValue(props, CFSTR("Type"));
        CFTypeRef size = CFDictionaryGetValue(props, CFSTR("Size"));
        CFTypeRef block = CFDictionaryGetValue(props, CFSTR("Preferred Block Size"));
        int64_t bytes = 0; int32_t blockSize = 0; uint64_t identity = 0;
        if (type && CFEqual(type, CFSTR("DVD+R")) && size && block &&
            CFGetTypeID(size) == CFNumberGetTypeID() && CFGetTypeID(block) == CFNumberGetTypeID() &&
            CFNumberGetValue(size, kCFNumberSInt64Type, &bytes) &&
            CFNumberGetValue(block, kCFNumberSInt32Type, &blockSize) && bytes > 0 && blockSize == 2048 &&
            IORegistryEntryGetRegistryEntryID(media, &identity) == KERN_SUCCESS) {
            *out = (DMMedia){identity, (uint64_t)bytes, (uint32_t)blockSize}; error = 0;
        }
    }
    if (props) CFRelease(props);
    IOObjectRelease(media);
    return error;
}
// Recovery checks identity for any optical medium, without opening its BSD node.
// Partitions are ignored; ambiguous/partial registry trees fail closed.
int dm_registry_recovery_state(const char *path, uint64_t *driveID, uint64_t *mediaID, char *bsd, size_t capacity) {
    if (!capacity) return EINVAL;
    *driveID = 0; *mediaID = 0; bsd[0] = '\0';
    io_registry_entry_t drive = IORegistryEntryFromPath(kIOMainPortDefault, path);
    if (!drive) return ENXIO;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryEntryGetRegistryEntryID(drive, driveID) != KERN_SUCCESS ||
        IORegistryEntryCreateIterator(drive, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS) {
        IOObjectRelease(drive); return EIO;
    }
    IOObjectRelease(drive);
    io_object_t child; int wholeCount = 0, mediaCount = 0, error = 0;
    while ((child = IOIteratorNext(iterator))) {
        if (IOObjectConformsTo(child, "IOMedia")) {
            ++mediaCount;
            CFTypeRef whole = IORegistryEntryCreateCFProperty(child, CFSTR("Whole"), kCFAllocatorDefault, 0);
            if (!whole || CFGetTypeID(whole) != CFBooleanGetTypeID()) error = EAGAIN;
            else if (CFBooleanGetValue((CFBooleanRef)whole)) {
                ++wholeCount;
                CFTypeRef name = IORegistryEntryCreateCFProperty(child, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                if (!name || CFGetTypeID(name) != CFStringGetTypeID() ||
                    !CFStringGetCString((CFStringRef)name, bsd, capacity, kCFStringEncodingUTF8) ||
                    IORegistryEntryGetRegistryEntryID(child, mediaID) != KERN_SUCCESS) error = EAGAIN;
                if (name) CFRelease(name);
            }
            if (whole) CFRelease(whole);
        }
        IOObjectRelease(child);
    }
    if (!IOIteratorIsValid(iterator) || wholeCount > 1 || (mediaCount > 0 && wholeCount != 1)) error = EAGAIN;
    IOObjectRelease(iterator);
    uint64_t current = 0;
    if (dm_registry_identity(path, &current) || current != *driveID) error = EAGAIN;
    return error;
}
int dm_registry_media(const char *path, uint64_t driveID, char *bsd, size_t capacity, DMMedia *out) {
    io_registry_entry_t drive = IORegistryEntryFromPath(kIOMainPortDefault, path);
    if (!drive) return ENXIO;
    uint64_t current = 0;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryEntryGetRegistryEntryID(drive, &current) != KERN_SUCCESS || current != driveID ||
        IORegistryEntryCreateIterator(drive, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS) {
        IOObjectRelease(drive); return ENXIO;
    }
    IOObjectRelease(drive);
    io_object_t child; int found = 0; int error = ENOENT;
    while ((child = IOIteratorNext(iterator))) {
        if (IOObjectConformsTo(child, "IODVDMedia")) {
            ++found;
            CFTypeRef name = IORegistryEntryCreateCFProperty(child, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
            if (name && CFGetTypeID(name) == CFStringGetTypeID() &&
                CFStringGetCString(name, bsd, capacity, kCFStringEncodingUTF8)) {
                error = dm_media(bsd, out);
                uint64_t mediaID = 0;
                if (!error && (IORegistryEntryGetRegistryEntryID(child, &mediaID) != KERN_SUCCESS || mediaID != out->registryID)) error = EAGAIN;
            } else { error = EAGAIN; }
            if (name) CFRelease(name);
        }
        IOObjectRelease(child);
    }
    if (!IOIteratorIsValid(iterator)) error = EAGAIN;
    IOObjectRelease(iterator);
    if (found > 1) return ENOTSUP;
    return error;
}
int dm_disc(int fd, DMDisc *out) {
    DVDDiscInfo info = {0}; dk_dvd_read_disc_info_t req = {0};
    req.buffer = &info; req.bufferLength = sizeof(info);
    if (ioctl(fd, DKIOCDVDREADDISCINFO, &req)) return errno;
    if (req.bufferLength < 12) return EIO;
    *out = (DMDisc){info.discStatus, info.stateOfLastBorder,
        (info.numberOfBordersMSB << 8) | info.numberOfBordersLSB,
        (info.firstRZoneNumberInLastBorderMSB << 8) | info.firstRZoneNumberInLastBorderLSB,
        (info.lastRZoneNumberInLastBorderMSB << 8) | info.lastRZoneNumberInLastBorderLSB};
    return 0;
}
int dm_track(int fd, uint32_t number, DMTrack *out) {
    DVDRZoneInfo info = {0}; dk_dvd_read_rzone_info_t req = {0};
    req.address = number; req.addressType = kDVDRZoneInfoAddressTypeRZoneNumber;
    req.buffer = &info; req.bufferLength = sizeof(info);
    if (ioctl(fd, DKIOCDVDREADRZONEINFO, &req)) return errno;
    if (req.bufferLength < sizeof(info)) return EIO;
    *out = (DMTrack){(info.rzoneNumberMSB << 8) | info.rzoneNumberLSB,
        (info.borderNumberMSB << 8) | info.borderNumberLSB,
        OSSwapBigToHostInt32(info.rzoneStartAddress), OSSwapBigToHostInt32(info.rzoneSize),
        info.blank, info.damage, info.nextWritableAddressValid,
        OSSwapBigToHostInt32(info.nextWritableAddress), OSSwapBigToHostInt32(info.freeBlocks)};
    return 0;
}
static int dm_mount_matches_type(const char *path, const char *bsd, const char *filesystem) {
    struct statfs fs;
    if (statfs(path, &fs)) return errno;
    char expected[64];
    if (snprintf(expected, sizeof(expected), "/dev/%s", bsd) >= (int)sizeof(expected)) return EINVAL;
    return strcmp(fs.f_mntfromname, expected) || strcmp(fs.f_fstypename, filesystem) || !(fs.f_flags & MNT_RDONLY) ? EINVAL : 0;
}
// An explicit mount_cd9660 mount may survive a successful DA whole-unmount.
int dm_session_mount_for_eject(const char *bsd, char *path, size_t capacity) {
    char source[64];
    if (snprintf(source, sizeof(source), "/dev/%s", bsd) >= (int)sizeof(source)) return EINVAL;
    struct statfs *mounts = NULL;
    int count = getmntinfo_r_np(&mounts, MNT_NOWAIT);
    if (!count) return errno ? errno : EIO;
    int result = ENOENT;
    const char *prefix = "/Volumes/DiscMate-Session-";
    for (int i = 0; i < count; i++) {
        const struct statfs *m = &mounts[i];
        if (strcmp(source, m->f_mntfromname)) continue;
        if (result != ENOENT || strcmp(m->f_fstypename, "cd9660") ||
            !(m->f_flags & MNT_RDONLY) || strncmp(m->f_mntonname, prefix, strlen(prefix)) ||
            strchr(m->f_mntonname + strlen(prefix), '/')) { result = EBUSY; break; }
        result = strlcpy(path, m->f_mntonname, capacity) < capacity ? 0 : ENAMETOOLONG;
    }
    free(mounts);
    return result;
}

// cd9660 identifies a directory by the byte offset of its extent. Check
// the root inode as well as the device: different sessions can share names.
int dm_existing_iso_mount(const char *bsd, uint32_t rootLBA, char *path, size_t capacity) {
    char source[64];
    if (snprintf(source, sizeof(source), "/dev/%s", bsd) >= (int)sizeof(source)) return EINVAL;
    struct statfs *mounts = NULL;
    int count = getmntinfo_r_np(&mounts, MNT_NOWAIT);
    if (!count) return errno ? errno : EIO;
    int result = ENOENT;
    for (int i = 0; i < count; ++i) {
        const struct statfs *m = &mounts[i];
        if (strcmp(source, m->f_mntfromname)) continue;
        result = EBUSY;
        struct stat root;
        if (strcmp(m->f_fstypename, "cd9660") || !(m->f_flags & MNT_RDONLY)) continue;
        if (lstat(m->f_mntonname, &root)) { result = errno; break; }
        if (!S_ISDIR(root.st_mode) || root.st_ino != (uint64_t)rootLBA * 2048) continue;
        result = dm_mount_matches_type(m->f_mntonname, bsd, "cd9660");
        if (!result && strlcpy(path, m->f_mntonname, capacity) >= capacity) result = ENAMETOOLONG;
        break;
    }
    free(mounts);
    return result;
}
int dm_mount_matches(const char *path, const char *bsd) {
    return dm_mount_matches_type(path, bsd, "cd9660");
}
int dm_udf_mount_matches(const char *path, const char *bsd) {
    return dm_mount_matches_type(path, bsd, "udf");
}
