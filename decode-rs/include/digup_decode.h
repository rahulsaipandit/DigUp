/* DOWNSTREAM-FORK (2026-11-17, security): new in the fork. The C interface of decode-rs (src/lib.rs): what stb_image and miniz read
   for DigUp, in Rust. Return codes are 0 for success, or one of the codes below. */
#ifndef DIGUP_DECODE_H
#define DIGUP_DECODE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  DZ_OK = 0,
  DZ_UNSUPPORTED = 1,   /* not a format this reads: another reader may try it */
  DZ_CORRUPT = 2,       /* a format this reads, and the file is bad */
  DZ_TOO_BIG = 3,       /* more memory or size than is allowed */
  DZ_NOT_A_ZIP = 4,
  DZ_NO_SUCH_ENTRY = 5,
  DZ_READ_ERROR = 6,
  DZ_PANIC = 7,
  DZ_BAD_ARGUMENT = 8
};

/* Frees what an out parameter returned, with the length it returned with it. */
void dz_free(uint8_t *pointer, size_t len);

/* A picture's size, found without decoding it: JPEG, PNG, GIF and BMP, recognized by their first bytes. DZ_UNSUPPORTED for any other
   file (stb may read it). */
int32_t dz_image_info(const uint8_t *data, size_t len, int32_t *width, int32_t *height);

/* A picture as packed 8-bit RGB: width * height * 3 bytes in *out, freed with dz_free(*out, *out_len). */
int32_t dz_image_decode_rgb(const uint8_t *data, size_t len, int32_t *width, int32_t *height, uint8_t **out, size_t *out_len);

/* Reads where it is asked: copies up to `length` bytes from `offset` into `buffer`, returns how many, or -1. */
typedef int64_t (*dz_read_at)(void *context, uint64_t offset, uint8_t *buffer, size_t length);

/* One entry of a zip file, by its UTF-8 name, at most max_bytes long (checked against the declared size before anything is
   allocated, and again as it is read). The zip is `size` bytes, read through `read`. The entry's bytes are in *out, freed with
   dz_free(*out, *out_len). */
int32_t dz_zip_entry(dz_read_at read, void *context, uint64_t size, const char *name, uint64_t max_bytes, uint8_t **out,
                     size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif
