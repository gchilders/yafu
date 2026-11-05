/*
cpu_dispatch.c -- one executable, two copies of the siever.

build_boinc_windows.sh links a generic (x86-64) and an AVX-512 (x86-64-v4,
AVX512_ALL=1) build of gnfs-lasieve4I<n>e into a single executable.  The
AVX-512 copy's symbols are renamed (its main becomes lasieve_main_avx512),
the generic copy's main becomes lasieve_main_generic, and this file supplies
the real main(), which picks one at startup.

Selection:
  --cpu=auto     (default) AVX-512 if the CPU has everything the x86-64-v4
                 build uses AND the OS saves the AVX-512 register state,
                 otherwise generic.
  --cpu=generic  always the generic code.
  --cpu=avx512   the AVX-512 code; refused (generic used instead, with a
                 message) if the CPU or OS cannot run it.
Values are case-insensitive; an unknown value means auto.

The option is removed before the siever parses its own arguments, so it can
go anywhere on the command line -- in particular in <cmdline> in a BOINC
app_config.xml, e.g.

  <app_config>
    <app_version>
      <app_name>APP_NAME</app_name>
      <cmdline>--cpu=generic</cmdline>
    </app_version>
  </app_config>

The choice is reported on stderr, and passed in LASIEVE_CPU_PATH so the BOINC
build can repeat it after boinc_init() has redirected stderr to stderr.txt.

This file is compiled for baseline x86-64: it runs before either copy is
chosen.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <cpuid.h>

int lasieve_main_generic(int argc, char **argv);
int lasieve_main_avx512(int argc, char **argv);

/* Returns NULL if the AVX-512 copy can run here, else the reason it can't. */
static const char *avx512_unavailable(void)
{
    unsigned int a, b, c, d, max;
    unsigned int lo, hi;

    max = __get_cpuid_max(0, NULL);
    if (max < 7)
        return "CPU has no CPUID leaf 7";
    __cpuid(1, a, b, c, d);
    if ((c & (bit_FMA | bit_MOVBE | bit_POPCNT | bit_AVX | bit_F16C)) !=
        (bit_FMA | bit_MOVBE | bit_POPCNT | bit_AVX | bit_F16C))
        return "CPU lacks FMA/MOVBE/POPCNT/AVX/F16C";
    if (!(c & bit_OSXSAVE))
        return "OS has not enabled XSAVE";
    __cpuid_count(7, 0, a, b, c, d);
    if ((b & (bit_AVX2 | bit_BMI | bit_BMI2)) != (bit_AVX2 | bit_BMI | bit_BMI2))
        return "CPU lacks AVX2/BMI1/BMI2";
    if ((b & (bit_AVX512F | bit_AVX512DQ | bit_AVX512CD | bit_AVX512BW | bit_AVX512VL)) !=
        (bit_AVX512F | bit_AVX512DQ | bit_AVX512CD | bit_AVX512BW | bit_AVX512VL))
        return "CPU lacks AVX-512 F/DQ/CD/BW/VL";
    if (__get_cpuid_max(0x80000000, NULL) < 0x80000001)
        return "CPU has no extended CPUID leaf 0x80000001";
    __cpuid(0x80000001, a, b, c, d);
    if (!(c & bit_LZCNT))
        return "CPU lacks LZCNT";
    /* XCR0: SSE, AVX, and the three AVX-512 state components (opmask,
       ZMM0-15 upper halves, ZMM16-31) must all be enabled by the OS. */
    __asm__ __volatile__("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    if ((lo & 0xE6) != 0xE6)
        return "OS does not save AVX-512 register state";
    return NULL;
}

static void set_note(const char *note)
{
#ifdef _WIN32
    _putenv_s("LASIEVE_CPU_PATH", note);
#else
    setenv("LASIEVE_CPU_PATH", note, 1);
#endif
    fprintf(stderr, "%s\n", note);
}

int main(int argc, char **argv)
{
    const char *want = "auto";
    const char *why_not;
    char note[200];
    int i, j, use_avx512;

    /* take out every --cpu=... (the last one wins) */
    for (i = j = 1; i < argc; i++) {
        if (strncmp(argv[i], "--cpu=", 6) == 0)
            want = argv[i] + 6;
        else
            argv[j++] = argv[i];
    }
    argc = j;
    argv[argc] = NULL;

    why_not = avx512_unavailable();
    if (strcasecmp(want, "generic") == 0) {
        use_avx512 = 0;
        snprintf(note, sizeof(note), "cpu path: generic (--cpu=generic)");
    }
    else if (strcasecmp(want, "avx512") == 0) {
        use_avx512 = (why_not == NULL);
        if (use_avx512)
            snprintf(note, sizeof(note), "cpu path: avx512 (--cpu=avx512)");
        else
            snprintf(note, sizeof(note),
                     "cpu path: generic (--cpu=avx512 refused: %s)", why_not);
    }
    else {
        char how[80];
        use_avx512 = (why_not == NULL);
        if (strcasecmp(want, "auto") == 0)
            snprintf(how, sizeof(how), "auto");
        else
            snprintf(how, sizeof(how), "unknown --cpu=%.30s, using auto", want);
        if (use_avx512)
            snprintf(note, sizeof(note), "cpu path: avx512 (%s)", how);
        else
            snprintf(note, sizeof(note), "cpu path: generic (%s: %s)", how, why_not);
    }
    set_note(note);

    return use_avx512 ? lasieve_main_avx512(argc, argv)
                      : lasieve_main_generic(argc, argv);
}
