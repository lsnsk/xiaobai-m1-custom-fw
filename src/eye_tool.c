/*
 * eye_tool.c - Fast media rotation, live shbf snapshot & WoWLAN utility
 * for Xiaomi Xiaobai Smart Cat Eye M1 (chuangmi.cateye.ipc018 / Hi3556V200)
 *
 * Subcommands:
 *   eye_tool mp4rot    <file.mp4> <0|90|180|270>
 *   eye_tool jpgrot    <in.jpg> <out.jpg> <0|90|180|270> [quality=85]
 *   eye_tool jpgscale  <in.jpg> <out.jpg> <w> <h> [quality=80]
 *   eye_tool snap      <out.jpg> [0|90|180|270] [timeout_ms=3000]
 *   eye_tool record    <out.mp4> [dur_sec=10]
 *   eye_tool rlf_add   <record_msg_path> <epoch_ts> <dur_sec> [event_type=1]
 *   eye_tool udpwake   <ip> <port> [payload=WAKEUP] [count=3]
 *   eye_tool udplisten <port> <key> <hook_cmd>
 *   eye_tool mqttpub     <host> <port> <topic> <payload> [user] [pass] [retain=0|1]
 *   eye_tool mqttpub_file <host> <port> <topic> <file> [user] [pass] [retain=0|1]
 *   eye_tool stdin2file  <out_file> <byte_len>
 *   eye_tool ogg2alaw    <in.oga|in.wav> <out.alaw>
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <opus.h>

#define STBI_ONLY_JPEG
#define STBI_NO_SIMD
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t read_be64(const uint8_t *p) {
    return ((uint64_t)read_be32(p) << 32) | (uint64_t)read_be32(p + 4);
}

static void write_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)(v);
}

/* ---------- 1. MP4 tkhd rotation matrix patcher (< 1 ms, lossless) ---------- */

static int has_vide_hdlr(FILE *fp, uint64_t start, uint64_t end) {
    uint64_t pos = start;
    uint8_t hdr[16];
    while (pos + 8 <= end) {
        if (fseeko(fp, (off_t)pos, SEEK_SET) != 0) break;
        if (fread(hdr, 1, 8, fp) != 8) break;
        uint64_t sz = read_be32(hdr);
        uint32_t hdr_len = 8;
        if (sz == 1) {
            if (pos + 16 > end || fread(hdr + 8, 1, 8, fp) != 8) break;
            sz = read_be64(hdr + 8);
            hdr_len = 16;
        } else if (sz == 0) {
            sz = end - pos;
        }
        if (sz < hdr_len || pos + sz > end) break;

        if (memcmp(hdr + 4, "mdia", 4) == 0) {
            if (has_vide_hdlr(fp, pos + hdr_len, pos + sz)) return 1;
        } else if (memcmp(hdr + 4, "hdlr", 4) == 0 && sz >= hdr_len + 12) {
            uint8_t hbuf[12];
            if (fread(hbuf, 1, 12, fp) == 12 && memcmp(hbuf + 8, "vide", 4) == 0) {
                return 1;
            }
        }
        pos += sz;
    }
    return 0;
}

static int patch_trak_tkhd(FILE *fp, uint64_t start, uint64_t end, int deg) {
    if (!has_vide_hdlr(fp, start, end)) {
        /* Fallback check: we only patch tkhd with non-zero width & height anyway */
    }
    uint64_t pos = start;
    uint8_t hdr[16];
    int patched = 0;

    while (pos + 8 <= end) {
        if (fseeko(fp, (off_t)pos, SEEK_SET) != 0) break;
        if (fread(hdr, 1, 8, fp) != 8) break;
        uint64_t sz = read_be32(hdr);
        uint32_t hdr_len = 8;
        if (sz == 1) {
            if (pos + 16 > end || fread(hdr + 8, 1, 8, fp) != 8) break;
            sz = read_be64(hdr + 8);
            hdr_len = 16;
        } else if (sz == 0) {
            sz = end - pos;
        }
        if (sz < hdr_len || pos + sz > end) break;

        if (memcmp(hdr + 4, "tkhd", 4) == 0 && sz >= hdr_len + 84) {
            uint8_t ver = 0;
            if (fread(&ver, 1, 1, fp) != 1) break;
            uint64_t mat_off = pos + hdr_len + (ver == 1 ? 52 : 40);
            uint64_t wh_off  = pos + hdr_len + (ver == 1 ? 88 : 76);
            if (wh_off + 8 <= pos + sz) {
                uint8_t wh[8];
                if (fseeko(fp, (off_t)wh_off, SEEK_SET) == 0 && fread(wh, 1, 8, fp) == 8) {
                    uint32_t w_fp = read_be32(wh);
                    uint32_t h_fp = read_be32(wh + 4);
                    if (w_fp > 0 && h_fp > 0) {
                        uint32_t m[9];
                        memset(m, 0, sizeof(m));
                        m[8] = 0x40000000U;
                        if (deg == 90) {
                            m[1] = 0x00010000U;
                            m[3] = 0xFFFF0000U; /* -1.0 in 16.16 */
                            m[6] = h_fp;
                        } else if (deg == 180) {
                            m[0] = 0xFFFF0000U;
                            m[4] = 0xFFFF0000U;
                            m[6] = w_fp;
                            m[7] = h_fp;
                        } else if (deg == 270) {
                            m[1] = 0xFFFF0000U;
                            m[3] = 0x00010000U;
                            m[7] = w_fp;
                        } else {
                            m[0] = 0x00010000U;
                            m[4] = 0x00010000U;
                        }
                        uint8_t mbuf[36];
                        for (int i = 0; i < 9; i++) write_be32(mbuf + i * 4, m[i]);
                        if (fseeko(fp, (off_t)mat_off, SEEK_SET) == 0 &&
                            fwrite(mbuf, 1, 36, fp) == 36) {
                            patched++;
                        }
                    }
                }
            }
        }
        pos += sz;
    }
    return patched;
}

