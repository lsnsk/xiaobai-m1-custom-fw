/*
 * eye_snap.c - live snapshot for Xiaobai M1 (shbf /run/video_rawstream/control)
 *
 * Hardware-verified on 4.3.5_3319: REQ_SNAPSHOT_A returns an uncompressed 8-bit luma frame,
 * 640x360 (data_sz = 64-byte sub-header + 230400 bytes). If a JPEG is ever delivered instead
 * it is written through unchanged.
 *
 * Usage: eye_snap <out.jpg> [rotate=0|90|180|270] [timeout_ms=4000] [REQ_SNAPSHOT_A|REQ_SNAPSHOT_R]
 * Set EYE_SNAP_DEBUG=1 for stage tracing on stderr.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/uio.h>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define RAW_W 640
#define RAW_H 360

static int g_dbg;
#define DBG(...) do { if (g_dbg) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static int send_request(int fd, const char *cmd) {
    uint32_t type = 0;
    struct iovec iov[2] = {{&type, sizeof type}, {(void *)cmd, strlen(cmd) + 1}};
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = iov;
    m.msg_iovlen = 2;
    return sendmsg(fd, &m, MSG_NOSIGNAL) >= 0 ? 0 : -1;
}

typedef struct { uint8_t *p; size_t n, cap; int err; } sink_t;

static void sink_write(void *ctx, void *data, int size) {
    sink_t *s = (sink_t *)ctx;
    if (s->err || size <= 0) return;
    if (s->n + (size_t)size > s->cap) {
        size_t nc = s->cap ? s->cap * 2 : 65536;
        while (nc < s->n + (size_t)size) nc *= 2;
        uint8_t *np = (uint8_t *)realloc(s->p, nc);
        if (!np) { s->err = 1; return; }
        s->p = np;
        s->cap = nc;
    }
    memcpy(s->p + s->n, data, (size_t)size);
    s->n += (size_t)size;
}

static int write_bytes(const uint8_t *b, size_t n, const char *out);

static int write_gray_jpeg(const uint8_t *y, const char *out, int deg) {
    int w = RAW_W, h = RAW_H, ow = w, oh = h;
    uint8_t *dst = (uint8_t *)malloc((size_t)w * h);
    if (!dst) return -1;
    switch (deg) {
    case 90:
        ow = h; oh = w;
        for (int j = 0; j < h; j++)
            for (int i = 0; i < w; i++) dst[(size_t)i * ow + (h - 1 - j)] = y[(size_t)j * w + i];
        break;
    case 270:
        ow = h; oh = w;
        for (int j = 0; j < h; j++)
            for (int i = 0; i < w; i++) dst[(size_t)(w - 1 - i) * ow + j] = y[(size_t)j * w + i];
        break;
    case 180:
        for (size_t k = 0; k < (size_t)w * h; k++) dst[(size_t)w * h - 1 - k] = y[k];
        break;
    default:
        memcpy(dst, y, (size_t)w * h);
    }
    DBG("rotated %dx%d\n", ow, oh);
    uint8_t *rgb = (uint8_t *)malloc((size_t)ow * oh * 3);
    if (!rgb) { free(dst); return -1; }
    for (size_t k = 0; k < (size_t)ow * oh; k++) rgb[k * 3] = rgb[k * 3 + 1] = rgb[k * 3 + 2] = dst[k];
    free(dst);
    sink_t sk = {0};
    int ok = stbi_write_jpg_to_func(sink_write, &sk, ow, oh, 3, rgb, 90);
    free(rgb);
    DBG("jpg ok=%d bytes=%zu\n", ok, sk.n);
    int rc = (ok && !sk.err && sk.n > 0 && write_bytes(sk.p, sk.n, out) == 0) ? 0 : -1;
    free(sk.p);
    return rc;
}

static int write_bytes(const uint8_t *b, size_t n, const char *out) {
    char tmp[512];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", out, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    size_t w = fwrite(b, 1, n, f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    if (w != n || rename(tmp, out) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <out.jpg> [rotate] [timeout_ms] [REQ_SNAPSHOT_A|R]\n", argv[0]);
        return 2;
    }
    g_dbg = getenv("EYE_SNAP_DEBUG") != NULL;
    const char *out = argv[1];
    int deg = argc > 2 ? atoi(argv[2]) : 0;
    deg = ((deg % 360) + 360) % 360;
    int timeout = argc > 3 ? atoi(argv[3]) : 4000;
    const char *req = argc > 4 ? argv[4] : "REQ_SNAPSHOT_A";

    int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd < 0) return 1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strcpy(a.sun_path, "/run/video_rawstream/control");
    int connected = 0;
    for (int attempt = 0; attempt < 4; attempt++) {
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
            connected = 1;
            break;
        }
        if (attempt < 3) usleep(200000);
    }
    if (!connected) {
        perror("connect");
        close(fd);
        return 1;
    }
    DBG("connected\n");

    long t0 = now_ms();
    int sent = 0;
    while (now_ms() - t0 < timeout) {
        long rem = timeout - (now_ms() - t0);
        fd_set r;
        FD_ZERO(&r);
        FD_SET(fd, &r);
        struct timeval tv = {(time_t)(rem / 1000), (suseconds_t)((rem % 1000) * 1000)};
        if (select(fd + 1, &r, NULL, NULL, &tv) <= 0) continue;

        uint32_t type = 0xFFFFFFFFu;
        uint8_t pl[512];
        struct iovec iov[2] = {{&type, sizeof type}, {pl, sizeof pl}};
        union { struct cmsghdr c; char b[CMSG_SPACE(sizeof(int))]; } cu;
        struct msghdr m;
        memset(&m, 0, sizeof m);
        memset(&cu, 0, sizeof cu);
        m.msg_iov = iov;
        m.msg_iovlen = 2;
        m.msg_control = cu.b;
        m.msg_controllen = sizeof cu.b;
        ssize_t n = recvmsg(fd, &m, 0);
        if (n <= 0) break;

        int rfd = -1;
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&m); c; c = CMSG_NXTHDR(&m, c))
            if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS && c->cmsg_len >= CMSG_LEN(sizeof(int)))
                memcpy(&rfd, CMSG_DATA(c), sizeof(int));
        DBG("recv type=%u n=%zd rfd=%d\n", type, n, rfd);

        if (type == 1 && !sent) {
            send_request(fd, req);
            sent = 1;
            if (rfd >= 0) close(rfd);
        } else if (type >= 2 && rfd >= 0 && n >= 12) {
            uint32_t alloc = 0;
            memcpy(&alloc, pl + 4, 4);
            int rc = 1;
            if (alloc >= 0x80 && alloc <= 4u * 1024 * 1024) {
                uint8_t *shm = (uint8_t *)mmap(NULL, alloc, PROT_READ, MAP_SHARED, rfd, 0);
                DBG("mmap alloc=%u -> %p\n", alloc, (void *)shm);
                if (shm != MAP_FAILED) {
                    uint32_t ds = *(const uint32_t *)(shm + 8);
                    DBG("data_sz=%u\n", ds);
                    if (ds > 0x24 && (uint64_t)0x40 + ds <= alloc) {
                        const uint8_t *base = shm + 0x40;
                        if (ds > 0x23 && base[0x20] == 0xFF && base[0x21] == 0xD8 && base[0x22] == 0xFF)
                            rc = write_bytes(base + 0x20, ds - 0x20, out) == 0 ? 0 : 1;
                        else if (ds >= (uint32_t)(RAW_W * RAW_H))
                            rc = write_gray_jpeg(base + (ds - RAW_W * RAW_H), out, deg) == 0 ? 0 : 1;
                    }
                    munmap(shm, alloc);
                }
            }
            close(rfd);
            close(fd);
            return rc;
        } else if (rfd >= 0) {
            close(rfd);
        }
    }
    close(fd);
    return 1;
}
