/* x86-intrin-compat.h: include this instead of <immintrin.h>.

   On x86-64 it is just <immintrin.h>.  Anywhere else (arm64) it provides
   portable versions of the few x86 intrinsics that the non-AVX-512 code
   uses -- _addcarry_u64, _subborrow_u64, _umul128, _tzcnt_u32/_u64 -- built
   on compiler builtins that compile to the native carry and multiply-high
   instructions.  The AVX-512 code is compiled only for x86-64, so nothing
   else is needed. */
#ifndef X86_INTRIN_COMPAT_H
#define X86_INTRIN_COMPAT_H

#if defined(__x86_64__) || defined(_M_X64)

#include <immintrin.h>

#else

#include <stdint.h>

#define LASIEVE_PORTABLE_INTRIN

static inline unsigned char _addcarry_u64(unsigned char c_in, uint64_t a,
                                          uint64_t b, uint64_t *sum)
{
    unsigned __int128 s = (unsigned __int128)a + b + c_in;
    *sum = (uint64_t)s;
    return (unsigned char)(s >> 64);
}

static inline unsigned char _subborrow_u64(unsigned char b_in, uint64_t a,
                                           uint64_t b, uint64_t *diff)
{
    unsigned __int128 d = (unsigned __int128)a - b - b_in;
    *diff = (uint64_t)d;
    return (unsigned char)((d >> 64) & 1);
}

static inline uint64_t _umul128(uint64_t a, uint64_t b, uint64_t *hi)
{
    unsigned __int128 p = (unsigned __int128)a * b;
    *hi = (uint64_t)(p >> 64);
    return (uint64_t)p;
}

static inline uint32_t _tzcnt_u32(uint32_t x)
{
    return x ? (uint32_t)__builtin_ctz(x) : 32;
}

static inline uint64_t _tzcnt_u64(uint64_t x)
{
    return x ? (uint64_t)__builtin_ctzll(x) : 64;
}

#endif

#endif /* X86_INTRIN_COMPAT_H */