static int cmd_mp4rot(const char *path, int deg) {
    deg = ((deg % 360) + 360) % 360;
    if (deg != 0 && deg != 90 && deg != 180 && deg != 270) {
        fprintf(stderr, "Invalid rotation degree: %d\n", deg);
        return 1;
    }
    FILE *fp = fopen(path, "r+b");
    if (!fp) {
        perror("fopen mp4");
        return 1;
    }
    if (fseeko(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return 1;
    }
    uint64_t fsize = (uint64_t)ftello(fp);
    uint64_t pos = 0;
    uint8_t hdr[16];
    int patched = 0;

    while (pos + 8 <= fsize) {
        if (fseeko(fp, (off_t)pos, SEEK_SET) != 0) break;
        if (fread(hdr, 1, 8, fp) != 8) break;
        uint64_t sz = read_be32(hdr);
        uint32_t hdr_len = 8;
        if (sz == 1) {
            if (pos + 16 > fsize || fread(hdr + 8, 1, 8, fp) != 8) break;
            sz = read_be64(hdr + 8);
            hdr_len = 16;
        } else if (sz == 0) {
            sz = fsize - pos;
        }
        if (sz < hdr_len || pos + sz > fsize) break;

        if (memcmp(hdr + 4, "moov", 4) == 0) {
            uint64_t mpos = pos + hdr_len;
            uint64_t mend = pos + sz;
            while (mpos + 8 <= mend) {
                if (fseeko(fp, (off_t)mpos, SEEK_SET) != 0) break;
                if (fread(hdr, 1, 8, fp) != 8) break;
                uint64_t tsz = read_be32(hdr);
                uint32_t thdr = 8;
                if (tsz == 1) {
                    if (mpos + 16 > mend || fread(hdr + 8, 1, 8, fp) != 8) break;
                    tsz = read_be64(hdr + 8);
                    thdr = 16;
                } else if (tsz == 0) {
                    tsz = mend - mpos;
                }
                if (tsz < thdr || mpos + tsz > mend) break;
                if (memcmp(hdr + 4, "trak", 4) == 0) {
                    patched += patch_trak_tkhd(fp, mpos + thdr, mpos + tsz, deg);
                }
                mpos += tsz;
            }
        }
        pos += sz;
    }

    fflush(fp);
    fsync(fileno(fp));
    fclose(fp);
    return patched > 0 ? 0 : 2;
}

/* ---------- 2. JPEG pixel rotator (atomic write) ---------- */

static int write_bytes_atomic(const char *out_path, const uint8_t *buf, size_t len) {
    char tmp_path[512];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%d", out_path, (int)getpid());
    FILE *fp = fopen(tmp_path, "wb");
    if (!fp) return -1;
    if (fwrite(buf, 1, len, fp) != len) {
        fclose(fp);
        unlink(tmp_path);
        return -1;
    }
    fflush(fp);
    fsync(fileno(fp));
    fclose(fp);
    if (rename(tmp_path, out_path) != 0) {
        unlink(tmp_path);
        return -1;
    }
    return 0;
}

static uint8_t *rotate_rgb(const uint8_t *src, int w, int h, int deg, int *out_w, int *out_h) {
    if (deg == 90) {
        int nw = h, nh = w;
        uint8_t *dst = (uint8_t *)malloc((size_t)nw * (size_t)nh * 3);
        if (!dst) return NULL;
        for (int y = 0; y < h; y++) {
            int dx = nw - 1 - y;
            const uint8_t *srow = src + (size_t)y * (size_t)w * 3;
            for (int x = 0; x < w; x++) {
                uint8_t *dp = dst + ((size_t)x * (size_t)nw + (size_t)dx) * 3;
                const uint8_t *sp = srow + (size_t)x * 3;
                dp[0] = sp[0];
                dp[1] = sp[1];
                dp[2] = sp[2];
            }
        }
        *out_w = nw;
        *out_h = nh;
        return dst;
    } else if (deg == 270) {
        int nw = h, nh = w;
        uint8_t *dst = (uint8_t *)malloc((size_t)nw * (size_t)nh * 3);
        if (!dst) return NULL;
        for (int y = 0; y < h; y++) {
            const uint8_t *srow = src + (size_t)y * (size_t)w * 3;
            for (int x = 0; x < w; x++) {
                int dy = nh - 1 - x;
                uint8_t *dp = dst + ((size_t)dy * (size_t)nw + (size_t)y) * 3;
                const uint8_t *sp = srow + (size_t)x * 3;
                dp[0] = sp[0];
                dp[1] = sp[1];
                dp[2] = sp[2];
            }
        }
        *out_w = nw;
        *out_h = nh;
        return dst;
    } else if (deg == 180) {
        uint8_t *dst = (uint8_t *)malloc((size_t)w * (size_t)h * 3);
        if (!dst) return NULL;
        size_t total = (size_t)w * (size_t)h;
        for (size_t i = 0; i < total; i++) {
            size_t j = total - 1 - i;
            dst[j * 3 + 0] = src[i * 3 + 0];
            dst[j * 3 + 1] = src[i * 3 + 1];
            dst[j * 3 + 2] = src[i * 3 + 2];
        }
        *out_w = w;
        *out_h = h;
        return dst;
    }
    return NULL;
}

typedef struct {
    uint8_t *buf;
    size_t len;
    size_t cap;
    int err;
} jpg_sink_t;

static void jpg_sink_cb(void *ctx, void *data, int size) {
    jpg_sink_t *s = (jpg_sink_t *)ctx;
    if (s->err || size <= 0) return;
    if (s->len + (size_t)size > s->cap) {
        size_t nc = s->cap ? s->cap * 2U : 65536U;
        while (nc < s->len + (size_t)size) nc *= 2U;
        uint8_t *nb = (uint8_t *)realloc(s->buf, nc);
        if (!nb) {
            s->err = 1;
            return;
        }
        s->buf = nb;
        s->cap = nc;
    }
    memcpy(s->buf + s->len, data, (size_t)size);
    s->len += (size_t)size;
}

static int write_rgb_jpg_atomic(const char *out_path, int w, int h, const uint8_t *rgb, int quality) {
    jpg_sink_t sk;
    memset(&sk, 0, sizeof(sk));
    int ok = stbi_write_jpg_to_func(jpg_sink_cb, &sk, w, h, 3, rgb, quality);
    int rc = (ok && !sk.err && sk.len > 0 && write_bytes_atomic(out_path, sk.buf, sk.len) == 0) ? 0 : -1;
    free(sk.buf);
    return rc;
}

static int save_rotated_jpg_from_mem(const uint8_t *jpg_data, size_t jpg_len,
                                     const char *out_path, int deg, int quality) {
    deg = ((deg % 360) + 360) % 360;
    if (deg == 0) {
        return write_bytes_atomic(out_path, jpg_data, jpg_len);
    }
    int w = 0, h = 0, comp = 0;
    uint8_t *rgb = stbi_load_from_memory(jpg_data, (int)jpg_len, &w, &h, &comp, 3);
    if (!rgb) {
        fprintf(stderr, "stbi_load failed: %s\n", stbi_failure_reason());
        return -1;
    }
    int nw = w, nh = h;
    uint8_t *rot = rotate_rgb(rgb, w, h, deg, &nw, &nh);
    stbi_image_free(rgb);
    if (!rot) return -1;

    int rc = write_rgb_jpg_atomic(out_path, nw, nh, rot, quality);
    free(rot);
    return rc;
}

static int cmd_jpgrot(const char *in_path, const char *out_path, int deg, int quality) {
    deg = ((deg % 360) + 360) % 360;
    if (deg == 0 && strcmp(in_path, out_path) == 0) return 0;

    FILE *fp = fopen(in_path, "rb");
    if (!fp) {
        perror("fopen jpg");
        return 1;
    }
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (sz <= 0 || sz > 16 * 1024 * 1024) {
        fclose(fp);
        return 1;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) {
        fclose(fp);
        return 1;
    }
    if (fread(buf, 1, (size_t)sz, fp) != (size_t)sz) {
        free(buf);
        fclose(fp);
        return 1;
    }
    fclose(fp);
    int rc = save_rotated_jpg_from_mem(buf, (size_t)sz, out_path, deg, quality);
    free(buf);
    return rc == 0 ? 0 : 1;
}

/* ---------- 3. Live shbf snapshot via /run/video_rawstream/control ---------- */

static int send_shbf_req_snapshot(int fd) {
    uint32_t pkt_type = 0; /* shbf_rcv_send_message type = 0 */
    char cmd[] = "REQ_SNAPSHOT_A";
    struct iovec iov[2];
    iov[0].iov_base = &pkt_type;
    iov[0].iov_len  = sizeof(pkt_type);
    iov[1].iov_base = cmd;
    iov[1].iov_len  = sizeof(cmd); /* 15 bytes incl NUL */

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov    = iov;
    msg.msg_iovlen = 2;
    return sendmsg(fd, &msg, MSG_NOSIGNAL) >= 0 ? 0 : -1;
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int cmd_snap(const char *out_path, int deg, int timeout_ms) {
    int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd >= 0) {
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, "/run/video_rawstream/control", sizeof(addr.sun_path) - 1);

        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            int64_t deadline = now_ms() + timeout_ms;
            int sent_req = 0;

            while (now_ms() < deadline) {
                int64_t rem = deadline - now_ms();
                if (rem < 10) rem = 10;
                fd_set rfds;
                FD_ZERO(&rfds);
                FD_SET(fd, &rfds);
                struct timeval tv;
                tv.tv_sec  = (time_t)(rem / 1000);
                tv.tv_usec = (suseconds_t)((rem % 1000) * 1000);

                int r = select(fd + 1, &rfds, NULL, NULL, &tv);
                if (r <= 0) continue;

                uint32_t pkt_type = 0xFFFFFFFFU;
                uint8_t payload[512];
                struct iovec iov[2];
                iov[0].iov_base = &pkt_type;
                iov[0].iov_len  = sizeof(pkt_type);
                iov[1].iov_base = payload;
                iov[1].iov_len  = sizeof(payload);

                union {
                    struct cmsghdr cm;
                    char control[CMSG_SPACE(sizeof(int))];
                } cmsg_un;
                memset(&cmsg_un, 0, sizeof(cmsg_un));

                struct msghdr msg;
                memset(&msg, 0, sizeof(msg));
                msg.msg_iov        = iov;
                msg.msg_iovlen     = 2;
                msg.msg_control    = cmsg_un.control;
                msg.msg_controllen = sizeof(cmsg_un.control);

                ssize_t n = recvmsg(fd, &msg, 0);
                if (n <= 0) break;

                int recv_fd = -1;
                for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL;
                     cmsg = CMSG_NXTHDR(&msg, cmsg)) {
                    if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS &&
                        cmsg->cmsg_len >= CMSG_LEN(sizeof(int))) {
                        memcpy(&recv_fd, CMSG_DATA(cmsg), sizeof(int));
                    }
                }

                if (pkt_type == 1 && !sent_req) {
                    send_shbf_req_snapshot(fd);
                    sent_req = 1;
                    if (recv_fd >= 0) close(recv_fd);
                } else if (pkt_type == 2 && recv_fd >= 0 && n >= 12) {
                    uint32_t alloc_sz = 0;
                    memcpy(&alloc_sz, payload + 4, 4);
                    int got_jpg = 0;
                    if (alloc_sz >= 0x80 && alloc_sz <= 4 * 1024 * 1024) {
                        uint8_t *shm = (uint8_t *)mmap(NULL, alloc_sz, PROT_READ, MAP_SHARED, recv_fd, 0);
                        if (shm != MAP_FAILED) {
                            uint32_t data_sz = *(const uint32_t *)(shm + 8);
                            if (data_sz > 0x24 && (uint64_t)0x40 + data_sz <= alloc_sz) {
                                const uint8_t *base = shm + 0x40;
                                /* Snapshot has 0x20-byte metadata header before FF D8 FF */
                                size_t jpg_off = 0xFFFFFFFFU;
                                if (data_sz > 0x23 && base[0x20] == 0xFF && base[0x21] == 0xD8 && base[0x22] == 0xFF) {
                                    jpg_off = 0x20;
                                } else {
                                    size_t scan_lim = data_sz < 128 ? data_sz - 3 : 128;
                                    for (size_t k = 0; k < scan_lim; k++) {
                                        if (base[k] == 0xFF && base[k + 1] == 0xD8 && base[k + 2] == 0xFF) {
                                            jpg_off = k;
                                            break;
                                        }
                                    }
                                }
                                if (jpg_off != 0xFFFFFFFFU && data_sz - jpg_off > 512) {
                                    if (save_rotated_jpg_from_mem(base + jpg_off, data_sz - jpg_off,
                                                                  out_path, deg, 85) == 0) {
                                        got_jpg = 1;
                                    }
                                } else if (data_sz >= 640U * 360U) {
                                    /* 4.3.5_3319 REQ_SNAPSHOT_A delivers uncompressed 640x360 8-bit luma */
                                    const uint8_t *y = base + (data_sz - 640U * 360U);
                                    uint8_t *rgb = (uint8_t *)malloc(640U * 360U * 3U);
                                    if (rgb) {
                                        for (size_t k = 0; k < 640U * 360U; k++) {
                                            rgb[k * 3 + 0] = y[k];
                                            rgb[k * 3 + 1] = y[k];
                                            rgb[k * 3 + 2] = y[k];
                                        }
                                        int d = ((deg % 360) + 360) % 360;
                                        if (d == 0) {
                                            if (write_rgb_jpg_atomic(out_path, 640, 360, rgb, 88) == 0) got_jpg = 1;
                                        } else {
                                            int nw = 640, nh = 360;
                                            uint8_t *rot = rotate_rgb(rgb, 640, 360, d, &nw, &nh);
                                            if (rot) {
                                                if (write_rgb_jpg_atomic(out_path, nw, nh, rot, 88) == 0) got_jpg = 1;
                                                free(rot);
                                            }
                                        }
                                        free(rgb);
                                    }
                                }
                            }
                            munmap(shm, alloc_sz);
                        }
                    }
                    close(recv_fd);
                    if (got_jpg) {
                        close(fd);
                        return 0;
                    }
                } else {
                    if (recv_fd >= 0) close(recv_fd);
                }
            }
        }
        close(fd);
    }

    /* Fallback to /dev/alarm0.jpeg if present */
    struct stat st;
    if (stat("/dev/alarm0.jpeg", &st) == 0 && st.st_size > 512) {
        return cmd_jpgrot("/dev/alarm0.jpeg", out_path, deg, 85);
    }
    return 1;
}

/* ---------- 4. UDP WoWLAN magic packet sender ---------- */

static int cmd_udpwake(const char *ip, int port, const char *payload, int count) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }
    int bcast = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &bcast, sizeof(bcast));

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port   = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) {
        close(fd);
        return 1;
    }
    size_t len = strlen(payload);
    for (int i = 0; i < count; i++) {
        sendto(fd, payload, len, 0, (struct sockaddr *)&dst, sizeof(dst));
        if (i + 1 < count) usleep(40000);
    }
    close(fd);
    return 0;
}

static int cmd_udplisten(int port, const char *key, const char *hook_cmd) {
    if (!key || !key[0]) {
        fprintf(stderr, "udplisten: empty key not allowed\n");
        return 1;
    }
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close(fd);
        return 1;
    }

    size_t key_len = strlen(key);
    int64_t last_fire = 0;
    char buf[256];

    for (;;) {
        struct sockaddr_in peer;
        socklen_t peer_len = sizeof(peer);
        ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&peer, &peer_len);
        if (n <= 0) continue;
        buf[n] = '\0';
        /* Trim trailing CR/LF */
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) {
            buf[--n] = '\0';
        }
        if ((size_t)n >= key_len && memcmp(buf, key, key_len) == 0) {
            const char *ack = "OK_AWAKE\n";
            sendto(fd, ack, strlen(ack), 0, (struct sockaddr *)&peer, peer_len);
            int64_t t = now_ms();
            if (t - last_fire >= 5000 && hook_cmd && hook_cmd[0]) {
                last_fire = t;
                char run_buf[512];
                snprintf(run_buf, sizeof(run_buf), "%s &", hook_cmd);
                system(run_buf);
            }
        }
    }
}

/* ---------- 5. Lightweight raw TCP MQTT v3.1.1 publisher (HA Auto-Discovery ready) ---------- */

static size_t mqtt_put_varlen(uint8_t *dst, size_t len) {
    size_t n = 0;
    do {
        uint8_t byte = (uint8_t)(len & 0x7FU);
        len >>= 7;
        if (len > 0) byte |= 0x80U;
        dst[n++] = byte;
    } while (len > 0 && n < 4);
    return n;
}

static uint8_t *mqtt_put_str(uint8_t *p, const char *s) {
    size_t n = strlen(s);
    if (n > 65535) n = 65535;
    p[0] = (uint8_t)(n >> 8);
    p[1] = (uint8_t)(n & 0xFFU);
    memcpy(p + 2, s, n);
    return p + 2 + n;
}

static int send_all(int fd, const uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t w = send(fd, buf + off, len - off, MSG_NOSIGNAL);
        if (w <= 0) {
            if (w < 0 && errno == EINTR) continue;
            return -1;
        }
        off += (size_t)w;
    }
    return 0;
}

static int connect_tcp_timeout(const char *host, int port, int timeout_ms) {
    char port_s[16];
    snprintf(port_s, sizeof(port_s), "%d", port);

    struct addrinfo hints, *res = NULL, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port_s, &hints, &res) != 0 || !res) return -1;

    int fd = -1;
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;

        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int rc = connect(fd, rp->ai_addr, rp->ai_addrlen);
        if (rc != 0 && errno != EINPROGRESS) {
            close(fd);
            fd = -1;
            continue;
        }
        if (rc != 0) {
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(fd, &wfds);
            struct timeval tv;
            tv.tv_sec  = timeout_ms / 1000;
            tv.tv_usec = (timeout_ms % 1000) * 1000;
            if (select(fd + 1, NULL, &wfds, NULL, &tv) <= 0) {
                close(fd);
                fd = -1;
                continue;
            }
            int so_err = 0;
            socklen_t slen = sizeof(so_err);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &slen) != 0 || so_err != 0) {
                close(fd);
                fd = -1;
                continue;
            }
        }
        if (flags >= 0) fcntl(fd, F_SETFL, flags);
        struct timeval iotv;
        iotv.tv_sec  = timeout_ms / 1000;
        iotv.tv_usec = (timeout_ms % 1000) * 1000;
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &iotv, sizeof(iotv));
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &iotv, sizeof(iotv));
        break;
    }
    freeaddrinfo(res);
    return fd;
}

static int mqtt_publish_bytes(const char *host, int port, const char *topic,
                              const uint8_t *payload, size_t pl_len,
                              const char *user, const char *pass, int retain) {
    if (!host || !host[0] || !topic || !topic[0] || (!payload && pl_len > 0)) return 1;
    if (port <= 0 || port > 65535) port = 1883;

    size_t t_len = strlen(topic);
    if (t_len > 4096 || pl_len > 524288) return 1;

    int fd = connect_tcp_timeout(host, port, 1200);
    if (fd < 0) return 1;

    char cid[48];
    snprintf(cid, sizeof(cid), "xiaobai_m1_%d", (int)getpid());

    int has_user = (user && user[0]) ? 1 : 0;
    int has_pass = (has_user && pass && pass[0]) ? 1 : 0;

    size_t cid_len  = strlen(cid);
    size_t u_len    = has_user ? strlen(user) : 0;
    size_t p_len    = has_pass ? strlen(pass) : 0;
    size_t conn_rem = 10 + (2 + cid_len) + (has_user ? (2 + u_len) : 0) + (has_pass ? (2 + p_len) : 0);
    size_t pub_rem  = (2 + t_len) + pl_len;

    uint8_t *pkt = (uint8_t *)malloc(conn_rem + pub_rem + 32);
    if (!pkt) {
        close(fd);
        return 1;
    }

    /* 1. Build & send CONNECT (MQTT v3.1.1) */
    uint8_t *q = pkt;
    *q++ = 0x10U;
    q += mqtt_put_varlen(q, conn_rem);
    q = mqtt_put_str(q, "MQTT");
    *q++ = 0x04U; /* Protocol Level 4 (v3.1.1) */
    uint8_t cflags = 0x02U; /* Clean Session */
    if (has_user) cflags |= 0x80U;
    if (has_pass) cflags |= 0x40U;
    *q++ = cflags;
    *q++ = 0x00U;
    *q++ = 0x0FU; /* KeepAlive = 15s */
    q = mqtt_put_str(q, cid);
    if (has_user) q = mqtt_put_str(q, user);
    if (has_pass) q = mqtt_put_str(q, pass);

    if (send_all(fd, pkt, (size_t)(q - pkt)) != 0) {
        free(pkt);
        close(fd);
        return 1;
    }

    /* 2. Wait for 4-byte CONNACK (0x20 0x02 <sp> <rc==0>) */
    uint8_t ack[4];
    ssize_t an = recv(fd, ack, sizeof(ack), MSG_WAITALL);
    if (an != 4 || (ack[0] & 0xF0U) != 0x20U || ack[3] != 0x00U) {
        if (an == 4 && (ack[0] & 0xF0U) == 0x20U) {
            fprintf(stderr, "MQTT_CONNACK_RC=%u\n", (unsigned)ack[3]);
        } else {
            fprintf(stderr, "MQTT_CONNACK_ERR=%zd\n", an);
        }
        free(pkt);
        close(fd);
        return 2;
    }

    /* 3. Build & send PUBLISH + DISCONNECT back-to-back */
    q = pkt;
    *q++ = (uint8_t)(0x30U | (retain ? 0x01U : 0x00U));
    q += mqtt_put_varlen(q, pub_rem);
    q = mqtt_put_str(q, topic);
    if (pl_len > 0) {
        memcpy(q, payload, pl_len);
        q += pl_len;
    }
    *q++ = 0xE0U; /* DISCONNECT */
    *q++ = 0x00U;

    int rc = send_all(fd, pkt, (size_t)(q - pkt));
    free(pkt);
    shutdown(fd, SHUT_WR);
    if (rc == 0 && pl_len > 4096) {
        struct timeval fin_tv;
        fin_tv.tv_sec  = 0;
        fin_tv.tv_usec = 200000;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &fin_tv, sizeof(fin_tv));
        uint8_t eof_b;
        (void)recv(fd, &eof_b, 1, 0);
    }
    close(fd);
    return rc == 0 ? 0 : 1;
}

static int cmd_mqttpub(const char *host, int port, const char *topic, const char *payload,
                       const char *user, const char *pass, int retain) {
    if (!payload) return 1;
    return mqtt_publish_bytes(host, port, topic, (const uint8_t *)payload, strlen(payload), user, pass, retain);
}

static int cmd_mqttpub_file(const char *host, int port, const char *topic, const char *file_path,
                            const char *user, const char *pass, int retain) {
    if (!file_path || !file_path[0]) return 1;
    FILE *fp = fopen(file_path, "rb");
    if (!fp) return 1;
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return 1;
    }
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (sz < 1 || sz > 524288) {
        fclose(fp);
        return 1;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) {
        fclose(fp);
        return 1;
    }
    if (fread(buf, 1, (size_t)sz, fp) != (size_t)sz) {
        free(buf);
        fclose(fp);
        return 1;
    }
    fclose(fp);
    int rc = mqtt_publish_bytes(host, port, topic, buf, (size_t)sz, user, pass, retain);
    free(buf);
    return rc;
}

static int cmd_stdin2file(const char *out_path, size_t want_len) {
    if (!out_path || !out_path[0] || want_len == 0 || want_len > 512 * 1024) return 1;
    uint8_t *buf = (uint8_t *)malloc(want_len);
    if (!buf) return 1;
    size_t got = 0;
    while (got < want_len) {
        ssize_t r = read(STDIN_FILENO, buf + got, want_len - got);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (r == 0) break;
        got += (size_t)r;
    }
    if (got == 0) {
        free(buf);
        return 1;
    }
    int rc = write_bytes_atomic(out_path, buf, got);
    free(buf);
    return rc == 0 ? 0 : 1;
}

/* ---------- 6. Telegram Voice (.oga Ogg Opus / .wav) -> 8000 Hz ITU-T G.711 A-law ---------- */

#define MAX_VOICE_SAMPLES_8K (8000 * 30) /* 30 seconds max outdoor intercom message */

static uint8_t lin2alaw_sample(int pcm_val) {
    if (pcm_val < -32768) pcm_val = -32768;
    if (pcm_val > 32767) pcm_val = 32767;
    uint8_t sign = 0x80U;
    if (pcm_val < 0) {
        sign = 0x00U;
        pcm_val = -pcm_val - 1;
        if (pcm_val < 0) pcm_val = 0;
    }
    pcm_val >>= 3;
    uint8_t aval;
    if (pcm_val >= 256) {
        int seg = 7;
        for (int s = 1; s < 8; s++) {
            if (pcm_val < (0x100 << s)) {
                seg = s;
                break;
            }
        }
        aval = (uint8_t)((seg << 4) | ((pcm_val >> (seg + 3)) & 0x0F));
    } else {
        aval = (uint8_t)(pcm_val >> 4);
    }
    return (uint8_t)((aval | sign) ^ 0xD5U);
}

static uint32_t read_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint16_t read_le16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static int write_normalized_alaw(const char *out_path, int16_t *pcm_8k, size_t n_samples) {
    if (n_samples == 0) return -1;
    int max_abs = 0;
    for (size_t i = 0; i < n_samples; i++) {
        int a = pcm_8k[i] < 0 ? -(int)pcm_8k[i] : (int)pcm_8k[i];
        if (a > max_abs) max_abs = a;
    }
    /* Gentle auto-gain for quiet phone voice notes (boost up to 4.5x toward -2 dBFS = 26000) */
    int gain_q10 = 1024;
    if (max_abs >= 800 && max_abs < 26000) {
        gain_q10 = (26000 * 1024) / max_abs;
        if (gain_q10 > 4608) gain_q10 = 4608;
    }
    size_t padded = ((n_samples + 319U) / 320U) * 320U;
    if (padded < 320U) padded = 320U;
    uint8_t *alaw = (uint8_t *)malloc(padded);
    if (!alaw) return -1;
    memset(alaw, 0xD5, padded);
    for (size_t i = 0; i < n_samples; i++) {
        int v = ((int)pcm_8k[i] * gain_q10) >> 10;
        alaw[i] = lin2alaw_sample(v);
    }
    int rc = write_bytes_atomic(out_path, alaw, padded);
    free(alaw);
    return rc;
}

static int decode_ogg_opus_to_alaw(const uint8_t *buf, size_t len, const char *out_path) {
    int16_t *pcm_8k = (int16_t *)malloc(MAX_VOICE_SAMPLES_8K * sizeof(int16_t));
    uint8_t *pkt = (uint8_t *)malloc(65536);
    if (!pcm_8k || !pkt) {
        free(pcm_8k);
        free(pkt);
        return -1;
    }

    size_t out_n = 0;
    size_t pkt_len = 0;
    size_t pos = 0;
    int got_head = 0;
    int got_tags = 0;
    int channels = 1;
    uint32_t target_serial = 0;
    uint32_t skip_rem = 0;
    OpusDecoder *dec = NULL;
    opus_int16 frame_pcm[960 * 2];

    while (pos + 27 <= len && out_n < MAX_VOICE_SAMPLES_8K) {
        if (memcmp(buf + pos, "OggS", 4) != 0) {
            pos++;
            continue;
        }
        if (buf[pos + 4] != 0) { /* stream_structure_version must be 0 */
            pos += 4;
            continue;
        }
        uint8_t hdr_type = buf[pos + 5];
        uint32_t serial  = read_le32(buf + pos + 14);
        uint8_t nsegs    = buf[pos + 26];
        if (pos + 27 + (size_t)nsegs > len) break;

        const uint8_t *seg_tbl = buf + pos + 27;
        size_t body_off = pos + 27 + (size_t)nsegs;
        size_t page_body = 0;
        for (uint8_t i = 0; i < nsegs; i++) page_body += seg_tbl[i];
        if (body_off + page_body > len) break;

        if (got_head && serial != target_serial) {
            pos = body_off + page_body;
            continue;
        }
        if ((hdr_type & 0x01U) == 0) {
            /* Fresh packet start on page boundary */
            pkt_len = 0;
        }

        size_t cur = body_off;
        for (uint8_t i = 0; i < nsegs; i++) {
            uint8_t slen = seg_tbl[i];
            if (pkt_len + slen <= 65536) {
                memcpy(pkt + pkt_len, buf + cur, slen);
                pkt_len += slen;
            } else {
                pkt_len = 65537; /* mark oversized packet to drop */
            }
            cur += slen;

            if (slen < 255) {
                /* Complete Ogg packet */
                if (pkt_len <= 65536) {
                    if (!got_head) {
                        if (pkt_len >= 19 && memcmp(pkt, "OpusHead", 8) == 0) {
                            channels = pkt[9];
                            if (channels >= 1 && channels <= 2) {
                                uint16_t pre_skip_48k = read_le16(pkt + 10);
                                int16_t gain_q8 = (int16_t)read_le16(pkt + 16);
                                int err = OPUS_OK;
                                dec = opus_decoder_create(8000, channels, &err);
                                if (dec && err == OPUS_OK) {
                                    if (gain_q8 != 0) {
                                        opus_decoder_ctl(dec, OPUS_SET_GAIN(gain_q8));
                                    }
                                    skip_rem = (uint32_t)(pre_skip_48k / 6U);
                                    target_serial = serial;
                                    got_head = 1;
                                }
                            }
                        }
                    } else if (!got_tags && pkt_len >= 8 && memcmp(pkt, "OpusTags", 8) == 0) {
                        got_tags = 1;
                    } else if (dec && pkt_len > 0) {
                        got_tags = 1;
                        int n_samp = opus_decode(dec, pkt, (opus_int32)pkt_len, frame_pcm, 960, 0);
                        if (n_samp > 0) {
                            for (int s = 0; s < n_samp && out_n < MAX_VOICE_SAMPLES_8K; s++) {
                                if (skip_rem > 0) {
                                    skip_rem--;
                                    continue;
                                }
                                int v = (channels == 2)
                                            ? (((int)frame_pcm[s * 2] + (int)frame_pcm[s * 2 + 1]) / 2)
                                            : (int)frame_pcm[s];
                                pcm_8k[out_n++] = (int16_t)v;
                            }
                        }
                    }
                }
                pkt_len = 0;
                if (out_n >= MAX_VOICE_SAMPLES_8K) break;
            }
        }
        pos = body_off + page_body;
    }

    if (dec) opus_decoder_destroy(dec);
    free(pkt);

    if (out_n < 400) { /* require >= 50 ms valid audio */
        free(pcm_8k);
        return -1;
    }
    int rc = write_normalized_alaw(out_path, pcm_8k, out_n);
    free(pcm_8k);
    return rc;
}

