// Internal to the DVD+R transport. Only called after acquiring the original drive.
static IOReturn zoneAt(Transport send, void *ctx, uint16_t number, DVDRZoneInfo *zone, DMCloseResult *r) {
    memset(zone, 0, sizeof(*zone));
    uint8_t cdb[10] = {0x52,1,0,0,(uint8_t)(number >> 8),(uint8_t)number,0,0,sizeof(*zone),0};
    IOReturn rc = send(ctx, cdb, zone, sizeof(*zone), r);
    if (rc) return rc;
    return OSSwapBigToHostInt16(zone->dataLength) >= sizeof(*zone)-2 &&
           word(zone->rzoneNumberMSB, zone->rzoneNumberLSB) == number ? 0 : kIOReturnUnderrun;
}

static bool matchesZone(DVDRZoneInfo z, uint16_t session, uint32_t start, uint32_t blocks, bool blank) {
    return word(z.borderNumberMSB, z.borderNumberLSB) == session && !z.damage &&
        z.blank == blank && z.nextWritableAddressValid == blank &&
        OSSwapBigToHostInt32(z.rzoneStartAddress) == start && OSSwapBigToHostInt32(z.rzoneSize) == blocks &&
        (!blank || (OSSwapBigToHostInt32(z.nextWritableAddress) == start && OSSwapBigToHostInt32(z.freeBlocks) == blocks));
}

static IOReturn writeReservation(Transport send, void *ctx, DMReservation t, const uint8_t *descriptor,
                                 const uint8_t *image, size_t bytes, DMCloseResult *r) {
    uint64_t tailStart = (uint64_t)t.start + t.blocks + 16;
    if (!image || !descriptor || !bytes || bytes >= UINT32_MAX || bytes % 2048 ||
        t.session < 2 || !t.previousTrack || t.track != t.previousTrack + 1 || t.track >= 64 ||
        !t.blocks || !t.tailBlocks || t.blocks % 16 || t.start % 16 || t.previousBlocks <= 16 ||
        (uint64_t)t.previousStart + t.previousBlocks > t.start ||
        tailStart + t.tailBlocks > UINT32_MAX || (bytes+32767)/32768*16 > t.blocks || !t.speedKBps)
        return kIOReturnBadArgument;
    uint8_t profile[8] = {0}, config[10] = {0x46,0,0,0,0,0,0,0,8,0};
    IOReturn rc = send(ctx, config, profile, sizeof(profile), r);
    if (rc) return rc;
    if (word(profile[6], profile[7]) != 0x1b) return kIOReturnUnsupported;
    DVDDiscInfo d;
    rc = readDisc(send, ctx, &d, r);
    if (rc) return rc;
    if (d.discStatus != 1 || d.stateOfLastBorder != 1 || word(d.numberOfBordersMSB,d.numberOfBordersLSB) != t.session ||
        word(d.firstRZoneNumberInLastBorderMSB,d.firstRZoneNumberInLastBorderLSB) != t.track ||
        word(d.lastRZoneNumberInLastBorderMSB,d.lastRZoneNumberInLastBorderLSB) != t.track + 1)
        return kIOReturnNotPermitted;
    DVDRZoneInfo z;
    rc = zoneAt(send, ctx, t.previousTrack, &z, r);
    if (rc) return rc;
    if (!matchesZone(z,t.session-1,t.previousStart,t.previousBlocks,false)) return kIOReturnNotPermitted;
    rc = zoneAt(send, ctx, t.track, &z, r);
    if (rc) return rc;
    if (!matchesZone(z,t.session,t.start,t.blocks,true)) return kIOReturnNotPermitted;
    rc = zoneAt(send, ctx, t.track + 1, &z, r);
    if (rc) return rc;
    if (!matchesZone(z,t.session,(uint32_t)tailStart,t.tailBlocks,true)) return kIOReturnNotPermitted;

    uint8_t sector[2048], read[10] = {0x28,0,0,0,0,0,0,0,1,0};
    OSWriteBigInt32(read, 2, t.previousStart + 16);
    rc = send(ctx, read, sector, sizeof(sector), r);
    if (rc) return rc;
    if (memcmp(sector, descriptor, sizeof(sector))) return kIOReturnNotAttached;
    uint8_t speed[12] = {0xbb,0,0xff,0xff,(uint8_t)(t.speedKBps >> 8),(uint8_t)t.speedKBps};
    rc = send(ctx, speed, NULL, 0, r);
    if (rc) return rc;
    // Write only the ECC-aligned image. CLOSE TRACK pads the reserved remainder.
    uint8_t block[32768];
    for (size_t offset = 0; offset < bytes; offset += sizeof(block)) {
        size_t n = bytes-offset < sizeof(block) ? bytes-offset : sizeof(block);
        memcpy(block, image + offset, n);
        memset(block+n, 0, sizeof(block)-n);
        uint8_t write[10] = {0x2a,0,0,0,0,0,0,0,16,0};
        OSWriteBigInt32(write, 2, t.start + (uint32_t)(offset / 2048));
        rc = send(ctx, write, block, sizeof(block), r);
        if (rc) return rc;
    }
    uint8_t flush[10] = {0x35};
    rc = send(ctx, flush, NULL, 0, r);
    if (rc) return rc;
    rc = zoneAt(send,ctx,t.track,&z,r);
    if (rc) return rc;
    if (z.blank || z.damage || word(z.borderNumberMSB,z.borderNumberLSB) != t.session ||
        OSSwapBigToHostInt32(z.rzoneStartAddress) != t.start) return kIOReturnIOError;
    if (z.nextWritableAddressValid) {
        if (OSSwapBigToHostInt32(z.nextWritableAddress) != t.start + (bytes+32767)/32768*16)
            return kIOReturnNotReady;
        uint8_t closeTrack[10] = {0x5b,0,1,0,(uint8_t)(t.track>>8),(uint8_t)t.track};
        rc = send(ctx,closeTrack,NULL,0,r);
        if (rc) return rc;
    }
    rc = zoneAt(send,ctx,t.track,&z,r);
    if (rc) return rc;
    if (!matchesZone(z,t.session,t.start,t.blocks,false)) return kIOReturnNotReady;
    uint8_t closeSession[10] = {0x5b,0,2};
    rc = send(ctx,closeSession,NULL,0,r);
    if (rc) return rc;
    rc = readDisc(send,ctx,&d,r);
    if (rc) return rc;
    uint16_t sessions = word(d.numberOfBordersMSB,d.numberOfBordersLSB);
    if (d.discStatus == 1 && d.stateOfLastBorder == 0 && sessions == t.session+1) return 0;
    if ((d.discStatus == 1 || d.discStatus == 2) && d.stateOfLastBorder == 3 && sessions == t.session) return 0;
    return kIOReturnNotReady;
}
