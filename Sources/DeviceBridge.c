#include "DeviceBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IODVDMediaBSDClient.h>
#include <IOKit/storage/IODVDTypes.h>
#include <libkern/OSByteOrder.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

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
int dm_mount_matches(const char *path, const char *bsd) {
    struct statfs fs;
    if (statfs(path, &fs)) return errno;
    char expected[64];
    if (snprintf(expected, sizeof(expected), "/dev/%s", bsd) >= (int)sizeof(expected)) return EINVAL;
    return strcmp(fs.f_mntfromname, expected) || strcmp(fs.f_fstypename, "cd9660") || !(fs.f_flags & MNT_RDONLY) ? EINVAL : 0;
}