static int decode_wav_to_alaw(const uint8_t *buf, size_t len, const char *out_path) {
    if (len < 44) return -1;
    uint16_t fmt_tag = 0, ch = 0, bits = 0;
    uint32_t srate = 0;
    const uint8_t *data_ptr = NULL;
    size_t data_len = 0;

    size_t pos = 12;
    while (pos + 8 <= len) {
        uint32_t csz = read_le32(buf + pos + 4);
        size_t cbody = pos + 8;
        if (cbody + csz > len) csz = (uint32_t)(len - cbody);
        if (memcmp(buf + pos, "fmt ", 4) == 0 && csz >= 16) {
            fmt_tag = read_le16(buf + cbody + 0);
            ch      = read_le16(buf + cbody + 2);
            srate   = read_le32(buf + cbody + 4);
            bits    = read_le16(buf + cbody + 14);
        } else if (memcmp(buf + pos, "data", 4) == 0) {
            data_ptr = buf + cbody;
            data_len = csz;
            break;
        }
        pos = cbody + csz + (csz & 1U);
    }
    if (!data_ptr || data_len == 0 || ch < 1 || ch > 2 || srate < 4000 || srate > 96000) return -1;

    if (fmt_tag == 6 && ch == 1 && srate == 8000 && bits == 8) {
        /* Already 8 kHz mono G.711 A-law */
        if (data_len > MAX_VOICE_SAMPLES_8K) data_len = MAX_VOICE_SAMPLES_8K;
        size_t padded = ((data_len + 319U) / 320U) * 320U;
        uint8_t *alaw = (uint8_t *)malloc(padded);
        if (!alaw) return -1;
        memset(alaw, 0xD5, padded);
        memcpy(alaw, data_ptr, data_len);
        int rc = write_bytes_atomic(out_path, alaw, padded);
        free(alaw);
        return rc;
    }
    if (fmt_tag != 1 || (bits != 16 && bits != 8)) return -1;

    size_t frame_bytes = (size_t)ch * (bits / 8U);
    size_t in_frames = data_len / frame_bytes;
    if (in_frames < 100) return -1;

    size_t out_n = (size_t)(((uint64_t)in_frames * 8000ULL) / (uint64_t)srate);
    if (out_n > MAX_VOICE_SAMPLES_8K) out_n = MAX_VOICE_SAMPLES_8K;
    int16_t *pcm_8k = (int16_t *)malloc(out_n * sizeof(int16_t));
    if (!pcm_8k) return -1;

    for (size_t i = 0; i < out_n; i++) {
        size_t src_i = (size_t)(((uint64_t)i * (uint64_t)srate) / 8000ULL);
        if (src_i >= in_frames) src_i = in_frames - 1;
        const uint8_t *sp = data_ptr + src_i * frame_bytes;
        int v = 0;
        if (bits == 16) {
            int s0 = (int16_t)read_le16(sp);
            int s1 = (ch == 2) ? (int16_t)read_le16(sp + 2) : s0;
            v = (s0 + s1) / 2;
        } else {
            int s0 = ((int)sp[0] - 128) << 8;
            int s1 = (ch == 2) ? (((int)sp[1] - 128) << 8) : s0;
            v = (s0 + s1) / 2;
        }
        pcm_8k[i] = (int16_t)v;
    }
    int rc = write_normalized_alaw(out_path, pcm_8k, out_n);
    free(pcm_8k);
    return rc;
}

static int cmd_ogg2alaw(const char *in_path, const char *out_path) {
    FILE *fp = fopen(in_path, "rb");
    if (!fp) return 1;
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return 1;
    }
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (sz < 28 || sz > 4 * 1024 * 1024) {
        fclose(fp);
        return 1;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) {
        fclose(fp);
        return 1;
    }
    if (fread(buf, 1, (size_t)sz, fp) != (size_t)sz) {
        free(buf);
        fclose(fp);
        return 1;
    }
    fclose(fp);

    int rc = -1;
    if (sz >= 12 && memcmp(buf, "RIFF", 4) == 0 && memcmp(buf + 8, "WAVE", 4) == 0) {
        rc = decode_wav_to_alaw(buf, (size_t)sz, out_path);
    } else {
        rc = decode_ogg_opus_to_alaw(buf, (size_t)sz, out_path);
    }
    free(buf);
    return rc == 0 ? 0 : 1;
}

/* ---------- 7. Fast JPEG downscale (320x180 album thumbnail) ---------- */

static int cmd_jpgscale(const char *in_path, const char *out_path, int dst_w, int dst_h, int quality) {
    if (dst_w < 8 || dst_w > 4096 || dst_h < 8 || dst_h > 4096) return 1;
    if (quality < 10) quality = 10;
    if (quality > 100) quality = 100;

    int sw = 0, sh = 0, comp = 0;
    uint8_t *src = stbi_load(in_path, &sw, &sh, &comp, 3);
    if (!src || sw <= 0 || sh <= 0) {
        if (src) stbi_image_free(src);
        fprintf(stderr, "jpgscale stbi_load failed\n");
        return 1;
    }

    uint8_t *dst = (uint8_t *)malloc((size_t)dst_w * (size_t)dst_h * 3);
    if (!dst) {
        stbi_image_free(src);
        return 1;
    }

    for (int dy = 0; dy < dst_h; dy++) {
        int64_t fy_q16 = (((int64_t)dy * 2 + 1) * sh * 32768LL) / dst_h - 32768LL;
        if (fy_q16 < 0) fy_q16 = 0;
        int y0 = (int)(fy_q16 >> 16);
        int wy = (int)(fy_q16 & 0xFFFF);
        if (y0 >= sh - 1) {
            y0 = sh - 1;
            wy = 0;
        }
        int y1 = (y0 + 1 < sh) ? (y0 + 1) : y0;
        int wy0 = 65536 - wy;
        const uint8_t *row0 = src + (size_t)y0 * (size_t)sw * 3;
        const uint8_t *row1 = src + (size_t)y1 * (size_t)sw * 3;
        uint8_t *drow = dst + (size_t)dy * (size_t)dst_w * 3;

        for (int dx = 0; dx < dst_w; dx++) {
            int64_t fx_q16 = (((int64_t)dx * 2 + 1) * sw * 32768LL) / dst_w - 32768LL;
            if (fx_q16 < 0) fx_q16 = 0;
            int x0 = (int)(fx_q16 >> 16);
            int wx = (int)(fx_q16 & 0xFFFF);
            if (x0 >= sw - 1) {
                x0 = sw - 1;
                wx = 0;
            }
            int x1 = (x0 + 1 < sw) ? (x0 + 1) : x0;
            int wx0 = 65536 - wx;
            const uint8_t *p00 = row0 + (size_t)x0 * 3;
            const uint8_t *p01 = row0 + (size_t)x1 * 3;
            const uint8_t *p10 = row1 + (size_t)x0 * 3;
            const uint8_t *p11 = row1 + (size_t)x1 * 3;

            for (int c = 0; c < 3; c++) {
                int64_t top = (int64_t)p00[c] * wx0 + (int64_t)p01[c] * wx;
                int64_t bot = (int64_t)p10[c] * wx0 + (int64_t)p11[c] * wx;
                int64_t val = ((top >> 8) * (wy0 >> 8) + (bot >> 8) * (wy >> 8) + 32768) >> 16;
                if (val < 0) val = 0;
                if (val > 255) val = 255;
                drow[dx * 3 + c] = (uint8_t)val;
            }
        }
    }

    stbi_image_free(src);
    int rc = write_rgb_jpg_atomic(out_path, dst_w, dst_h, dst, quality);
    free(dst);
    return rc == 0 ? 0 : 1;
}

/* ---------- 8. Native .record_msg indexer (compatible with librlf.so) ---------- */

#define RLF_TOTAL_SIZE 1048576U
#define RLF_HDR_SIZE   512U
#define RLF_MAX_RECS   ((RLF_TOTAL_SIZE - RLF_HDR_SIZE) / 8U)

static void write_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFFU);
    p[1] = (uint8_t)((v >> 8) & 0xFFU);
    p[2] = (uint8_t)((v >> 16) & 0xFFU);
    p[3] = (uint8_t)((v >> 24) & 0xFFU);
}

static int init_rlf_file(FILE *fp, uint8_t hdr[RLF_HDR_SIZE]) {
    memset(hdr, 0, RLF_HDR_SIZE);
    write_le32(hdr + 0x00, 1U);
    write_le32(hdr + 0x04, 1U);
    memcpy(hdr + 0x08, "chuangmi.camera.ipc009", 22);
    write_le32(hdr + 0x48, 0U);
    write_le32(hdr + 0x4C, RLF_HDR_SIZE);
    write_le32(hdr + 0x50, 0U);

    if (fseeko(fp, 0, SEEK_SET) != 0) return -1;
    if (fwrite(hdr, 1, RLF_HDR_SIZE, fp) != RLF_HDR_SIZE) return -1;
    uint8_t z[4096];
    memset(z, 0, sizeof(z));
    size_t rem = RLF_TOTAL_SIZE - RLF_HDR_SIZE;
    while (rem > 0) {
        size_t chunk = rem > sizeof(z) ? sizeof(z) : rem;
        if (fwrite(z, 1, chunk, fp) != chunk) return -1;
        rem -= chunk;
    }
    return 0;
}

static int cmd_rlf_add(const char *path, uint32_t epoch_ts, int dur_sec, int event_type) {
    if (!path || !path[0] || epoch_ts == 0) return 1;
    if (dur_sec < 1) dur_sec = 1;
    if (dur_sec > 255) dur_sec = 255;
    if (event_type < 0 || event_type > 255) event_type = 1;

    uint8_t hdr[RLF_HDR_SIZE];
    FILE *fp = fopen(path, "r+b");
    if (!fp) {
        fp = fopen(path, "w+b");
        if (!fp) {
            perror("fopen rlf");
            return 1;
        }
        if (init_rlf_file(fp, hdr) != 0) {
            fclose(fp);
            return 1;
        }
    } else {
        if (fseeko(fp, 0, SEEK_END) != 0) {
            fclose(fp);
            return 1;
        }
        off_t fsz = ftello(fp);
        if (fsz < (off_t)RLF_HDR_SIZE) {
            if (init_rlf_file(fp, hdr) != 0) {
                fclose(fp);
                return 1;
            }
        } else {
            if (fseeko(fp, 0, SEEK_SET) != 0 || fread(hdr, 1, RLF_HDR_SIZE, fp) != RLF_HDR_SIZE ||
                read_le32(hdr) != 1U) {
                if (init_rlf_file(fp, hdr) != 0) {
                    fclose(fp);
                    return 1;
                }
            } else if (fsz < (off_t)RLF_TOTAL_SIZE) {
                if (fseeko(fp, fsz, SEEK_SET) != 0) {
                    fclose(fp);
                    return 1;
                }
                uint8_t z[4096];
                memset(z, 0, sizeof(z));
                size_t rem = RLF_TOTAL_SIZE - (size_t)fsz;
                while (rem > 0) {
                    size_t chunk = rem > sizeof(z) ? sizeof(z) : rem;
                    if (fwrite(z, 1, chunk, fp) != chunk) {
                        fclose(fp);
                        return 1;
                    }
                    rem -= chunk;
                }
            }
        }
    }

    uint32_t act_cnt = read_le32(hdr + 0x48);
    uint32_t tot_cnt = read_le32(hdr + 0x50);
    if (tot_cnt > RLF_MAX_RECS) tot_cnt = RLF_MAX_RECS;
    if (act_cnt > tot_cnt) act_cnt = tot_cnt;

    /* Update existing non-deleted entry with matching timestamp instead of duplicating */
    for (uint32_t i = 0; i < tot_cnt; i++) {
        uint8_t rec[8];
        if (fseeko(fp, (off_t)(RLF_HDR_SIZE + (size_t)i * 8U), SEEK_SET) != 0 ||
            fread(rec, 1, 8, fp) != 8) {
            fclose(fp);
            return 1;
        }
        if (read_le32(rec) == epoch_ts && rec[6] == 0) {
            rec[4] = (uint8_t)dur_sec;
            rec[5] = (uint8_t)event_type;
            if (fseeko(fp, (off_t)(RLF_HDR_SIZE + (size_t)i * 8U), SEEK_SET) != 0 ||
                fwrite(rec, 1, 8, fp) != 8) {
                fclose(fp);
                return 1;
            }
            fflush(fp);
            fsync(fileno(fp));
            fclose(fp);
            return 0;
        }
    }

    if (tot_cnt >= RLF_MAX_RECS) {
        fclose(fp);
        fprintf(stderr, "record_msg full\n");
        return 1;
    }

    uint8_t rec[8];
    write_le32(rec, epoch_ts);
    rec[4] = (uint8_t)dur_sec;
    rec[5] = (uint8_t)event_type;
    rec[6] = 0;
    rec[7] = 0;

    if (fseeko(fp, (off_t)(RLF_HDR_SIZE + (size_t)tot_cnt * 8U), SEEK_SET) != 0 ||
        fwrite(rec, 1, 8, fp) != 8) {
        fclose(fp);
        return 1;
    }

    tot_cnt++;
    act_cnt++;
    write_le32(hdr + 0x48, act_cnt);
    write_le32(hdr + 0x4C, RLF_HDR_SIZE + tot_cnt * 8U);
    write_le32(hdr + 0x50, tot_cnt);

    if (fseeko(fp, 0, SEEK_SET) != 0 || fwrite(hdr, 1, RLF_HDR_SIZE, fp) != RLF_HDR_SIZE) {
        fclose(fp);
        return 1;
    }
    fflush(fp);
    fsync(fileno(fp));
    fclose(fp);
    return 0;
}

/* ---------- 9. Live H.265 + G.711A MP4 recorder via LiteOS CPU1 shared DDR ---------- */

#define DDR_SHM_BASE      0x86E00000U
#define DDR_SHM_SIZE      0x00100000U
#define DDR_AUD_RING_OFF  0x00020000U
#define DDR_AUD_RING_MAX  0x0001FFFFU
#define DDR_VID_RING_OFF  0x00040000U
#define DDR_VID_RING_MAX  0x000AFFFFU
#define DDR_VID_IDX_OFF   0x000F1000U
#define DDR_AUD_IDX_OFF   0x000F2000U
#define DDR_CTRL_OFF      0x000FF000U
#define DDR_VID_SLOTS     30
#define DDR_AUD_SLOTS     200
#define DDR_VID_MAX_PKT   0x0003FC00U
#define DDR_AUD_MAX_PKT   0x00002000U

typedef struct {
    int32_t seq;
    int32_t size;
    int32_t type;
    uint32_t offset;
    uint32_t crc32;
} ddr_vid_slot_t;

typedef struct {
    int32_t seq;
    int32_t size;
    uint32_t ts;
    uint32_t offset;
} ddr_aud_slot_t;

typedef struct {
    uint32_t stco;
    uint32_t stsz;
    uint8_t is_key;
} mp4_sample_rec_t;

typedef struct {
    uint8_t *buf;
    size_t len;
    size_t cap;
} byte_vec_t;

static uint32_t crc32_ieee(const uint8_t *data, size_t len) {
    static uint32_t tab[256];
    static int inited = 0;
    if (!inited) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) {
                c = (c & 1U) ? ((c >> 1) ^ 0xEDB88320U) : (c >> 1);
            }
            tab[i] = c;
        }
        inited = 1;
    }
    uint32_t crc = 0xFFFFFFFFU;
    for (size_t i = 0; i < len; i++) {
        crc = tab[(crc ^ data[i]) & 0xFFU] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFU;
}

static void write_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v & 0xFFU);
}

static void write_be64(uint8_t *p, uint64_t v) {
    write_be32(p, (uint32_t)(v >> 32));
    write_be32(p + 4, (uint32_t)(v & 0xFFFFFFFFU));
}

static int bv_reserve(byte_vec_t *v, size_t add) {
    if (v->len + add <= v->cap) return 0;
    size_t ncap = v->cap ? v->cap : 4096U;
    while (ncap < v->len + add) ncap *= 2U;
    uint8_t *nb = (uint8_t *)realloc(v->buf, ncap);
    if (!nb) return -1;
    v->buf = nb;
    v->cap = ncap;
    return 0;
}

static int bv_append(byte_vec_t *v, const void *src, size_t n) {
    if (bv_reserve(v, n) != 0) return -1;
    if (n > 0) memcpy(v->buf + v->len, src, n);
    v->len += n;
    return 0;
}

static int bv_append_u16(byte_vec_t *v, uint16_t x) {
    uint8_t b[2];
    write_be16(b, x);
    return bv_append(v, b, 2);
}

static int bv_append_u32(byte_vec_t *v, uint32_t x) {
    uint8_t b[4];
    write_be32(b, x);
    return bv_append(v, b, 4);
}

static int bv_append_zeros(byte_vec_t *v, size_t n) {
    if (bv_reserve(v, n) != 0) return -1;
    memset(v->buf + v->len, 0, n);
    v->len += n;
    return 0;
}

static size_t bv_box_begin(byte_vec_t *v, const char *fourcc) {
    size_t off = v->len;
    bv_append_u32(v, 0);
    bv_append(v, fourcc, 4);
    return off;
}

static size_t bv_fullbox_begin(byte_vec_t *v, const char *fourcc, uint8_t ver, uint32_t flags) {
    size_t off = bv_box_begin(v, fourcc);
    bv_append_u32(v, ((uint32_t)ver << 24) | (flags & 0xFFFFFFU));
    return off;
}

static void bv_box_end(byte_vec_t *v, size_t off) {
    write_be32(v->buf + off, (uint32_t)(v->len - off));
}

typedef struct {
    const uint8_t *data;
    size_t bitlen;
    size_t pos;
} bit_reader_t;

static uint32_t br_bits(bit_reader_t *br, int n) {
    uint32_t val = 0;
    for (int i = 0; i < n; i++) {
        uint32_t b = 0;
        if (br->pos < br->bitlen) {
            b = (br->data[br->pos >> 3] >> (7U - (br->pos & 7U))) & 1U;
            br->pos++;
        }
        val = (val << 1) | b;
    }
    return val;
}

static uint32_t br_ue(bit_reader_t *br) {
    int lz = 0;
    while (br->pos < br->bitlen && lz < 30) {
        if (br_bits(br, 1) != 0) break;
        lz++;
    }
    if (lz == 0) return 0;
    return ((1U << lz) - 1U) + br_bits(br, lz);
}

static void parse_hevc_sps(const uint8_t *sps, size_t sps_len,
                           uint32_t *out_w, uint32_t *out_h,
                           uint8_t out_ptl[12], uint8_t *out_chroma,
                           uint8_t *out_luma_m8, uint8_t *out_chroma_m8) {
    if (sps_len < 16) return;
    uint8_t rbsp[512];
    size_t rlen = 0;
    for (size_t i = 2; i < sps_len && rlen < sizeof(rbsp); i++) {
        if (i + 2 < sps_len && sps[i] == 0x00 && sps[i + 1] == 0x00 && sps[i + 2] == 0x03) {
            if (rlen < sizeof(rbsp)) rbsp[rlen++] = 0x00;
            if (rlen < sizeof(rbsp)) rbsp[rlen++] = 0x00;
            i += 2;
        } else {
            rbsp[rlen++] = sps[i];
        }
    }
    if (rlen < 16) return;
    memcpy(out_ptl, rbsp + 1, 12);

    bit_reader_t br = { rbsp, rlen * 8U, 0 };
    (void)br_bits(&br, 4);
    uint32_t max_sub = br_bits(&br, 3);
    (void)br_bits(&br, 1);
    br.pos += 96;
    uint8_t sub_prof[8] = {0}, sub_lvl[8] = {0};
    if (max_sub > 6) return;
    for (uint32_t i = 0; i < max_sub; i++) {
        sub_prof[i] = (uint8_t)br_bits(&br, 1);
        sub_lvl[i]  = (uint8_t)br_bits(&br, 1);
    }
    if (max_sub > 0) {
        for (uint32_t i = max_sub; i < 8; i++) (void)br_bits(&br, 2);
    }
    for (uint32_t i = 0; i < max_sub; i++) {
        if (sub_prof[i]) br.pos += 88;
        if (sub_lvl[i])  br.pos += 8;
    }
    (void)br_ue(&br);
    uint32_t chroma = br_ue(&br);
    if (chroma == 3) (void)br_bits(&br, 1);
    uint32_t w = br_ue(&br);
    uint32_t h = br_ue(&br);
    uint32_t conf = br_bits(&br, 1);
    if (conf) {
        uint32_t cl = br_ue(&br), cr = br_ue(&br), ct = br_ue(&br), cb = br_ue(&br);
        uint32_t sx = (chroma == 1 || chroma == 2) ? 2U : 1U;
        uint32_t sy = (chroma == 1) ? 2U : 1U;
        if ((cl + cr) * sx < w) w -= (cl + cr) * sx;
        if ((ct + cb) * sy < h) h -= (ct + cb) * sy;
    }
    uint32_t lm8 = br_ue(&br);
    uint32_t cm8 = br_ue(&br);
    if (w >= 160 && w <= 4096 && h >= 120 && h <= 4096) {
        *out_w = w;
        *out_h = h;
    }
    if (chroma <= 3) *out_chroma = (uint8_t)chroma;
    if (lm8 <= 6)    *out_luma_m8 = (uint8_t)lm8;
    if (cm8 <= 6)    *out_chroma_m8 = (uint8_t)cm8;
}

typedef struct {
    uint8_t vps[256];
    size_t vps_len;
    uint8_t sps[512];
    size_t sps_len;
    uint8_t pps[256];
    size_t pps_len;
    uint32_t width;
    uint32_t height;
    uint8_t ptl[12];
    uint8_t chroma;
    uint8_t luma_m8;
    uint8_t chroma_m8;
} hevc_cfg_t;

static size_t annexb_to_hvcc(const uint8_t *src, size_t len, uint8_t *dst, size_t dst_cap, hevc_cfg_t *cfg) {
    size_t out_len = 0;
    size_t i = 0;
    while (i + 3 <= len) {
        size_t sc_len = 0;
        while (i + 3 <= len) {
            if (i + 4 <= len && src[i] == 0 && src[i + 1] == 0 && src[i + 2] == 0 && src[i + 3] == 1) {
                sc_len = 4;
                break;
            }
            if (src[i] == 0 && src[i + 1] == 0 && src[i + 2] == 1) {
                sc_len = 3;
                break;
            }
            i++;
        }
        if (sc_len == 0) break;
        size_t nal_start = i + sc_len;
        size_t j = nal_start;
        while (j + 3 <= len) {
            if (j + 4 <= len && src[j] == 0 && src[j + 1] == 0 && src[j + 2] == 0 && src[j + 3] == 1) break;
            if (src[j] == 0 && src[j + 1] == 0 && src[j + 2] == 1) break;
            j++;
        }
        if (j + 3 > len) j = len;
        size_t nal_len = j - nal_start;
        if (nal_len >= 2) {
            uint8_t ntype = (uint8_t)((src[nal_start] >> 1) & 0x3FU);
            if (ntype == 32 && cfg->vps_len == 0 && nal_len <= sizeof(cfg->vps)) {
                memcpy(cfg->vps, src + nal_start, nal_len);
                cfg->vps_len = nal_len;
            } else if (ntype == 33 && cfg->sps_len == 0 && nal_len <= sizeof(cfg->sps)) {
                memcpy(cfg->sps, src + nal_start, nal_len);
                cfg->sps_len = nal_len;
                parse_hevc_sps(cfg->sps, cfg->sps_len, &cfg->width, &cfg->height,
                               cfg->ptl, &cfg->chroma, &cfg->luma_m8, &cfg->chroma_m8);
            } else if (ntype == 34 && cfg->pps_len == 0 && nal_len <= sizeof(cfg->pps)) {
                memcpy(cfg->pps, src + nal_start, nal_len);
                cfg->pps_len = nal_len;
            }
            if (out_len + 4 + nal_len <= dst_cap) {
                write_be32(dst + out_len, (uint32_t)nal_len);
                memcpy(dst + out_len + 4, src + nal_start, nal_len);
                out_len += 4 + nal_len;
            }
        }
        i = j;
    }
    return out_len;
}

static int read_vid_slot_safe(const volatile uint8_t *vid_idx, int slot_idx,
                              const volatile uint8_t *vid_ring,
                              ddr_vid_slot_t *out_hdr, uint8_t *out_buf) {
    const volatile ddr_vid_slot_t *s = ((const volatile ddr_vid_slot_t *)vid_idx) + slot_idx;
    ddr_vid_slot_t h1;
    h1.seq    = s->seq;
    h1.size   = s->size;
    h1.type   = s->type;
    h1.offset = s->offset;
    h1.crc32  = s->crc32;
    __asm__ volatile("" ::: "memory");
    if (h1.size <= 0 || (uint32_t)h1.size >= DDR_VID_MAX_PKT || h1.offset > DDR_VID_RING_MAX ||
        h1.offset + (uint32_t)h1.size > DDR_VID_RING_MAX) {
        return -1;
    }
    memcpy(out_buf, (const void *)(vid_ring + h1.offset), (size_t)h1.size);
    __asm__ volatile("" ::: "memory");
    if (s->seq != h1.seq || s->offset != h1.offset || s->size != h1.size) return -1;
    if (crc32_ieee(out_buf, (size_t)h1.size) != h1.crc32) return -1;
    *out_hdr = h1;
    return 0;
}

