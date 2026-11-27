// Scripted, in-memory MMC drive. No device is opened.
#include "../Sources/CloseDVDSession.c"
#include <assert.h>
#include <stdio.h>

struct Model {
    DMReservation target;
    uint8_t descriptor[2048], image[34816];
    unsigned writes, trackCloses, sessionCloses;
    bool flushed, wrongProfile, wrongTrack, changed, timeout, stillOpen, speedRejected;
};

static IOReturn drive(void *ctx, uint8_t cdb[10], void *buffer, size_t size, DMCloseResult *r) {
    struct Model *m = ctx;
    DMReservation t = m->target;
    switch (cdb[0]) {
    case 0x46: ((uint8_t *)buffer)[7] = m->wrongProfile ? 0x2b : 0x1b; return 0;
    case 0x51: {
        DVDDiscInfo *d = buffer;
        bool finished = m->sessionCloses && !m->stillOpen;
        d->dataLength = OSSwapHostToBigInt16(32);
        d->discStatus = 1; d->stateOfLastBorder = finished ? 0 : 1;
        d->numberOfBordersLSB = t.session + finished;
        d->firstRZoneNumberInLastBorderLSB = t.track;
        d->lastRZoneNumberInLastBorderLSB = t.track + 1;
        return 0;
    }
    case 0x52: {
        DVDRZoneInfo *z = buffer;
        unsigned n = cdb[5];
        assert(n >= t.previousTrack && n <= (unsigned)t.track + 1);
        bool prev = n == t.previousTrack, last = n == (unsigned)t.track+1;
        uint32_t start = prev ? t.previousStart : last ? t.start+t.blocks+16 : t.start;
        uint32_t blocks = prev ? t.previousBlocks : last ? t.tailBlocks : t.blocks;
        z->dataLength = OSSwapHostToBigInt16(sizeof(*z)-2);
        z->borderNumberLSB = prev ? t.session-1 : t.session;
        z->rzoneNumberLSB = n;
        z->rzoneStartAddress = OSSwapHostToBigInt32(start);
        z->rzoneSize = OSSwapHostToBigInt32(blocks);
        z->blank = last || (!prev && m->writes == 0);
        z->nextWritableAddressValid = !prev && !m->trackCloses;
        z->nextWritableAddress = OSSwapHostToBigInt32(start + (last || prev ? 0 : m->writes * 16));
        z->freeBlocks = OSSwapHostToBigInt32(blocks);
        z->damage = m->wrongTrack && last;
        return 0;
    }
    case 0x28:
        assert(size == 2048 && OSReadBigInt32(cdb,2) == t.previousStart + 16);
        memcpy(buffer,m->descriptor,size);
        if (m->changed) ((uint8_t*)buffer)[50]++;
        return 0;
    case 0xbb:
        assert(word(cdb[4],cdb[5]) == t.speedKBps);
        return m->speedRejected ? kIOReturnUnsupported : 0;
    case 0x2a: {
        size_t offset = m->writes * 32768;
        assert(size == 32768 && cdb[8] == 16 && OSReadBigInt32(cdb,2) == t.start + m->writes * 16);
        assert(offset < sizeof(m->image));
        for (size_t i=0; i<size; ++i)
            assert(((uint8_t*)buffer)[i] == (offset+i < sizeof(m->image) ? m->image[offset+i] : 0));
        ++m->writes; r->attempted = 1;
        return m->timeout ? kIOReturnTimeout : 0;
    }
    case 0x35: assert(m->writes == 2); m->flushed = true; return 0;
    case 0x5b:
        assert(m->flushed && !cdb[1]);
        if (cdb[2] == 1) { assert(cdb[5] == t.track && !m->trackCloses); ++m->trackCloses; }
        else { assert(cdb[2] == 2 && !cdb[5] && m->trackCloses == 1 && !m->sessionCloses); ++m->sessionCloses; }
        return 0;
    default: assert(false);
    }
}
int main(void) {
    for (int scenario=0; scenario<8; ++scenario) {
        struct Model m = {.target = {3,3,2,5540,163312,60208,2071568,160800,464},
            .wrongProfile = scenario==1, .wrongTrack = scenario==2, .changed = scenario==3,
            .timeout = scenario==4, .stillOpen = scenario==5, .speedRejected = scenario==7};
        memset(m.image, 0x62, sizeof(m.image));
        DMCloseResult r = {0};
        size_t size = scenario==6 ? ((size_t)m.target.blocks+1)*2048 : sizeof(m.image);
        IOReturn rc = writeReservation(drive,&m,m.target,m.descriptor,m.image,size,&r);
        assert((rc == 0) == (scenario == 0));
        assert(m.writes == (scenario==0 || scenario==5 ? 2U : scenario==4 ? 1U : 0U));
    }
    puts("PASS reserved DVD+R layout, data and padding, speed rejection, stale target, capacity, no write retry, verified close");
}
