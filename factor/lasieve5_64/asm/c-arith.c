/* c-arith.c: C versions of the x86-64 arithmetic in asm_arith{64,128,192}.asm,
   asm_64bit.asm and pt64.asm, for targets without that assembly (arm64).
   Built only when the target is not x86-64 (see asm/Makefile).

   Montgomery arithmetic modulo N = montgomery_modulo_n[0..k-1] (k = 1, 2, 3
   64-bit limbs), with montgomery_inv_n = -1/N mod 2^64.  As in the assembly,
   every input is < N and every result is fully reduced (< N).  The top limb
   of N is never 2^64-1 (set_montgomery_multiplication sees to that).

     asm_zeroK(a)        a = 0
     asm_copyK(b,a)      b = a
     asm_subK_3(c,a,b)   c = a - b mod N
     asm_addK(b,a)       b = b + a mod N
     asm_halfK(a)        a = a / 2 mod N   (N odd)
     asm_mulmK(c,a,b)    c = a * b / 2^(64K) mod N

   asm_modadd64 and asm_modmul64 work modulo the global modulo64, and pt64(n)
   is a base-2 strong probable prime test of a 64-bit n. */

#include <stdint.h>
#include <stdlib.h>
#include <gmp.h>
#include "siever-config.h"
#include "../if.h"
#include "montgomery_mul.h"

typedef unsigned __int128 u128;

extern ulong montgomery_inv_n;
extern ulong *montgomery_modulo_n;
volatile extern u64_t modulo64;

/* ---------------- generic K-limb helpers (K is a constant) ---------------- */

/* x >= N ? */
static inline int geq_n(const ulong *x, const ulong *n, int k)
{
    for (int i = k - 1; i >= 0; i--) {
        if (x[i] != n[i])
            return x[i] > n[i];
    }
    return 1;
}

/* x -= y, returns the borrow */
static inline ulong sub_k(ulong *x, const ulong *y, int k)
{
    ulong borrow = 0;
    for (int i = 0; i < k; i++) {
        u128 d = (u128)x[i] - y[i] - borrow;
        x[i] = (ulong)d;
        borrow = (ulong)(d >> 64) & 1;
    }
    return borrow;
}

/* x += y, returns the carry */
static inline ulong add_k(ulong *x, const ulong *y, int k)
{
    ulong carry = 0;
    for (int i = 0; i < k; i++) {
        u128 s = (u128)x[i] + y[i] + carry;
        x[i] = (ulong)s;
        carry = (ulong)(s >> 64);
    }
    return carry;
}

static inline void sub3_k(ulong *c, const ulong *a, const ulong *b, int k)
{
    ulong t[3];
    for (int i = 0; i < k; i++) t[i] = a[i];
    if (sub_k(t, b, k))
        add_k(t, montgomery_modulo_n, k);
    for (int i = 0; i < k; i++) c[i] = t[i];
}

static inline void add2_k(ulong *x, const ulong *y, int k)
{
    ulong carry = add_k(x, y, k);
    if (carry || geq_n(x, montgomery_modulo_n, k))
        sub_k(x, montgomery_modulo_n, k);
}

static inline void half_k(ulong *x, int k)
{
    ulong carry = 0;
    if (x[0] & 1)
        carry = add_k(x, montgomery_modulo_n, k);
    for (int i = 0; i < k - 1; i++)
        x[i] = (x[i] >> 1) | (x[i + 1] << 63);
    x[k - 1] = (x[k - 1] >> 1) | (carry << 63);
}

/* Montgomery product, CIOS */
static inline void mulm_k(ulong *c, const ulong *a, const ulong *b, int k)
{
    const ulong *n = montgomery_modulo_n;
    const ulong inv = montgomery_inv_n;
    ulong t[5] = { 0, 0, 0, 0, 0 };

    for (int i = 0; i < k; i++) {
        u128 p;
        ulong carry = 0;
        for (int j = 0; j < k; j++) {
            p = (u128)a[i] * b[j] + t[j] + carry;
            t[j] = (ulong)p;
            carry = (ulong)(p >> 64);
        }
        p = (u128)t[k] + carry;
        t[k] = (ulong)p;
        t[k + 1] = (ulong)(p >> 64);

        ulong m = t[0] * inv;
        p = (u128)m * n[0] + t[0];
        carry = (ulong)(p >> 64);
        for (int j = 1; j < k; j++) {
            p = (u128)m * n[j] + t[j] + carry;
            t[j - 1] = (ulong)p;
            carry = (ulong)(p >> 64);
        }
        p = (u128)t[k] + carry;
        t[k - 1] = (ulong)p;
        t[k] = t[k + 1] + (ulong)(p >> 64);
    }
    /* t < 2N */
    if (t[k] || geq_n(t, n, k))
        sub_k(t, n, k);
    for (int i = 0; i < k; i++) c[i] = t[i];
}

