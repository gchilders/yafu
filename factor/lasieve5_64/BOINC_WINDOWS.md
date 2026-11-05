# Windows x86_64 BOINC sievers

How to build `gnfs-lasieve4I14e.exe`, `gnfs-lasieve4I15e.exe` and
`gnfs-lasieve4I16e.exe` for NFS@Home's `windows_x86_64` platform.

Each executable holds two complete copies of the siever. One is built for
plain x86-64, the other for x86-64-v4 with the AVX-512 code paths. A small
dispatcher picks one at startup. `build_boinc_windows.sh` does all of this; its
header comment explains how the two copies are combined.

## 1. Toolchain: MSYS2 UCRT64

Install MSYS2 (for example `winget install MSYS2.MSYS2`). Then, in an MSYS2
shell:

```sh
pacman -Syu
pacman -S make m4 tar \
    mingw-w64-ucrt-x86_64-gcc \
    mingw-w64-ucrt-x86_64-binutils \
    mingw-w64-ucrt-x86_64-gmp
```

The build was last done with gcc 16.2.0, binutils 2.47, GMP 6.3.0, m4 1.4.21 and
make 4.4.1. Do everything else from the **UCRT64** shell (the "MSYS2 UCRT64"
Start menu entry, or `MSYSTEM=UCRT64` with `bash -l`).

- MSYS2's `libgmp.a` is a fat build: it picks its CPU-specific code at run time,
  so one static copy serves both siever copies.
- The `asm/` directory needs `m4`. Strawberry Perl's gcc and an MSVC toolchain
  are not used.

## 2. BOINC libraries, built with MinGW

The MSVC `.lib` files from BOINC's `win_build` cannot be linked with MinGW, so
build `libboinc.a` and `libboinc_api.a` with BOINC's own `lib/Makefile.mingw`.
Keep this build apart from any MSVC BOINC build, for example in a git worktree:

```sh
git clone https://github.com/BOINC/boinc.git   # or reuse a checkout
cd boinc
git worktree add --detach ../boinc-mingw 637492d36d   # what the release was built with
cd ../boinc-mingw
mkdir _build && cd _build
make -f ../lib/Makefile.mingw BOINC_SRC=.. \
    OPTFLAGS='-O3 -march=x86-64 -mtune=generic' -j16 all
make -f ../lib/Makefile.mingw BOINC_SRC=.. \
    OPTFLAGS='-O3 -march=x86-64 -mtune=generic' BOINC_PREFIX=../_install install
```

This leaves the headers in `_install/include/boinc` and the libraries in
`_install/lib`.

**Keep the `OPTFLAGS`.** MSYS2's gcc defaults to `-march=nocona` (x86-64 plus
SSE3), so building without `-march=x86-64` puts SSE3 instructions into code that
runs before the dispatcher has checked anything.

## 3. Build the sievers

From this directory, in the UCRT64 shell:

```sh
BOINC_PREFIX=/c/dev/boinc-mingw/_install sh build_boinc_windows.sh
```

It takes well under a minute with `JOBS=16`, the default. `GMP_PREFIX` defaults
to `/ucrt64`. The optional argument is the output directory, which defaults to
`boinc-win/` (gitignored):

| Output | What it is |
|---|---|
| `boinc-win/gnfs-lasieve4I{14,15,16}e.exe` | the combined executables; **these are what get deployed** |
| `boinc-win/generic/`, `boinc-win/avx512/` | single-flavour builds, for testing and comparison |
| `boinc-win/build/` | the build trees |

**Don't run `make clean` in this directory.** It deletes the prebuilt Linux
`gnfs-lasieve4I1*e` binaries that are tracked in git. The script builds each
flavour in its own copy of the sources, so it never needs to clean here.

The Makefile's own BOINC switches, in case you build by hand: `BOINC=1` (plus
`BOINC_INC_DIR`, `BOINC_LIB_DIR`), `ARCH=` and `TUNE=` (which replace
`-march=native`), and `AVX512_ALL=1`. The `gnfs-lasieve4I<n>e.ro` target
produces the partially linked object that the combining step uses.

## 4. What the executables need at run time

- **Windows 10 or later** as they are.
- **Windows Vista SP2, 7 SP1, 8 or 8.1** only with the Universal C Runtime
  installed. It comes from KB2999226 through Windows Update, or with any Visual
  C++ 2015–2022 redistributable. Without it the task fails at once with
  "api-ms-win-crt-runtime-l1-1-0.dll is missing".
- **Any x86-64 CPU.** The only exception is 8 SSE3 `movddup` instructions in
  MSYS2's prebuilt libstdc++ string-buffer code, which the siever is not known
  to use. The AVX-512 copy is used only when the CPU has AVX-512 F/BW/CD/DQ/VL
  (and the rest of x86-64-v4) *and* the OS saves the AVX-512 registers.
  Windows versions before 10 don't, so they get the generic copy.
- **No DLLs to ship.** Everything is linked statically.
  `objdump -p <exe> | grep 'DLL Name'` should show only `KERNEL32`, `ADVAPI32`,
  `SHELL32`, `USER32` and `api-ms-win-crt-*`.

