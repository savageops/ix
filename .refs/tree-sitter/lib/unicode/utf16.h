#ifndef TREE_SITTER_UNICODE_UTF16_H
#define TREE_SITTER_UNICODE_UTF16_H
#include <stdint.h>
static inline uint32_t utf16_decode(const uint16_t **p) { return **p; }
#endif
