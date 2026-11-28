#include "../Sources/DeviceBridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void put(int fd, uint32_t at, unsigned char *sector) {
    assert(pwrite(fd, sector, 2048, (off_t)at * 2048) == 2048);
}

static void anchor(int fd, uint32_t at, uint32_t location) {
    unsigned char data[2048] = {2, 0, 2};
    data[10] = 0xf0;
    data[11] = 1;
    memcpy(data + 12, &location, sizeof(location));
    for (int i = 0; i < 16; ++i) if (i != 4) data[4] += data[i];
    put(fd, at, data);
}

int main(void) {
    FILE *image = tmpfile();
    assert(image);
    int fd = fileno(image);
    unsigned char udf[2048] = {0}, iso[2048] = {0};
    memcpy(udf + 1, "BEA01", 5);
    memcpy(iso, "\1CD001\1", 7);
    put(fd, 16, udf);
    put(fd, 616, iso);
    anchor(fd, 856, 856);
    anchor(fd, 999, 399);
    DMDisc disc = {.status=2, .lastState=3, .sessions=1, .lastTrack=1};
    DMTrack track = {.blocks=1000};
    uint32_t start;
    assert(!dm_sealed_iso_start(fd, &disc, &track, &start) && start == 600);
    disc.status = 1;
    assert(!dm_sealed_iso_start(fd, &disc, &track, &start) && !start);
    disc.status = 2;
    anchor(fd, 856, 256);
    assert(!dm_sealed_iso_start(fd, &disc, &track, &start) && !start);
    anchor(fd, 856, 856);
    assert(pwrite(fd, "x", 1, 999 * 2048 + 20) == 1);
    assert(!dm_sealed_iso_start(fd, &disc, &track, &start) && !start);
    fclose(image);
    puts("PASS sealed directory selection and invalid anchors");
}