## 5. Choosing the code path

| Option | Effect |
|---|---|
| `--cpu=auto` | the default: AVX-512 where the CPU and the OS can run it, otherwise generic |
| `--cpu=generic` | always use the generic code |
| `--cpu=avx512` | use the AVX-512 code; if this machine can't run it, use generic and say why |

The option can go anywhere on the command line, the last one wins, and values
are case-insensitive. An unknown value means `auto`. The executable removes the
option before the siever reads its own arguments, so a volunteer can set it in
`app_config.xml`:

```xml
<app_config>
  <app_version>
    <app_name>APP_NAME</app_name>
    <cmdline>--cpu=generic</cmdline>
  </app_version>
</app_config>
```

Every run writes the choice to `stderr.txt`, for example
`cpu path: avx512 (auto)` or `cpu path: generic (--cpu=generic)`.

## 6. Checking a build

**Run it standalone.** Outside BOINC the executable reads `input_data` and
writes `output_data` and `stderr.txt` in the current directory:

```sh
mkdir t && cd t
cp ../nfs512_15300k_I14.job input_data
../boinc-win/gnfs-lasieve4I14e.exe --cpu=generic -a -f 15300000 -c 200
wc -l output_data      # 539 relations
```

Run it again with `--cpu=avx512` (on an AVX-512 machine) and with no option.
`-c` is the width of the special-q range, not a count of special-q.

**Compare with Linux.** Built with the same `ARCH=x86-64 TUNE=generic`, the
generic code writes byte-identical `output_data` on Windows and Linux. The
AVX-512 code is deterministic for a given binary, but differs slightly from the
generic code. It prints the three large primes of a relation in a different
order and finds about 0.15% fewer three-large-prime relations. Every relation
it writes is still correct, and NFS@Home's validator only checks that.

**Check the instruction set.** The generic copy should contain nothing beyond
SSE2, apart from GMP's runtime-dispatched routines (`__gmpn_*_<cpu>`) and the
libstdc++ `movddup` mentioned above. Use the unstripped exe in the build tree,
which still has function names. This lists every SSE3, SSSE3, SSE4, AVX,
AVX-512, BMI, ADX, LZCNT, POPCNT and MOVBE instruction, by function:

```sh
objdump -d --no-show-raw-insn boinc-win/build/generic/gnfs-lasieve4I16e.exe | awk '
  /^[0-9a-f]+ <.*>:$/ { fn = $2; next }
  fn ~ /^<__gmpn_.*_(core|zen|sky|broad|has|bd|bobcat|jaguar|silvermont|goldmont|atom|nano|k8|k10|bt)/ { next }
  $2 ~ /^(v[a-z0-9]+|popcnt|lzcnt|movbe|mulx|adcx|adox|andn|bextr|blsi|blsmsk|blsr|bzhi|pdep|pext|rorx|sarx|shlx|shrx|movddup|movs[hl]dup|lddqu|addsubp[sd]|h(add|sub)p[sd]|fisttp[a-z]*|pshufb|palignr|pabs[bwd]|ph(add|sub)[a-z]*|pmaddubsw|pmulhrsw|psign[bwd]|crc32[a-z]*|pcmp[ei]str[im]|ptest|pblend[a-z]*|blendv?p[sd]|pmov[sz]x[a-z]*|round[ps][sd]|pinsr[bdq]|pextr[bdq]|pm(ax|in)(sb|sd|ud|uw)|pmulld|pcmpeqq|pcmpgtq|packusdw|dpp[sd]|insertps|extractps)$/ { n[fn " " $2]++ }
  END { for (k in n) print n[k], k }'
```

On each of the three sievers the expected output is exactly eight lines, each
one `movddup` in a `basic_stringbuf` function. Anything else is a
baseline-breaking instruction: find out where it came from before deploying.
gcc's `tzcnt` is not listed, because CPUs without BMI1 run it as `bsf`.

**Resume.** Kill a run partway and start it again in the same directory. It
should print " Dropped an incomplete last line" if the kill cut a line, and
carry on.

## 7. Things that bit during the port

- **LLP64.** On Windows `long` is 32 bits, so any `mpz_*_ui` call given a
  64-bit word truncates it silently. `ecm.c` and `pm1.c` now use `mpz_import`
  for this.
- **getopt.** MinGW's getopt does not permute arguments, so the BOINC code puts
  the job file last.
- **`USE_MULX`** in `tinyecm.c` is defined only when `__BMI2__` is. Otherwise
  the generic build would contain BMI2 instructions and crash on pre-Haswell
  CPUs.
- **Common-symbol alignment.** MinGW records it as `-aligncomm:"name",n`
  directives in `.drectve`, by symbol name. When the AVX-512 copy's symbols are
  renamed, those directives have to be renamed too, or its 32-byte-aligned
  `jmp_buf` ends up misaligned and `setjmp` crashes.
  `build_boinc_windows.sh` does this.
