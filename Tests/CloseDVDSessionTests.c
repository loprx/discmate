// The production sequence is exercised with an in-memory transport only.
#include "../Sources/CloseDVDSession.c"
#include <assert.h>
#include <stdio.h>

enum Scenario { closed, nextEmpty, wrongProfile, alreadyClosed, wrongTrack, damage, changedDisc,
                transportFailure, stillOpen, unexpectedSession };
struct Fixture { enum Scenario scenario; int closes; };
static IOReturn simulate(void *ctx, uint8_t cdb[10], void *out, size_t length, DMCloseResult *result) {
    struct Fixture *f = ctx;
    switch (cdb[0]) {
    case 0x46:
        assert(length == 8);
        ((uint8_t *)out)[7] = f->scenario == wrongProfile ? 0x11 : 0x1b;
        break;
    case 0x51: {
        assert(length == 12);
        DVDDiscInfo *disc = out;
        disc->dataLength = OSSwapHostToBigInt16(32);
        disc->discStatus = 1;
        disc->stateOfLastBorder = f->closes || f->scenario == alreadyClosed ? 3 : 1;
        disc->numberOfBordersLSB = 2;
        disc->firstRZoneNumberInLastBorderLSB = 2;
        disc->lastRZoneNumberInLastBorderLSB = 3;
        if (f->closes && f->scenario == nextEmpty) {
            disc->stateOfLastBorder = 0;
            disc->numberOfBordersLSB = 3;
        }
        if (f->closes && f->scenario == stillOpen) disc->stateOfLastBorder = 1;
        if (f->closes && f->scenario == unexpectedSession) disc->numberOfBordersLSB = 8;
        break;
    }
    case 0x52: {
        assert(length == sizeof(DVDRZoneInfo) && cdb[1] == 1 && (cdb[5] == 2 || cdb[5] == 3));
        DVDRZoneInfo *zone = out;
        zone->dataLength = OSSwapHostToBigInt16(sizeof(*zone)-2);
        zone->borderNumberLSB = 2;
        zone->rzoneNumberLSB = f->scenario == wrongTrack ? 4 : cdb[5];
        zone->damage = f->scenario == damage;
        zone->nextWritableAddressValid = cdb[5] == 3;
        zone->rzoneSize = OSSwapHostToBigInt32(32);
        zone->rzoneStartAddress = OSSwapHostToBigInt32(cdb[5] == 2 ? 100 : 140);
        zone->nextWritableAddress = OSSwapHostToBigInt32(145);
        break;
    }
    case 0x28:
        assert(length == 2048 && OSReadBigInt32(cdb, 2) == 116 && cdb[8] == 1);
        memset(out, f->scenario == changedDisc ? 1 : 42, length);
        break;
    case 0x5b: {
        const uint8_t sessionOnly[10] = {0x5b,0,2,0,0,0,0,0,0,0};
        assert(!memcmp(cdb, sessionOnly, 10) && !out && !length);
        assert(++f->closes == 1);
        result->attempted = 1;
        if (f->scenario == transportFailure) return kIOReturnTimeout;
        break;
    }
    default: assert(false);
    }
    return 0;
}
int main(void) {
    uint8_t descriptor[2048];
    memset(descriptor, 42, sizeof(descriptor));
    for (enum Scenario s = closed; s <= unexpectedSession; ++s) {
        struct Fixture f = {.scenario = s};
        DMCloseResult result = {0};
        IOReturn rc = checkedClose(simulate, &f, 2, 2, 100, 32, descriptor, &result);
        assert((rc == 0) == (s == closed || s == nextEmpty));
        assert(f.closes == (s <= nextEmpty || s >= transportFailure));
    }
    puts("PASS DVD+R single-session close: exact CDB, media and track checks, timeout, postcondition, no retry");
}
