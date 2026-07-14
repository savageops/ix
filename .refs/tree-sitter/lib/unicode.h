#ifndef TREE_SITTER_UNICODE_H_
#define TREE_SITTER_UNICODE_H_

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <limits.h>

#define TS_DECODE_ERROR ((uint32_t)-1)

static inline uint32_t ts_decode_utf8(const uint8_t *input, uint32_t length, uint32_t *code_point) {
    if (length == 0) { *code_point = 0; return 0; }
    uint8_t first = input[0];
    if (first < 0x80) { *code_point = first; return 1; }
    if ((first & 0xE0) == 0xC0 && length >= 2) {
        *code_point = ((first & 0x1F) << 6) | (input[1] & 0x3F);
        return 2;
    }
    if ((first & 0xF0) == 0xE0 && length >= 3) {
        *code_point = ((first & 0x0F) << 12) | ((input[1] & 0x3F) << 6) | (input[2] & 0x3F);
        return 3;
    }
    if ((first & 0xF8) == 0xF0 && length >= 4) {
        *code_point = ((first & 0x07) << 18) | ((input[1] & 0x3F) << 12) | ((input[2] & 0x3F) << 6) | (input[3] & 0x3F);
        return 4;
    }
    *code_point = first;
    return 1;
}

static inline uint32_t ts_decode_utf16_le(const uint8_t *input, uint32_t length, uint32_t *code_point) {
    if (length < 2) { *code_point = TS_DECODE_ERROR; return 0; }
    *code_point = input[0] | (input[1] << 8);
    return 2;
}

static inline uint32_t ts_decode_utf16_be(const uint8_t *input, uint32_t length, uint32_t *code_point) {
    if (length < 2) { *code_point = TS_DECODE_ERROR; return 0; }
    *code_point = (input[0] << 8) | input[1];
    return 2;
}

#ifdef __cplusplus
}
#endif

#endif  // TREE_SITTER_UNICODE_H_
