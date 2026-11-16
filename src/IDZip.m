/*
 * IDZip.m - a .zip archive of files and folders, as the desktop's Compress makes it.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import "IDDock.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// libcompression's stream API, which the SDK ships without its header; COMPRESSION_ZLIB is raw deflate
typedef struct {
    uint8_t *dst_ptr;
    size_t dst_size;
    const uint8_t *src_ptr;
    size_t src_size;
    void *state;
} id_compression_stream;
int compression_stream_init(id_compression_stream *stream, int operation, int algorithm);
int compression_stream_process(id_compression_stream *stream, int flags);
int compression_stream_destroy(id_compression_stream *stream);
#define ID_COMPRESSION_ZLIB 0x205
#define ID_STREAM_ENCODE 0
#define ID_STREAM_FINALIZE 1
#define ID_STATUS_OK 0
#define ID_STATUS_END 1

static uint32_t crcTable[256];

static void makeCrcTable(void)
{
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;

        for (int k = 0; k < 8; k++)
            c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crcTable[n] = c;
    }
}

static uint32_t crcUpdate(uint32_t crc, const uint8_t *p, size_t n)
{
    crc = ~crc;
    while (n--)
        crc = crcTable[(crc ^ *p++) & 0xff] ^ (crc >> 8);
    return ~crc;
}

static void put16(NSMutableData *d, uint32_t v)
{
    uint8_t b[2] = { v & 0xff, (v >> 8) & 0xff };
    [d appendBytes:b length:2];
}

static void put32(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = { v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff };
    [d appendBytes:b length:4];
}

static BOOL writeAll(FILE *f, NSData *d)
{
    return fwrite([d bytes], 1, [d length], f) == [d length];
}

// MS-DOS time and date, in local time, as zip readers show them
static void dosTime(time_t t, uint32_t *timeOut, uint32_t *dateOut)
{
    struct tm tm;

    localtime_r(&t, &tm);
    if (tm.tm_year < 80) {
        *timeOut = 0;
        *dateOut = (1 << 5) | 1;
        return;
    }
    *timeOut = (tm.tm_hour << 11) | (tm.tm_min << 5) | (tm.tm_sec / 2);
    *dateOut = ((tm.tm_year - 80) << 9) | ((tm.tm_mon + 1) << 5) | tm.tm_mday;
}

typedef struct {
    uint32_t crc, csize, usize, offset, time, date, mode;
    uint16_t method, flags;
} IDZipEntry;

// one local header with its data; a file's data is deflated and its sizes follow it in a data descriptor
static BOOL writeEntry(FILE *out, NSString *full, NSString *name, NSMutableData *central, uint32_t *count)
{
    struct stat st;
    IDZipEntry e = { 0 };
    NSMutableData *head = [NSMutableData data];
    const char *utf8;
    long offset = ftell(out);
    BOOL directory, link;

    if (lstat([full fileSystemRepresentation], &st) != 0 || offset < 0 || offset > 0xFFFFFFF0L)
        return NO;
    directory = S_ISDIR(st.st_mode);
    link = S_ISLNK(st.st_mode);
    if (!directory && !link && !S_ISREG(st.st_mode))
        return YES; // sockets, fifos and devices are left out, as the Archive Utility does
    if (directory)
        name = [name stringByAppendingString:@"/"];
    utf8 = [name UTF8String];
    e.offset = (uint32_t)offset;
    e.mode = st.st_mode;
    e.flags = 0x0800; // the name is UTF-8
    e.method = directory || link ? 0 : 8;
    if (e.method == 8)
        e.flags |= 0x0008; // the sizes come after the data
    dosTime(st.st_mtime, &e.time, &e.date);

    NSData *stored = nil;
    if (link) {
        char target[4096];
        ssize_t n = readlink([full fileSystemRepresentation], target, sizeof target);

        if (n < 0)
            return NO;
        stored = [NSData dataWithBytes:target length:(NSUInteger)n];
        e.crc = crcUpdate(0, (const uint8_t *)target, (size_t)n);
        e.csize = e.usize = (uint32_t)n;
    }

    put32(head, 0x04034b50);
    put16(head, 20);
    put16(head, e.flags);
    put16(head, e.method);
    put16(head, e.time);
    put16(head, e.date);
    put32(head, e.method == 8 ? 0 : e.crc);
    put32(head, e.method == 8 ? 0 : e.csize);
    put32(head, e.method == 8 ? 0 : e.usize);
    put16(head, (uint32_t)strlen(utf8));
    put16(head, 0);
    [head appendBytes:utf8 length:strlen(utf8)];
    if (!writeAll(out, head) || (stored != nil && !writeAll(out, stored)))
        return NO;

    if (e.method == 8) {
        FILE *in = fopen([full fileSystemRepresentation], "rb");
        id_compression_stream s;
        uint8_t src[65536], dst[65536];
        uint64_t usize = 0, csize = 0;
        int status = ID_STATUS_OK;
        BOOL eof = NO, ok = YES;

        if (in == NULL)
            return NO;
        if (compression_stream_init(&s, ID_STREAM_ENCODE, ID_COMPRESSION_ZLIB) != ID_STATUS_OK) {
            fclose(in);
            return NO;
        }
        s.src_size = 0;
        while (ok && status != ID_STATUS_END) {
            if (s.src_size == 0 && !eof) {
                size_t n = fread(src, 1, sizeof src, in);

                if (n < sizeof src) {
                    eof = YES;
                    ok = !ferror(in);
                }
                e.crc = crcUpdate(e.crc, src, n);
                usize += n;
                s.src_ptr = src;
                s.src_size = n;
            }
            s.dst_ptr = dst;
            s.dst_size = sizeof dst;
            status = compression_stream_process(&s, eof ? ID_STREAM_FINALIZE : 0);
            if (status != ID_STATUS_OK && status != ID_STATUS_END)
                ok = NO;
            if (ok && sizeof dst - s.dst_size > 0) {
                size_t n = sizeof dst - s.dst_size;

                ok = fwrite(dst, 1, n, out) == n;
                csize += n;
            }
        }
        compression_stream_destroy(&s);
        fclose(in);
        // no zip64: an archive this large is refused rather than written wrong
        if (!ok || usize > 0xFFFFFFF0ull || csize > 0xFFFFFFF0ull)
            return NO;
        e.usize = (uint32_t)usize;
        e.csize = (uint32_t)csize;

        NSMutableData *descriptor = [NSMutableData data];
        put32(descriptor, 0x08074b50);
        put32(descriptor, e.crc);
        put32(descriptor, e.csize);
        put32(descriptor, e.usize);
        if (!writeAll(out, descriptor))
            return NO;
    }

    put32(central, 0x02014b50);
    put16(central, (3 << 8) | 20); // made on Unix, so readers keep the mode
    put16(central, 20);
    put16(central, e.flags);
    put16(central, e.method);
    put16(central, e.time);
    put16(central, e.date);
    put32(central, e.crc);
    put32(central, e.csize);
    put32(central, e.usize);
    put16(central, (uint32_t)strlen(utf8));
    put16(central, 0);
    put16(central, 0);
    put16(central, 0);
    put16(central, 0);
    put32(central, (e.mode << 16) | (directory ? 0x10 : 0));
    put32(central, e.offset);
    [central appendBytes:utf8 length:strlen(utf8)];
    (*count)++;
    return *count < 0xFFFF;
}

static BOOL writeTree(FILE *out, NSString *full, NSString *name, NSMutableData *central, uint32_t *count)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    struct stat st;
    BOOL ok = writeEntry(out, full, name, central, count);

    if (ok && lstat([full fileSystemRepresentation], &st) == 0 && S_ISDIR(st.st_mode)) {
        NSArray *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:full error:NULL]
                             sortedArrayUsingSelector:@selector(compare:)];

        for (NSString *child in names) {
            if (!writeTree(out, [full stringByAppendingPathComponent:child], [name stringByAppendingPathComponent:child], central, count)) {
                ok = NO;
                break;
            }
        }
    }
    [pool release];
    return ok;
}

BOOL IDZipItems(NSArray *paths, NSString *archive)
{
    static dispatch_once_t once;
    NSString *partial = [[archive stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.part", [archive lastPathComponent]]];
    NSMutableData *central = [NSMutableData data], *end = [NSMutableData data];
    uint32_t count = 0;
    long start;
    FILE *out;
    BOOL ok = YES;

    dispatch_once(&once, ^{ makeCrcTable(); });
    out = fopen([partial fileSystemRepresentation], "wb");
    if (out == NULL)
        return NO;
    for (NSString *path in paths) {
        if (!writeTree(out, path, [path lastPathComponent], central, &count)) {
            ok = NO;
            break;
        }
    }
    start = ftell(out);
    if (ok && start >= 0 && start + (long)[central length] < 0xFFFFFFF0L) {
        put32(end, 0x06054b50);
        put16(end, 0);
        put16(end, 0);
        put16(end, count);
        put16(end, count);
        put32(end, (uint32_t)[central length]);
        put32(end, (uint32_t)start);
        put16(end, 0);
        ok = writeAll(out, central) && writeAll(out, end);
    } else {
        ok = NO;
    }
    ok = fclose(out) == 0 && ok;
    if (ok)
        ok = rename([partial fileSystemRepresentation], [archive fileSystemRepresentation]) == 0;
    if (!ok)
        unlink([partial fileSystemRepresentation]);
    return ok;
}