/* ------------------------------ entry points ------------------------------ */

#define DEFINE_K(K, BITS)                                                      \
void ASM_ATTR asm_zero##BITS(ulong *a)                                         \
{ for (int i = 0; i < K; i++) a[i] = 0; }                                      \
void ASM_ATTR asm_copy##BITS(ulong *b, ulong *a)                               \
{ for (int i = 0; i < K; i++) b[i] = a[i]; }                                   \
void ASM_ATTR asm_sub##BITS##_3(ulong *c, ulong *a, ulong *b)                  \
{ sub3_k(c, a, b, K); }                                                        \
void ASM_ATTR asm_add##BITS(ulong *b, ulong *a)                                \
{ add2_k(b, a, K); }                                                           \
void ASM_ATTR asm_half##BITS(ulong *a)                                         \
{ half_k(a, K); }                                                              \
void ASM_ATTR asm_mulm##BITS(ulong *c, ulong *a, ulong *b)                     \
{ mulm_k(c, a, b, K); }

DEFINE_K(1, 64)
DEFINE_K(2, 128)
DEFINE_K(3, 192)

/* (x + y) mod modulo64, for x, y < modulo64 */
u64_t ASM_ATTR asm_modadd64(u64_t x, u64_t y)
{
    u64_t n = modulo64;
    u128 s = (u128)x + y;
    return (u64_t)(s >= n ? s - n : s);
}

/* x * y mod modulo64 */
u64_t ASM_ATTR asm_modmul64(u64_t x, u64_t y)
{
    return (u64_t)(((u128)x * y) % modulo64);
}

/* ------------------------------- pt64 ------------------------------------- */

/* Montgomery product modulo the odd 64-bit n, ninv = -1/n mod 2^64 */
static inline u64_t mont64(u64_t a, u64_t b, u64_t n, u64_t ninv)
{
    u128 t = (u128)a * b;
    u64_t m = (u64_t)t * ninv;
    u128 s = (t >> 64) + (((u128)m * n) >> 64) + ((u64_t)t != 0);
    return (u64_t)(s >= n ? s - n : s);
}

/* 1 if n is a base-2 strong probable prime, else 0 */
u64_t ASM_ATTR pt64(u64_t n)
{
    if (n < 3 || !(n & 1))
        return n == 2;

    u64_t inv = n;                     /* 1/n mod 2^3 */
    for (int i = 0; i < 5; i++)        /* 6, 12, 24, 48, 96 bits */
        inv *= 2 - n * inv;
    u64_t ninv = -inv;

    u64_t one = (-n) % n;              /* 2^64 mod n */
    u64_t minus_one = n - one;

    u64_t d = n - 1;
    int s = __builtin_ctzll(d);
    d >>= s;

    /* t = 2^d, in Montgomery form, left to right */
    u64_t t = one;
    for (int bit = 63 - __builtin_clzll(d); bit >= 0; bit--) {
        t = mont64(t, t, n, ninv);
        if ((d >> bit) & 1) {          /* t *= 2 */
            u128 u = (u128)t + t;
            t = (u64_t)(u >= n ? u - n : u);
        }
    }
    if (t == one || t == minus_one)
        return 1;
    for (int i = 1; i < s; i++) {
        t = mont64(t, t, n, ninv);
        if (t == minus_one)
            return 1;
    }
    return 0;
}

/* ------------------------------ modinv32 ---------------------------------- */

volatile extern u32_t modulo32;

/* 1/x mod modulo32, for 0 < x < modulo32 with gcd 1, as modinv1000.asm:
   Euclid on (x, m), keeping the cofactors xc, yc (which stay below
   modulo32) unreduced.  modinv1000.asm tries up to 15 subtractions before
   each division, because x86 division is slow; arm64's is fast enough that
   dividing every time is about 45% quicker. */
u32_t ASM_ATTR asm_modinv32(u32_t x)
{
    u32_t y = modulo32, xc = 1, yc = 0;

    if (x == 0 || x >= y)
        abort();
    if (x == 1)
        return 1;
    for (;;) {
        /* y -= q*x, yc += q*xc */
        u32_t q = y / x;
        y -= q * x;
        yc += q * xc;
        if (y <= 1) {
            if (y != 1)
                abort();
            return modulo32 - yc;
        }
        /* x -= q*y, xc += q*yc */
        q = x / y;
        x -= q * y;
        xc += q * yc;
        if (x <= 1) {
            if (x != 1)
                abort();
            return xc;
        }
    }
}