static int read_aud_slot_safe(const volatile uint8_t *aud_idx, int slot_idx,
                              const volatile uint8_t *aud_ring,
                              ddr_aud_slot_t *out_hdr, uint8_t *out_buf) {
    const volatile ddr_aud_slot_t *s = ((const volatile ddr_aud_slot_t *)aud_idx) + slot_idx;
    ddr_aud_slot_t h1;
    h1.seq    = s->seq;
    h1.size   = s->size;
    h1.ts     = s->ts;
    h1.offset = s->offset;
    __asm__ volatile("" ::: "memory");
    if (h1.size <= 0 || (uint32_t)h1.size >= DDR_AUD_MAX_PKT || h1.offset > DDR_AUD_RING_MAX ||
        h1.offset + (uint32_t)h1.size > DDR_AUD_RING_MAX) {
        return -1;
    }
    memcpy(out_buf, (const void *)(aud_ring + h1.offset), (size_t)h1.size);
    __asm__ volatile("" ::: "memory");
    if (s->seq != h1.seq || s->offset != h1.offset || s->size != h1.size) return -1;
    *out_hdr = h1;
    return 0;
}

static int write_himp4_sample(FILE *fp, uint64_t *file_pos, uint32_t track_id,
                              uint32_t is_key, uint64_t dur_us,
                              const uint8_t *payload, uint32_t plen, uint32_t *out_stco) {
    uint8_t h[20];
    write_be32(h + 0, track_id);
    write_be32(h + 4, is_key);
    write_be64(h + 8, dur_us);
    write_be32(h + 16, plen);
    if (fwrite(h, 1, 20, fp) != 20) return -1;
    if (fwrite(payload, 1, plen, fp) != plen) return -1;
    *out_stco = (uint32_t)(*file_pos + 20ULL);
    *file_pos += 20ULL + (uint64_t)plen;
    return 0;
}

static void bv_append_dinf(byte_vec_t *v) {
    size_t dinf = bv_box_begin(v, "dinf");
    size_t dref = bv_fullbox_begin(v, "dref", 0, 0);
    bv_append_u32(v, 1);
    size_t url = bv_fullbox_begin(v, "url ", 0, 1);
    bv_box_end(v, url);
    bv_box_end(v, dref);
    bv_box_end(v, dinf);
}

static void bv_append_tkhd_matrix_identity(byte_vec_t *v) {
    bv_append_u32(v, 0x00010000U); bv_append_u32(v, 0); bv_append_u32(v, 0);
    bv_append_u32(v, 0); bv_append_u32(v, 0x00010000U); bv_append_u32(v, 0);
    bv_append_u32(v, 0); bv_append_u32(v, 0); bv_append_u32(v, 0x40000000U);
}

static void bv_append_hdlr(byte_vec_t *v, const char *subtype, const char *name_pstr) {
    size_t hdlr = bv_fullbox_begin(v, "hdlr", 0, 0);
    bv_append(v, "mhlr", 4);
    bv_append(v, subtype, 4);
    bv_append_zeros(v, 12);
    size_t slen = strlen(name_pstr);
    uint8_t plen = (uint8_t)(slen & 0xFFU);
    bv_append(v, &plen, 1);
    bv_append(v, name_pstr, slen);
    bv_box_end(v, hdlr);
}

static void build_moov(byte_vec_t *mv, uint32_t mp4_time,
                       const hevc_cfg_t *cfg,
                       const mp4_sample_rec_t *vsamps, uint32_t vcnt, uint32_t v_frame_ticks,
                       const mp4_sample_rec_t *asamps, uint32_t acnt, uint32_t a_total_samples) {
    uint64_t v_total_ticks = (uint64_t)vcnt * (uint64_t)v_frame_ticks;
    uint32_t mvhd_ts = 120000U;
    uint64_t a_dur_in_mvhd = acnt ? ((uint64_t)a_total_samples * (uint64_t)mvhd_ts) / 8000ULL : 0ULL;
    uint32_t mvhd_dur = (uint32_t)(v_total_ticks > a_dur_in_mvhd ? v_total_ticks : a_dur_in_mvhd);
    if (mvhd_dur == 0) mvhd_dur = 120000U;

    size_t moov = bv_box_begin(mv, "moov");

    /* mvhd */
    size_t mvhd = bv_fullbox_begin(mv, "mvhd", 0, 0);
    bv_append_u32(mv, mp4_time);
    bv_append_u32(mv, mp4_time);
    bv_append_u32(mv, mvhd_ts);
    bv_append_u32(mv, mvhd_dur);
    bv_append_u32(mv, 0x00010000U);
    bv_append_u16(mv, 0x0100U);
    bv_append_zeros(mv, 10);
    bv_append_tkhd_matrix_identity(mv);
    bv_append_zeros(mv, 24);
    bv_append_u32(mv, acnt > 0 ? 3U : 2U);
    bv_box_end(mv, mvhd);

    /* Video trak (ID = 1, unrotated so copy_mp4_finish.sh sets CAM_ROTATE once) */
    size_t vtrak = bv_box_begin(mv, "trak");
    size_t vtkhd = bv_fullbox_begin(mv, "tkhd", 0, 3);
    bv_append_u32(mv, mp4_time);
    bv_append_u32(mv, mp4_time);
    bv_append_u32(mv, 1);
    bv_append_u32(mv, 0);
    bv_append_u32(mv, (uint32_t)v_total_ticks);
    bv_append_zeros(mv, 8);
    bv_append_u16(mv, 0);
    bv_append_u16(mv, 0);
    bv_append_u16(mv, 0);
    bv_append_u16(mv, 0);
    bv_append_tkhd_matrix_identity(mv);
    bv_append_u32(mv, cfg->width << 16);
    bv_append_u32(mv, cfg->height << 16);
    bv_box_end(mv, vtkhd);

    size_t vedts = bv_box_begin(mv, "edts");
    size_t velst = bv_fullbox_begin(mv, "elst", 0, 0);
    bv_append_u32(mv, 1);
    bv_append_u32(mv, (uint32_t)v_total_ticks);
    bv_append_u32(mv, 0);
    bv_append_u32(mv, 0x00010000U);
    bv_box_end(mv, velst);
    bv_box_end(mv, vedts);

    size_t vmdia = bv_box_begin(mv, "mdia");
    size_t vmdhd = bv_fullbox_begin(mv, "mdhd", 0, 0);
    bv_append_u32(mv, mp4_time);
    bv_append_u32(mv, mp4_time);
    bv_append_u32(mv, 120000U);
    bv_append_u32(mv, (uint32_t)v_total_ticks);
    bv_append_u16(mv, 0x55C4U);
    bv_append_u16(mv, 0);
    bv_box_end(mv, vmdhd);

    bv_append_hdlr(mv, "vide", "Hisilicon VIDEO");

    size_t vminf = bv_box_begin(mv, "minf");
    size_t vmhd = bv_fullbox_begin(mv, "vmhd", 0, 1);
    bv_append_zeros(mv, 8);
    bv_box_end(mv, vmhd);
    bv_append_dinf(mv);

    size_t vstbl = bv_box_begin(mv, "stbl");
    size_t vstsd = bv_fullbox_begin(mv, "stsd", 0, 0);
    bv_append_u32(mv, 1);
    size_t hvc1 = bv_box_begin(mv, "hvc1");
    bv_append_zeros(mv, 6);
    bv_append_u16(mv, 1);
    bv_append_zeros(mv, 16);
    bv_append_u16(mv, (uint16_t)cfg->width);
    bv_append_u16(mv, (uint16_t)cfg->height);
    bv_append_u32(mv, 0x00480000U);
    bv_append_u32(mv, 0x00480000U);
    bv_append_u32(mv, 0);
    bv_append_u16(mv, 1);
    bv_append_zeros(mv, 32);
    bv_append_u16(mv, 0x0018U);
    bv_append_u16(mv, 0xFFFFU);

    size_t hvcc = bv_box_begin(mv, "hvcC");
    uint8_t hcfg[23];
    hcfg[0] = 0x01;
    memcpy(hcfg + 1, cfg->ptl, 12);
    hcfg[13] = 0xF0; hcfg[14] = 0x00;
    hcfg[15] = 0xFC;
    hcfg[16] = (uint8_t)(0xFCU | (cfg->chroma & 0x03U));
    hcfg[17] = (uint8_t)(0xF8U | (cfg->luma_m8 & 0x07U));
    hcfg[18] = (uint8_t)(0xF8U | (cfg->chroma_m8 & 0x07U));
    hcfg[19] = 0x00; hcfg[20] = 0x00;
    hcfg[21] = 0x0F;
    hcfg[22] = 3;
    bv_append(mv, hcfg, sizeof(hcfg));
    const uint8_t *nals[3] = { cfg->vps, cfg->sps, cfg->pps };
    size_t nlens[3] = { cfg->vps_len, cfg->sps_len, cfg->pps_len };
    uint8_t ntypes[3] = { 32, 33, 34 };
    for (int k = 0; k < 3; k++) {
        uint8_t ah = (uint8_t)(0x80U | ntypes[k]);
        bv_append(mv, &ah, 1);
        bv_append_u16(mv, 1);
        bv_append_u16(mv, (uint16_t)nlens[k]);
        bv_append(mv, nals[k], nlens[k]);
    }
    bv_box_end(mv, hvcc);
    bv_box_end(mv, hvc1);
    bv_box_end(mv, vstsd);

    size_t vstts = bv_fullbox_begin(mv, "stts", 0, 0);
    bv_append_u32(mv, 1);
    bv_append_u32(mv, vcnt);
    bv_append_u32(mv, v_frame_ticks);
    bv_box_end(mv, vstts);

    size_t vstsc = bv_fullbox_begin(mv, "stsc", 0, 0);
    bv_append_u32(mv, 1);
    bv_append_u32(mv, 1);
    bv_append_u32(mv, 1);
    bv_append_u32(mv, 1);
    bv_box_end(mv, vstsc);

    size_t vstsz = bv_fullbox_begin(mv, "stsz", 0, 0);
    bv_append_u32(mv, 0);
    bv_append_u32(mv, vcnt);
    for (uint32_t i = 0; i < vcnt; i++) bv_append_u32(mv, vsamps[i].stsz);
    bv_box_end(mv, vstsz);

    size_t vstco = bv_fullbox_begin(mv, "stco", 0, 0);
    bv_append_u32(mv, vcnt);
    for (uint32_t i = 0; i < vcnt; i++) bv_append_u32(mv, vsamps[i].stco);
    bv_box_end(mv, vstco);

    uint32_t key_cnt = 0;
    for (uint32_t i = 0; i < vcnt; i++) {
        if (vsamps[i].is_key) key_cnt++;
    }
    if (key_cnt > 0) {
        size_t vstss = bv_fullbox_begin(mv, "stss", 0, 0);
        bv_append_u32(mv, key_cnt);
        for (uint32_t i = 0; i < vcnt; i++) {
            if (vsamps[i].is_key) bv_append_u32(mv, i + 1U);
        }
        bv_box_end(mv, vstss);
    }

    bv_box_end(mv, vstbl);
    bv_box_end(mv, vminf);
    bv_box_end(mv, vmdia);
    bv_box_end(mv, vtrak);

    /* Audio trak (ID = 2, G.711 A-law 8000 Hz mono) */
    if (acnt > 0) {
        size_t atrak = bv_box_begin(mv, "trak");
        size_t atkhd = bv_fullbox_begin(mv, "tkhd", 0, 3);
        bv_append_u32(mv, mp4_time);
        bv_append_u32(mv, mp4_time);
        bv_append_u32(mv, 2);
        bv_append_u32(mv, 0);
        bv_append_u32(mv, (uint32_t)a_dur_in_mvhd);
        bv_append_zeros(mv, 8);
        bv_append_u16(mv, 0);
        bv_append_u16(mv, 0);
        bv_append_u16(mv, 0x0100U);
        bv_append_u16(mv, 0);
        bv_append_tkhd_matrix_identity(mv);
        bv_append_u32(mv, 0);
        bv_append_u32(mv, 0);
        bv_box_end(mv, atkhd);

        size_t aedts = bv_box_begin(mv, "edts");
        size_t aelst = bv_fullbox_begin(mv, "elst", 0, 0);
        bv_append_u32(mv, 1);
        bv_append_u32(mv, (uint32_t)a_dur_in_mvhd);
        bv_append_u32(mv, 0);
        bv_append_u32(mv, 0x00010000U);
        bv_box_end(mv, aelst);
        bv_box_end(mv, aedts);

        size_t amdia = bv_box_begin(mv, "mdia");
        size_t amdhd = bv_fullbox_begin(mv, "mdhd", 0, 0);
        bv_append_u32(mv, mp4_time);
        bv_append_u32(mv, mp4_time);
        bv_append_u32(mv, 8000U);
        bv_append_u32(mv, a_total_samples);
        bv_append_u16(mv, 0x55C4U);
        bv_append_u16(mv, 0);
        bv_box_end(mv, amdhd);

        bv_append_hdlr(mv, "soun", "Hisilicon AUDIO");

        size_t aminf = bv_box_begin(mv, "minf");
        size_t smhd = bv_fullbox_begin(mv, "smhd", 0, 0);
        bv_append_u32(mv, 0);
        bv_box_end(mv, smhd);
        bv_append_dinf(mv);

        size_t astbl = bv_box_begin(mv, "stbl");
        static const uint8_t alaw_stsd[52] = {
            0x00,0x00,0x00,0x34,'s','t','s','d', 0,0,0,0, 0,0,0,1,
            0x00,0x00,0x00,0x24,'a','l','a','w', 0,0,0,0, 0,0, 0,1,
            0,0,0,0, 0,0,0,0, 0,1, 0,0x10, 0,0,0,0, 0x1F,0x40,0,0,
        };
        bv_append(mv, alaw_stsd, sizeof(alaw_stsd));

        /* RLE-encode audio stts if sample sizes vary, else 1 run of (acnt, a_first_sz) */
        size_t astts = bv_fullbox_begin(mv, "stts", 0, 0);
        size_t run_cnt_pos = mv->len;
        bv_append_u32(mv, 0);
        uint32_t r_cnt = 0;
        uint32_t i = 0;
        while (i < acnt) {
            uint32_t s = asamps[i].stsz;
            uint32_t c = 1;
            while (i + c < acnt && asamps[i + c].stsz == s) c++;
            bv_append_u32(mv, c);
            bv_append_u32(mv, s);
            r_cnt++;
            i += c;
        }
        write_be32(mv->buf + run_cnt_pos, r_cnt);
        bv_box_end(mv, astts);

        size_t astsc = bv_fullbox_begin(mv, "stsc", 0, 0);
        bv_append_u32(mv, 1);
        bv_append_u32(mv, 1);
        bv_append_u32(mv, 1);
        bv_append_u32(mv, 1);
        bv_box_end(mv, astsc);

        size_t astsz = bv_fullbox_begin(mv, "stsz", 0, 0);
        bv_append_u32(mv, 0);
        bv_append_u32(mv, acnt);
        for (uint32_t k = 0; k < acnt; k++) bv_append_u32(mv, asamps[k].stsz);
        bv_box_end(mv, astsz);

        size_t astco = bv_fullbox_begin(mv, "stco", 0, 0);
        bv_append_u32(mv, acnt);
        for (uint32_t k = 0; k < acnt; k++) bv_append_u32(mv, asamps[k].stco);
        bv_box_end(mv, astco);

        bv_box_end(mv, astbl);
        bv_box_end(mv, aminf);
        bv_box_end(mv, amdia);
        bv_box_end(mv, atrak);
    }

    bv_box_end(mv, moov);
}

static int32_t max_vid_ring_seq(const volatile uint8_t *vid_idx) {
    int32_t m = -1;
    for (int i = 0; i < DDR_VID_SLOTS; i++) {
        int32_t seq = (((const volatile ddr_vid_slot_t *)vid_idx) + i)->seq;
        if (seq > m) m = seq;
    }
    return m;
}

static void record_release_venc(volatile uint32_t *ctrl, uint32_t prev_live, int started_venc) {
    if (!started_venc) return;
    if (ctrl[4] == 0U) {
        ctrl[0] = 0xFFFF0400U;
        for (int i = 0; i < 500 && ctrl[0] != 0U; i++) usleep(1000);
    }
    ctrl[3] = (prev_live == 0xFF00F040U) ? prev_live : 0xFF00F050U;
}

static int cmd_record(const char *out_path, int dur_sec) {
    if (!out_path || !out_path[0]) return 1;
    if (dur_sec < 1) dur_sec = 10;
    if (dur_sec > 60) dur_sec = 60;

    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("open /dev/mem");
        return 1;
    }
    uint8_t *shm = (uint8_t *)mmap(NULL, DDR_SHM_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_SHARED, mem_fd, (off_t)DDR_SHM_BASE);
    if (shm == MAP_FAILED) {
        perror("mmap /dev/mem");
        close(mem_fd);
        return 1;
    }

    const volatile uint8_t *aud_ring = shm + DDR_AUD_RING_OFF;
    const volatile uint8_t *vid_ring = shm + DDR_VID_RING_OFF;
    const volatile uint8_t *vid_idx  = shm + DDR_VID_IDX_OFF;
    const volatile uint8_t *aud_idx  = shm + DDR_AUD_IDX_OFF;
    volatile uint32_t *ctrl          = (volatile uint32_t *)(shm + DDR_CTRL_OFF);

    uint32_t prev_live = ctrl[3];
    uint32_t dev_rec = ctrl[4];
    int started_venc = 0;
    int venc_active = (prev_live == 0xFF00F040U || dev_rec != 0U) ? 1 : 0;
    if (!venc_active) {
        int32_t seq0 = max_vid_ring_seq(vid_idx);
        for (int p = 0; p < 10; p++) {
            usleep(25000);
            if (max_vid_ring_seq(vid_idx) != seq0) {
                venc_active = 1;
                break;
            }
        }
    }
    if (!venc_active) {
        /* Idle: full VENC Chn0 + AENC re-arm in LiteOS (same request main_app uses for live). */
        ctrl[3] = 0xFF00F040U;
        __asm__ volatile("" ::: "memory");
        ctrl[0] = 0xFFFF0500U;
        for (int i = 0; i < 2000 && ctrl[0] != 0U; i++) usleep(1000);
        usleep(150000);
        started_venc = 1;
    }

    char tmp_path[512];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%d", out_path, (int)getpid());
    FILE *fp = fopen(tmp_path, "wb");
    if (!fp) {
        record_release_venc(ctrl, prev_live, started_venc);
        munmap(shm, DDR_SHM_SIZE);
        close(mem_fd);
        return 1;
    }

    static const uint8_t ftyp_box[24] = {
        0x00,0x00,0x00,0x18,'f','t','y','p','m','p','4','2',0,0,0,0,'m','p','4','2','i','s','o','m'
    };
    static const uint8_t hisi_tmpl[136] = {
        0x00,0x00,0x00,0x88,0x68,0x69,0x73,0x69,0x06,0x40,0x00,0x00,0x00,0x01,0x00,0x00,
        0x00,0x00,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x37,0x00,0x00,
        0x00,0x01,0x00,0x00,0x00,0x01,0x00,0x01,0xD4,0xC0,0x00,0x00,0x00,0x01,0x00,0x00,
        0x09,0x00,0x00,0x00,0x05,0x10,0x00,0x00,0x04,0x00,0x00,0x00,0x00,0x0C,0x00,0x00,
        0x80,0x3F,0x48,0x69,0x73,0x69,0x6C,0x69,0x63,0x6F,0x6E,0x20,0x56,0x49,0x44,0x45,
        0x4F,0x00,0x00,0x00,0x37,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x02,0x00,0x00,0x1F,
        0x40,0x00,0x00,0x00,0x0A,0x00,0x00,0x00,0x01,0x00,0x00,0x1F,0x40,0x00,0x00,0x00,
        0xA0,0x00,0x00,0x00,0x10,0x00,0x00,0x80,0x3F,0x48,0x69,0x73,0x69,0x6C,0x69,0x63,
        0x6F,0x6E,0x20,0x41,0x55,0x44,0x49,0x4F
    };
    uint8_t mdat_hdr[16] = { 0x00,0x00,0x00,0x01,'m','d','a','t', 0,0,0,0,0,0,0,0 };
    uint8_t hisi_box[136];
    memcpy(hisi_box, hisi_tmpl, sizeof(hisi_box));

    if (fwrite(ftyp_box, 1, sizeof(ftyp_box), fp) != sizeof(ftyp_box) ||
        fwrite(mdat_hdr, 1, sizeof(mdat_hdr), fp) != sizeof(mdat_hdr) ||
        fwrite(hisi_box, 1, sizeof(hisi_box), fp) != sizeof(hisi_box)) {
        fclose(fp);
        unlink(tmp_path);
        record_release_venc(ctrl, prev_live, started_venc);
        munmap(shm, DDR_SHM_SIZE);
        close(mem_fd);
        return 1;
    }

    uint64_t file_pos = sizeof(ftyp_box) + sizeof(mdat_hdr) + sizeof(hisi_box);
    uint8_t *pkt_buf = (uint8_t *)malloc(DDR_VID_MAX_PKT);
    uint8_t *hvcc_buf = (uint8_t *)malloc(DDR_VID_MAX_PKT + 1024U);
    uint8_t *aud_buf = (uint8_t *)malloc(DDR_AUD_MAX_PKT);
    uint32_t vcap = 2048U, vcnt = 0;
    uint32_t acap = 4096U, acnt = 0;
    mp4_sample_rec_t *vsamps = (mp4_sample_rec_t *)malloc(vcap * sizeof(mp4_sample_rec_t));
    mp4_sample_rec_t *asamps = (mp4_sample_rec_t *)malloc(acap * sizeof(mp4_sample_rec_t));

    if (!pkt_buf || !hvcc_buf || !aud_buf || !vsamps || !asamps) {
        free(pkt_buf); free(hvcc_buf); free(aud_buf); free(vsamps); free(asamps);
        fclose(fp);
        unlink(tmp_path);
        record_release_venc(ctrl, prev_live, started_venc);
        munmap(shm, DDR_SHM_SIZE);
        close(mem_fd);
        return 1;
    }

    hevc_cfg_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.width = 1920;
    cfg.height = 1080;
    cfg.chroma = 1;

    int32_t last_vid_seq = -1;
    int32_t last_aud_seq = -1;
    int32_t retry_vseq = -1;
    int retry_vcnt = 0;
    int32_t retry_aseq = -1;
    int retry_acnt = 0;
    uint32_t a_total_samples = 0;
    int got_first_key = 0;
    int write_err = 0;
    int64_t t_wait_end = now_ms() + 4500;
    int64_t t_last_idr = now_ms();
    int64_t t_start = 0, t_end = 0;

    while (!write_err) {
        int64_t now = now_ms();
        if (!got_first_key) {
            if (now >= t_wait_end) break;
            /* Only request IDR if we started VENC and no keyframe arrived within 1500ms;
             * 0xFFFF0100 clears vid_idx (600B) via 0x74b1c, so never spam it every 400ms! */
            if (started_venc && now - t_last_idr >= 1500) {
                ctrl[0] = 0xFFFF0100U;
                t_last_idr = now;
            }
            int best_slot = -1;
            int32_t best_seq = -1;
            ddr_vid_slot_t best_hdr;
            for (int i = 0; i < DDR_VID_SLOTS; i++) {
                const volatile ddr_vid_slot_t *s = ((const volatile ddr_vid_slot_t *)vid_idx) + i;
                int32_t seq = s->seq;
                int32_t type = s->type;
                if (type == 0 && seq > best_seq) {
                    ddr_vid_slot_t tmp_h;
                    if (read_vid_slot_safe(vid_idx, i, vid_ring, &tmp_h, pkt_buf) == 0 && tmp_h.type == 0) {
                        best_seq = tmp_h.seq;
                        best_hdr = tmp_h;
                        best_slot = i;
                    }
                }
            }
            if (best_slot >= 0 && read_vid_slot_safe(vid_idx, best_slot, vid_ring, &best_hdr, pkt_buf) == 0) {
                size_t hlen = annexb_to_hvcc(pkt_buf, (size_t)best_hdr.size, hvcc_buf, DDR_VID_MAX_PKT + 1024U, &cfg);
                if (hlen > 0 && cfg.sps_len > 0 && cfg.pps_len > 0 && cfg.vps_len > 0) {
                    uint32_t stco = 0;
                    if (write_himp4_sample(fp, &file_pos, 1U, 1U, 0ULL, hvcc_buf, (uint32_t)hlen, &stco) != 0) {
                        write_err = 1;
                        break;
                    }
                    vsamps[vcnt].stco = stco;
                    vsamps[vcnt].stsz = (uint32_t)hlen;
                    vsamps[vcnt].is_key = 1U;
                    vcnt++;
                    last_vid_seq = best_hdr.seq;
                    /* Set audio baseline to newest current audio seq so audio aligns with keyframe */
                    for (int a = 0; a < DDR_AUD_SLOTS; a++) {
                        int32_t aseq = (((const volatile ddr_aud_slot_t *)aud_idx) + a)->seq;
                        if (aseq > last_aud_seq) last_aud_seq = aseq;
                    }
                    got_first_key = 1;
                    t_start = now_ms();
                    t_end = t_start + (int64_t)dur_sec * 1000LL;
                }
            }
        } else {
            /* Drain video frames in ascending seq order */
            for (;;) {
                int min_slot = -1;
                int32_t min_seq = 0x7FFFFFFF;
                for (int i = 0; i < DDR_VID_SLOTS; i++) {
                    int32_t seq = (((const volatile ddr_vid_slot_t *)vid_idx) + i)->seq;
                    if (seq > last_vid_seq && seq < min_seq) {
                        min_seq = seq;
                        min_slot = i;
                    }
                }
                if (min_slot < 0) break;
                ddr_vid_slot_t vh;
                if (read_vid_slot_safe(vid_idx, min_slot, vid_ring, &vh, pkt_buf) == 0) {
                    size_t hlen = annexb_to_hvcc(pkt_buf, (size_t)vh.size, hvcc_buf, DDR_VID_MAX_PKT + 1024U, &cfg);
                    if (hlen > 0) {
                        if (vcnt == vcap) {
                            vcap *= 2U;
                            mp4_sample_rec_t *nv = (mp4_sample_rec_t *)realloc(vsamps, vcap * sizeof(mp4_sample_rec_t));
                            if (!nv) { write_err = 1; break; }
                            vsamps = nv;
                        }
                        uint32_t stco = 0;
                        uint32_t is_key = (vh.type == 0) ? 1U : 0U;
                        if (write_himp4_sample(fp, &file_pos, 1U, is_key, 0ULL, hvcc_buf, (uint32_t)hlen, &stco) != 0) {
                            write_err = 1;
                            break;
                        }
                        vsamps[vcnt].stco = stco;
                        vsamps[vcnt].stsz = (uint32_t)hlen;
                        vsamps[vcnt].is_key = (uint8_t)is_key;
                        vcnt++;
                    }
                    last_vid_seq = vh.seq;
                    retry_vseq = -1;
                    retry_vcnt = 0;
                } else {
                    if (min_seq == retry_vseq) {
                        if (++retry_vcnt >= 6) {
                            last_vid_seq = min_seq;
                            retry_vseq = -1;
                            retry_vcnt = 0;
                        } else {
                            break;
                        }
                    } else {
                        retry_vseq = min_seq;
                        retry_vcnt = 1;
                        break;
                    }
                }
            }

            /* Drain audio frames in ascending seq order */
            for (;;) {
                int min_slot = -1;
                int32_t min_seq = 0x7FFFFFFF;
                for (int i = 0; i < DDR_AUD_SLOTS; i++) {
                    int32_t seq = (((const volatile ddr_aud_slot_t *)aud_idx) + i)->seq;
                    if (seq > last_aud_seq && seq < min_seq) {
                        min_seq = seq;
                        min_slot = i;
                    }
                }
                if (min_slot < 0) break;
                ddr_aud_slot_t ah;
                if (read_aud_slot_safe(aud_idx, min_slot, aud_ring, &ah, aud_buf) == 0) {
                    const uint8_t *ap = aud_buf;
                    uint32_t alen = (uint32_t)ah.size;
                    if (alen >= 4U && ap[0] == 0x00 && ap[1] == 0x01 &&
                        (ap[2] == 0x50 || alen == (uint32_t)(ap[2] * 2U + 4U)) && ap[3] == 0x00) {
                        ap += 4;
                        alen -= 4U;
                    }
                    if (alen > 0U && alen <= 2048U) {
                        if (acnt == acap) {
                            acap *= 2U;
                            mp4_sample_rec_t *na = (mp4_sample_rec_t *)realloc(asamps, acap * sizeof(mp4_sample_rec_t));
                            if (!na) { write_err = 1; break; }
                            asamps = na;
                        }
                        uint32_t stco = 0;
                        uint64_t adur_us = ((uint64_t)alen * 1000000ULL) / 8000ULL;
                        if (write_himp4_sample(fp, &file_pos, 2U, 1U, adur_us, ap, alen, &stco) != 0) {
                            write_err = 1;
                            break;
                        }
                        asamps[acnt].stco = stco;
                        asamps[acnt].stsz = alen;
                        asamps[acnt].is_key = 1U;
                        acnt++;
                        a_total_samples += alen;
                    }
                    last_aud_seq = ah.seq;
                    retry_aseq = -1;
                    retry_acnt = 0;
                } else {
                    if (min_seq == retry_aseq) {
                        if (++retry_acnt >= 6) {
                            last_aud_seq = min_seq;
                            retry_aseq = -1;
                            retry_acnt = 0;
                        } else {
                            break;
                        }
                    } else {
                        retry_aseq = min_seq;
                        retry_acnt = 1;
                        break;
                    }
                }
            }

            if (now_ms() >= t_end) break;
        }
        usleep(8000);
    }

    int64_t elapsed_ms = got_first_key ? (now_ms() - t_start) : 0;
    record_release_venc(ctrl, prev_live, started_venc);
    munmap(shm, DDR_SHM_SIZE);
    close(mem_fd);

    if (write_err || !got_first_key || vcnt < 5U || cfg.vps_len == 0 || cfg.sps_len == 0 || cfg.pps_len == 0) {
        fprintf(stderr, "record failed: got_key=%d vcnt=%u acnt=%u started_venc=%d err=%d\n",
                got_first_key, vcnt, acnt, started_venc, write_err);
        free(pkt_buf); free(hvcc_buf); free(aud_buf); free(vsamps); free(asamps);
        fclose(fp);
        unlink(tmp_path);
        return 1;
    }

    if (elapsed_ms < 500) elapsed_ms = (int64_t)dur_sec * 1000LL;
    uint32_t v_frame_ticks = (uint32_t)(((uint64_t)elapsed_ms * 120ULL + vcnt / 2U) / vcnt);
    if (v_frame_ticks < 4000U)  v_frame_ticks = 4000U;
    if (v_frame_ticks > 24000U) v_frame_ticks = 24000U;

    /* Finalize 64-bit mdat size (file_pos - 24) and hisi video width/height */
    uint8_t sz64[8], wh8[8];
    write_be64(sz64, file_pos - 24ULL);
    write_be32(wh8 + 0, cfg.width);
    write_be32(wh8 + 4, cfg.height);
    if (fseeko(fp, 32, SEEK_SET) != 0 || fwrite(sz64, 1, 8, fp) != 8 ||
        fseeko(fp, 86, SEEK_SET) != 0 || fwrite(wh8, 1, 8, fp) != 8 ||
        fseeko(fp, (off_t)file_pos, SEEK_SET) != 0) {
        free(pkt_buf); free(hvcc_buf); free(aud_buf); free(vsamps); free(asamps);
        fclose(fp);
        unlink(tmp_path);
        return 1;
    }

    uint32_t mp4_time = (uint32_t)time(NULL) + 2082844800U;
    byte_vec_t moov;
    memset(&moov, 0, sizeof(moov));
    build_moov(&moov, mp4_time, &cfg, vsamps, vcnt, v_frame_ticks, asamps, acnt, a_total_samples);

    int ok = (moov.len > 0 && fwrite(moov.buf, 1, moov.len, fp) == moov.len) ? 0 : -1;
    free(moov.buf);
    free(pkt_buf); free(hvcc_buf); free(aud_buf); free(vsamps); free(asamps);

    fflush(fp);
    fsync(fileno(fp));
    fclose(fp);
    if (ok != 0 || rename(tmp_path, out_path) != 0) {
        unlink(tmp_path);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "Usage:\n"
                "  %s mp4rot       <file.mp4> <0|90|180|270>\n"
                "  %s jpgrot       <in.jpg> <out.jpg> <0|90|180|270> [quality=85]\n"
                "  %s jpgscale     <in.jpg> <out.jpg> <w> <h> [quality=80]\n"
                "  %s snap         <out.jpg> [0|90|180|270] [timeout_ms=3000]\n"
                "  %s record       <out.mp4> [dur_sec=10]\n"
                "  %s rlf_add      <record_msg_path> <epoch_ts> <dur_sec> [event_type=1]\n"
                "  %s udpwake      <ip> <port> [payload=WAKEUP] [count=3]\n"
                "  %s udplisten    <port> <key> <hook_cmd>\n"
                "  %s mqttpub      <host> <port> <topic> <payload> [user] [pass] [retain=0|1]\n"
                "  %s mqttpub_file <host> <port> <topic> <file> [user] [pass] [retain=0|1]\n"
                "  %s stdin2file   <out_file> <byte_len>\n"
                "  %s ogg2alaw     <in.oga|in.wav> <out.alaw>\n",
                argv[0], argv[0], argv[0], argv[0], argv[0], argv[0], argv[0], argv[0], argv[0], argv[0], argv[0], argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "mp4rot") == 0 && argc >= 4) {
        return cmd_mp4rot(argv[2], atoi(argv[3]));
    } else if (strcmp(argv[1], "jpgrot") == 0 && argc >= 5) {
        int q = argc >= 6 ? atoi(argv[5]) : 85;
        return cmd_jpgrot(argv[2], argv[3], atoi(argv[4]), q);
    } else if (strcmp(argv[1], "jpgscale") == 0 && argc >= 6) {
        int q = argc >= 7 ? atoi(argv[6]) : 80;
        return cmd_jpgscale(argv[2], argv[3], atoi(argv[4]), atoi(argv[5]), q);
    } else if (strcmp(argv[1], "snap") == 0 && argc >= 3) {
        int deg = argc >= 4 ? atoi(argv[3]) : 0;
        int tms = argc >= 5 ? atoi(argv[4]) : 3000;
        return cmd_snap(argv[2], deg, tms);
    } else if (strcmp(argv[1], "record") == 0 && argc >= 3) {
        int dur = argc >= 4 ? atoi(argv[3]) : 10;
        return cmd_record(argv[2], dur);
    } else if (strcmp(argv[1], "rlf_add") == 0 && argc >= 5) {
        uint32_t ts = (uint32_t)strtoul(argv[3], NULL, 10);
        int dur = atoi(argv[4]);
        int ev = argc >= 6 ? atoi(argv[5]) : 1;
        return cmd_rlf_add(argv[2], ts, dur, ev);
    } else if (strcmp(argv[1], "udpwake") == 0 && argc >= 4) {
        const char *pl = argc >= 5 ? argv[4] : "WAKEUP";
        int cnt = argc >= 6 ? atoi(argv[5]) : 3;
        return cmd_udpwake(argv[2], atoi(argv[3]), pl, cnt);
    } else if (strcmp(argv[1], "udplisten") == 0 && argc >= 5) {
        return cmd_udplisten(atoi(argv[2]), argv[3], argv[4]);
    } else if (strcmp(argv[1], "mqttpub") == 0 && argc >= 6) {
        const char *u = argc >= 7 ? argv[6] : "";
        const char *p = argc >= 8 ? argv[7] : "";
        int ret = argc >= 9 ? atoi(argv[8]) : 0;
        return cmd_mqttpub(argv[2], atoi(argv[3]), argv[4], argv[5], u, p, ret);
    } else if (strcmp(argv[1], "mqttpub_file") == 0 && argc >= 6) {
        const char *u = argc >= 7 ? argv[6] : "";
        const char *p = argc >= 8 ? argv[7] : "";
        int ret = argc >= 9 ? atoi(argv[8]) : 0;
        return cmd_mqttpub_file(argv[2], atoi(argv[3]), argv[4], argv[5], u, p, ret);
    } else if (strcmp(argv[1], "stdin2file") == 0 && argc >= 4) {
        return cmd_stdin2file(argv[2], (size_t)atol(argv[3]));
    } else if (strcmp(argv[1], "ogg2alaw") == 0 && argc >= 4) {
        return cmd_ogg2alaw(argv[2], argv[3]);
    }

    fprintf(stderr, "Invalid arguments for %s\n", argv[1]);
    return 1;
}
