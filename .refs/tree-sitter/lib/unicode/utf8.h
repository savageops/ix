#ifndef TREE_SITTER_UNICODE_UTF8_H
#define TREE_SITTER_UNICODE_UTF8_H
#include <stdint.h>
static inline uint32_t utf8_decode(const uint8_t **p) { return **p; }
static inline int utf8_encode(uint32_t codepoint, uint8_t *dst) { *dst = (uint8_t)codepoint; return 1; }
#endif
