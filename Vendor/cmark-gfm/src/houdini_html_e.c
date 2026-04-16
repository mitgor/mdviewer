#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

#include "houdini.h"

#if defined(__SSE2__)
#include <emmintrin.h>
#ifdef _MSC_VER
#include <intrin.h>
#endif
#elif defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#if !defined(__has_builtin)
# define __has_builtin(b) 0
#endif

#if !__has_builtin(__builtin_expect)
# define __builtin_expect(e, v) (e)
#endif

#define unlikely(e) __builtin_expect((e), 0)

/**
 * According to the OWASP rules:
 *
 * & --> &amp;
 * < --> &lt;
 * > --> &gt;
 * " --> &quot;
 * ' --> &#x27;     &apos; is not recommended
 * / --> &#x2F;     forward slash is included as it helps end an HTML entity
 *
 */
static const char HTML_ESCAPE_TABLE[] = {
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 4,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

static const struct {
  const char *str;
  bufsize_t len;
} HTML_ESCAPES[] = {
    {"", 0},
    {"&quot;", 6},
    {"&amp;", 5},
    {"&#39;", 5},
    {"&#47;", 5},
    {"&lt;", 4},
    {"&gt;", 4},
};

/*
 * SIMD-accelerated scan for the next HTML escape character.
 *
 * Scans for: < > & " ' /  (all 6 characters from HTML_ESCAPE_TABLE)
 * Returns the index of the next character requiring escaping, or `size`
 * if none found. The SIMD path processes 16 bytes at a time; a scalar
 * tail handles the remaining 0-15 bytes.
 *
 * Three compile-time paths:
 *   - SSE2  (x86-64, always available)
 *   - NEON  (AArch64, always available)
 *   - Scalar fallback (wasm32-wasi, etc.)
 */
#if defined(__SSE2__)

static bufsize_t find_escape_char(const uint8_t *src, bufsize_t i,
                                  bufsize_t size) {
  /* SSE2: compare 16 bytes against each target character, OR masks */
  while (i + 16 <= size) {
    __m128i data = _mm_loadu_si128((const __m128i *)(src + i));

    __m128i mask = _mm_or_si128(
      _mm_or_si128(
        _mm_cmpeq_epi8(data, _mm_set1_epi8('<')),
        _mm_cmpeq_epi8(data, _mm_set1_epi8('>'))),
      _mm_or_si128(
        _mm_cmpeq_epi8(data, _mm_set1_epi8('&')),
        _mm_cmpeq_epi8(data, _mm_set1_epi8('"'))));
    mask = _mm_or_si128(mask,
      _mm_or_si128(
        _mm_cmpeq_epi8(data, _mm_set1_epi8('\'')),
        _mm_cmpeq_epi8(data, _mm_set1_epi8('/'))));

    int m = _mm_movemask_epi8(mask);
    if (m != 0) {
#ifdef _MSC_VER
      unsigned long idx;
      _BitScanForward(&idx, m);
      return i + (bufsize_t)idx;
#else
      return i + __builtin_ctz(m);
#endif
    }
    i += 16;
  }

  /* Scalar tail for remaining bytes */
  while (i < size && HTML_ESCAPE_TABLE[src[i]] == 0)
    i++;

  return i;
}

#elif defined(__ARM_NEON)

static bufsize_t find_escape_char(const uint8_t *src, bufsize_t i,
                                  bufsize_t size) {
  /* Hoist constant vectors outside the loop */
  const uint8x16_t ch_lt  = vdupq_n_u8('<');
  const uint8x16_t ch_gt  = vdupq_n_u8('>');
  const uint8x16_t ch_amp = vdupq_n_u8('&');
  const uint8x16_t ch_dq  = vdupq_n_u8('"');
  const uint8x16_t ch_sq  = vdupq_n_u8('\'');
  const uint8x16_t ch_sl  = vdupq_n_u8('/');

  while (i + 16 <= size) {
    uint8x16_t data = vld1q_u8(src + i);

    uint8x16_t mask = vorrq_u8(
      vorrq_u8(
        vceqq_u8(data, ch_lt),
        vceqq_u8(data, ch_gt)),
      vorrq_u8(
        vceqq_u8(data, ch_amp),
        vceqq_u8(data, ch_dq)));
    mask = vorrq_u8(mask,
      vorrq_u8(
        vceqq_u8(data, ch_sq),
        vceqq_u8(data, ch_sl)));

    /* Compress 16 match bytes into 8 nibbles in a u64, then find first */
    uint64_t bits = vget_lane_u64(vreinterpret_u64_u8(
      vshrn_n_u16(vreinterpretq_u16_u8(mask), 4)), 0);
    if (bits != 0) {
      int idx = __builtin_ctzll(bits) / 4;
      return i + idx;
    }
    i += 16;
  }

  /* Scalar tail for remaining bytes */
  while (i < size && HTML_ESCAPE_TABLE[src[i]] == 0)
    i++;

  return i;
}

#else

static bufsize_t find_escape_char(const uint8_t *src, bufsize_t i,
                                  bufsize_t size) {
  /* Scalar fallback: byte-by-byte lookup table scan */
  while (i < size && HTML_ESCAPE_TABLE[src[i]] == 0)
    i++;
  return i;
}

#endif

int houdini_escape_html0(cmark_strbuf *ob, const uint8_t *src, bufsize_t size,
                         int secure) {
  bufsize_t i = 0, org, esc = 0;

  // Pre-grow buffer for worst case: every byte becomes "&quot;" (6 bytes).
  // Guard against int32 overflow: if size > (INT32_MAX - ob->size) / 6,
  // skip pre-grow and let incremental growth handle it.
  if (size <= (INT32_MAX - ob->size) / 6) {
    cmark_strbuf_grow(ob, ob->size + size * 6);
  }

  while (i < size) {
    org = i;
    i = find_escape_char(src, i, size);

    if (i > org)
      cmark_strbuf_put(ob, src + org, i - org);

    /* escaping */
    if (unlikely(i >= size))
      break;

    esc = HTML_ESCAPE_TABLE[src[i]];

    /* The forward slash and single quote are only escaped in secure mode */
    if ((src[i] == '/' || src[i] == '\'') && !secure) {
      cmark_strbuf_putc(ob, src[i]);
    } else {
      cmark_strbuf_put(ob, (const unsigned char *)HTML_ESCAPES[esc].str,
                       HTML_ESCAPES[esc].len);
    }

    i++;
  }

  return 1;
}

int houdini_escape_html(cmark_strbuf *ob, const uint8_t *src, bufsize_t size) {
  return houdini_escape_html0(ob, src, size, 1);
}
