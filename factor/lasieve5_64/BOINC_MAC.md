# macOS BOINC sievers

How to build `gnfs-lasieve4I14e`, `gnfs-lasieve4I15e` and `gnfs-lasieve4I16e`
for NFS@Home's Mac platforms.

| Platform | Build | Oldest macOS |
|---|---|---|
| `x86_64-apple-darwin` | x86-64 assembly from `asm/`, SSE4.1 baseline | 10.13 |
| `arm64-apple-darwin` | native: C in place of the x86-64 assembly | 11.0 |

`build_boinc_mac.sh` also combines the two with `lipo` into universal
binaries, and `package_boinc_mac.sh` registers each universal file under
both platforms (section 8).

There is no AVX-512 copy yet, so the Mac executables don't take
`--cpu=`. Adding one needs two Mac-specific changes:
- macOS turns on AVX-512 register state only the first time a process uses
  it, so `cpu_dispatch.c` has to check `sysctlbyname("hw.optional.avx512f")`
  and the related keys, not XGETBV.
- The two copies have to be combined with Mach-O tools, not `objcopy`.

## 1. Toolchain

- The Xcode command line tools (`xcode-select --install`). Full Xcode is not
  needed. Last built with Apple clang 21.0.0 and the macOS 27 SDK, on
  macOS 26.7 on Apple Silicon.
- Homebrew `autoconf`, `automake` and `libtool`, to build the BOINC
  libraries. The system `m4` (GNU m4 1.4.6) is enough for `asm/`.
- Rosetta 2 (`softwareupdate --install-rosetta`), to build and test x86_64
  on an Apple Silicon Mac.

Every library has to be built for the same architecture and deployment target
as the siever: `-arch x86_64 -mmacosx-version-min=10.13` or
`-arch arm64 -mmacosx-version-min=11.0`. Homebrew's own libraries are built
for the host's macOS and can't be used.

## 2. GMP 6.3.0, static, one per architecture

```sh
D=$HOME/code/lasieve-mac-deps          # any directory

mkdir -p $D/build/gmp-x86_64 && cd $D/build/gmp-x86_64
/path/to/gmp-6.3.0/configure --prefix=$D/x86_64 \
    --host=x86_64-apple-darwin --build=x86_64-apple-darwin \
    --disable-shared --enable-static --enable-fat --with-pic \
    CC="clang -arch x86_64 -mmacosx-version-min=10.13" CFLAGS=-O2
make -j8 && make check && make install

mkdir -p $D/build/gmp-arm64 && cd $D/build/gmp-arm64
/path/to/gmp-6.3.0/configure --prefix=$D/arm64 \
    --host=aarch64-apple-darwin --build=aarch64-apple-darwin \
    --disable-shared --enable-static \
    CC="clang -arch arm64 -mmacosx-version-min=11.0" CFLAGS=-O2
make -j8 && make check && make install
```

- `--enable-fat` makes the x86_64 GMP pick its CPU-specific code at run time,
  as MSYS2's build does on Windows.
- `--with-pic` is required for x86_64. macOS executables are always
  position-independent, and without it GMP's x86_64 assembly makes text
  relocations that `ld` refuses ("Found illegal text-relocations").
- On an Apple Silicon Mac, the x86_64 `make check` runs under Rosetta.

## 3. BOINC libraries, one per architecture

Build them from a separate checkout or git worktree, so a local BOINC build
isn't disturbed. The release was built from BOINC commit 55a5644402.

```sh
cd boinc && LIBTOOLIZE=glibtoolize ./_autosetup
for a in "x86_64 x86_64 10.13" "arm64 aarch64 11.0"; do
  set -- $a
  mkdir -p $D/build/boinc-$1 && cd $D/build/boinc-$1
  f="-arch $1 -mmacosx-version-min=$3"
  /path/to/boinc/configure --host=$2-apple-darwin --build=$2-apple-darwin \
      --prefix=$D/$1 --disable-server --disable-client --disable-manager \
      --disable-shared --enable-static \
      CC="clang $f" CXX="clang++ $f" OBJC="clang $f" OBJCXX="clang++ $f" \
      CFLAGS=-O2 CXXFLAGS=-O2
  (cd lib && make -j8 libboinc.a && make install)
  (cd api && make -j8 libboinc_api.a && make install)
done
```

## 4. Build the sievers

From this directory:

```sh
X86_64_PREFIX=$D/x86_64 ARM64_PREFIX=$D/arm64 sh build_boinc_mac.sh
```

`ARCHS=x86_64` or `ARCHS=arm64` builds just one. The optional argument is the
output directory, which defaults to `boinc-mac/` (gitignored):

| Output | What it is |
|---|---|
| `boinc-mac/x86_64/gnfs-lasieve4I{14,15,16}e` | Intel; stripped, ad-hoc signed |
| `boinc-mac/arm64/gnfs-lasieve4I{14,15,16}e` | Apple Silicon; stripped, ad-hoc signed |
| `boinc-mac/universal/gnfs-lasieve4I{14,15,16}e` | both, from `lipo` |
| `boinc-mac/build/{x86_64,arm64}-generic/` | the build trees, with unstripped executables |

As on Windows, **don't run `make clean` in this directory**. It deletes the
prebuilt Linux binaries that are tracked in git.

By hand, the Makefile takes `TARGET_FLAGS` for the flags that every compile,
assembly and link needs, for example
`TARGET_FLAGS="-arch x86_64 -mmacosx-version-min=10.13" ARCH=penryn TUNE=generic`
or `TARGET_FLAGS="-arch arm64 -mmacosx-version-min=11.0" ARCH= TUNE=`. An empty
`ARCH` passes no `-march`. For arm64, clang's default for this target is the
M1, the oldest Apple Silicon CPU.

## 5. How the arm64 build works

`asm/` is x86-64 assembly. For any other target, the Makefiles and headers
switch to C, so the same tree builds unchanged on x86-64:

- `asm/Makefile` asks the compiler whether the target is x86-64
  (`__x86_64__` with `TARGET_FLAGS`), so cross builds in either direction are
  detected correctly. If it isn't, the libraries hold only the C files, plus
  `asm/c-arith.c`.
- `asm/siever-config.h` defines the `ASM_*` / `HAVE_MM_*` switches (and the
  new `LASIEVE_X86_ASM`) only for x86-64. Elsewhere the siever uses the C
  versions it already had for the line sievers, trial-division sievers,
  candidate search, scheduling and lattice setup. `lasched.c` and `medsched.c`
  fall through to their C loops instead of calling the asm.
- `asm/mpqs-config.h` turns off the `ASM_MPQS*` and `HAVE_XMM_MUL` switches,
  so MPQS uses its C code and the plain data layout.
- `asm/32bit.h` has a C branch for `modmul32` and its relatives.
- `asm/c-arith.c` has the routines that had no C version:
  - the 64/128/192-bit Montgomery arithmetic (`asm_mulm*`, `asm_add*`,
    `asm_sub*_3`, `asm_half*`, `asm_zero*`, `asm_copy*`)
  - `asm_modadd64` and `asm_modmul64`
  - `pt64` (a base-2 strong probable prime test)
  - `asm_modinv32`, a Euclid like `modinv1000.asm`, except that it divides at
    every step, which is faster on arm64
- `x86-intrin-compat.h` replaces `#include <immintrin.h>`. On x86-64 it is
  `<immintrin.h>`. Elsewhere it gives portable `_addcarry_u64`,
  `_subborrow_u64`, `_umul128` and `_tzcnt_*`, which `tinyecm.c`,
  `microecm.c` and `micropm1.c` use. The inline asm in `tinyecm.c` and
  `gcd32.c` is x86-64 only, with C in its place elsewhere.

The C code had two performance problems on arm64, both fixed:
- The lattice-walk loops in `lasched.c` and `medsched.c` were compiled into
  two near-random branches per step, reloading `ri[]` every time because the
  schedule stores might alias it. They now keep the steps in locals and add
  them without branches.
- `modinv32.c`'s binary inversion was about a third of the run time; it is
  replaced by `asm_modinv32` in `c-arith.c`.

### Tuning for Apple Silicon

These changes apply only when the target isn't x86-64, so the x86-64
builds are unchanged. The output has exactly the same relations as the x86-64
build; only the order of some primes within a relation differs.

- **Larger schedule regions** (`asm/siever-config.c`, `SCHED_SIZEBITS_SHIFT`,
  default 2 for 14e and 15e, 1 for 16e). Each large-prime schedule covers a
  region 2 or 4 times the x86 size, so there are fewer passes over each
  part of the factor base. This costs memory, which matters for 16e. On a
  degree-6 SNFS job with rlim 250M and alim 350M, q above the factor base
  limit, peak memory per task is about 1.0 GB at shift 0 (the x86 sizes),
  1.1 GB at shift 1 and 1.3–1.45 GB at shift 2. Shifts 1 and 2 are 9% and
  14% faster than 0. 16e uses shift 1, so that more tasks fit on 8 GB
  Macs: BOINC by default lets all tasks together use 50% of RAM while the
  computer is in use and 90% when it's idle. The table in `siever-config.c`
  has the measurements, including R942. Build with
  `-DSCHED_SIZEBITS_SHIFT=n` to choose another.
- **Lattice setup, several primes at once** (`lasieve-prepn.c`,
  `recurrence6.c`, `SETUP_LANES`, default 8). For each factor base prime, the
  setup does a modular inverse and then `get_recurrence_info`. Both are chains
  of dependent divisions with an unpredictable end. They now run for 8 primes
  in lockstep, which overlaps the divisions and shares the mispredicted loop
  exits. The results are bit for bit the same as before.
- **Bucket scheduling, several primes at once** (`asm/lasched.c`,
  `LASCHED_LANES`, default 3). Three primes are walked side by side. Entries
  within a bucket piece come out in a different order, which nothing depends
  on.
- **A cheap `clock()`** (`gnfs-lasieve4e.c`, Apple only). The `-v`
  statistics call `clock()` several times per subsieve, and on macOS that is
  a `getrusage` system call. The Apple build reads the uptime counter instead.

Tried and not kept, because they gave no gain on an M3:
- LTO and profile-guided optimisation.
- `L1_BITS=16` to match the larger L1: large-prime sieving got faster, but
  `medsched` slowed by as much.
- A fixed number of branch-free steps per prime in `lasched`.
- Software prefetch and non-temporal stores in `lasched`.
- Interleaving primes in `medsched`.
- `NO_TD_CLOCK`, which made I16 8% slower.

## 6. What the executables need at run time

- **Intel:** macOS 10.13 or later, on any Intel Mac that runs it. macOS 10.12
  and later run only on Penryn or newer CPUs, so SSE4.1 is the baseline.
  Clang already defaults to `-march=penryn` for these targets.
- **Apple Silicon:** macOS 11.0 or later, natively. The x86_64 build also
  runs there under Rosetta 2, but the native build is 1.6 to 1.7 times as
  fast.
- **No libraries to ship.** GMP and BOINC are linked statically.
  `otool -L` should show only `/usr/lib/libSystem.B.dylib` and
  `/usr/lib/libc++.1.dylib`.
- **Load commands.** `otool -l` on x86_64 should show `LC_VERSION_MIN_MACOSX`
  version 10.13 and `LC_DYLD_INFO_ONLY`. A newer `LC_BUILD_VERSION` or chained
  fixups would mean the 10.13 minimum didn't reach the link. On arm64 it
  should show `LC_BUILD_VERSION` with minos 11.0.
- **Signing.** arm64 macOS runs only signed code, so the script re-signs
  ad hoc (`codesign -s - -f`) after `strip` and after `lipo`.
- **libc++ below macOS 11.** The current SDK's libc++ headers warn "The
  selected platform is no longer supported by libc++" below macOS 11. This
  only affects the C++ BOINC code in the x86_64 build. Check that nothing
  newer than 10.13 is imported:
  `dyld_info -imports <exe> | grep 'from libc++'` should list only long-standing
  string, iostream and exception symbols, with no `__libcpp_verbose_abort`,
  `to_chars` or `__hash_memory`.

## 7. Checking a build

Standalone, outside BOINC, exactly as on Windows:

```sh
mkdir t && cd t
cp ../nfs512_15300k_I14.job input_data
../boinc-mac/arm64/gnfs-lasieve4I14e -a -f 15300000 -c 200
wc -l output_data      # 539 relations
```

**x86_64.** It finds the same 539 relations as Linux and Windows. Its
`output_data` has MD5 `534e21a7169b402e2b35199075a7a633`; compare that with a
Linux `ARCH=x86-64 TUNE=generic` run. The arm64 changes leave it
byte-identical to the build before them.

**arm64.** It finds exactly the same relations as x86_64 on every test job,
but sometimes lists the primes of a relation in a different order, so the
files aren't byte-identical. To compare, sort each relation's prime lists.
The tests:
- I14 `nfs512` job, `-c 200`
- I15 SNFS job, `-c 100` (2540 MPQS runs)
- I16 `nfs631` job, `-c 60`
- I16 `R942_poly.txt` with `-r -f 325000000 -c 40`, where both builds
  ran MPQS 4669 times and MPQS3 1926 times

Throughput on a fanless MacBook Air M3 (4 performance and 4 efficiency
cores) with all cores busy. Eight jobs ran at once on disjoint special-q
ranges; the figures are relations per second, summed over the jobs:

| Job | arm64 | x86_64 (Rosetta) |
|---|---|---|
| I14 `nfs512`, 8 × `-c 300` | 236 | 140 |
| I16 `nfs631`, 8 × `-c 25` | 11.7 | 7.3 |

That's about 1.7 times the throughput of the x86_64 build under Rosetta
for 14e and 1.6 times for 16e. 16e would reach 12.6 with shift 2, at the
cost of memory (section 5). The untuned port, before the changes in
section 5, managed 175 and 9.4.

Single job:

| Job | arm64 | x86_64 (Rosetta) |
|---|---|---|
| I14 `nfs512`, `-c 200` | 13.8 s | 23.5 s |
| I16 `nfs631`, `-c 60` | 42.0 s, 391 MB | 68.3 s, 316 MB |
| I16 `R942`, `-c 100` | 142 s, 2.23 GB | 216 s, 1.94 GB |

Startup (building the factor base) is included in each single-job time.
For R942 that's about 53 s. The extra memory on arm64 comes from the larger
schedule regions (section 5).

**Instruction set (x86_64).** Nothing beyond SSE4.1 should appear outside
GMP's runtime-dispatched routines. Use the unstripped executable:

```sh
otool -tvV boinc-mac/build/x86_64-generic/gnfs-lasieve4I16e | awk '
  /^[_a-zA-Z.$][^ \t]*:$/ { fn = $1; next }
  fn ~ /^___gmpn_.*_(core2|coreinhm|coreisbr|coreihwl|coreibwl|skylake|atom|silvermont|goldmont|k8|k10|bd1|bd2|bd3|bd4|zen|zen2|zen3|bobcat|jaguar|nano|pentium4|p6|pentiumm)/ { next }
  $2 ~ /^(v[a-z0-9]+|popcnt[a-z]?|lzcnt[a-z]?|movbe[a-z]?|mulx[a-z]?|adcx[a-z]?|adox[a-z]?|andn[a-z]?|bextr[a-z]?|blsi[a-z]?|blsmsk[a-z]?|blsr[a-z]?|bzhi[a-z]?|pdep[a-z]?|pext[a-z]?|rorx[a-z]?|sarx[a-z]?|shlx[a-z]?|shrx[a-z]?|crc32[a-z]*|pcmp[ei]str[im]|pcmpgtq|aes[a-z]*|pclmul[a-z]*)$/ { n[fn " " $2]++ }
  END { for (k in n) print n[k], k }'
```

The expected output is nothing at all. `tzcnt` isn't listed, because CPUs
without BMI1 run it as `bsf`.

**Universal.** `boinc-mac/universal/gnfs-lasieve4I14e` should run natively on
Apple Silicon, and with `arch -x86_64` it should give the x86_64 MD5 above.

**Resume.** Kill a run partway (`kill -9`) and start it again in the same
directory. It should print " Dropped an incomplete last line" if the kill cut
a line, and then " Resuming with -f <the last special-q seen>". The relations
of that last special-q are written again; that's expected.

## 8. Packaging for NFS@Home

NFS@Home gets one universal file per app, registered under both Mac
platforms:

| Siever | App | Version 1.60 file |
|---|---|---|
| `gnfs-lasieve4I14e` | `lasieved` | `lasieved_1.60_universal-apple-darwin` |
| `gnfs-lasieve4I15e` | `lasievee` | `lasievee_1.60_universal-apple-darwin` |
| `gnfs-lasieve4I16e` | `lasieve5f` | `lasieve5f_1.60_universal-apple-darwin` |

```sh
sh package_boinc_mac.sh          # VERSION=1.60 and APPS=... to change
```

This writes `boinc-mac/apps/<app>/1.60/{x86_64,arm64}-apple-darwin/`, each
holding the file and a `version.xml` that marks it as the main program.

**Why one universal file works on both platforms.** The BOINC client starts
an app with `execv()` (`client/app_start.cpp`), directly or through the
`switcher`, and the kernel picks the slice:

- An Intel Mac runs the x86_64 slice.
- An Apple Silicon Mac with a native client (current BOINC clients are
  universal; 8.2 is) runs the arm64 slice, whichever of the two platforms
  the scheduler sent.
- A Rosetta-translated parent gets the x86_64 slice of a universal binary.
  So an old Intel-only client on Apple Silicon runs the x86_64 code, as it
  does today.
- An Apple Silicon Mac without Rosetta reports only `arm64-apple-darwin`.
  That's why the file is registered under that platform too.

`update_versions` copies the file into `download/` once and accepts the
second, identical copy. The only cost is size: 2.9 MB, against 2.0 MB for
x86_64 alone.

**Apple signing.** Each slice has an ad hoc signature (arm64 macOS runs only
signed code). Nothing more is needed: files the BOINC client downloads carry
no quarantine attribute, so Gatekeeper and notarization don't apply.

**BOINC code signing.** Sign each file with the project's code-signing key
on the signing machine, and put the `.sig` next to the file in both
platform directories:

```sh
sign_executable lasieve5f_1.60_universal-apple-darwin code_sign_private \
    > lasieve5f_1.60_universal-apple-darwin.sig
```

Then copy `boinc-mac/apps/*` into the project's `apps/` and run
`update_versions`.

**Testing under a real client.** BOINC's `client/app_test.cpp` runs one job
without a project. `boinc_app_test_lasieve.patch` adds a lasieve case to it:
the executable is `projects/app_test/lasieve`, the job file is
`projects/app_test/job_in` (logical name `input_data`), the output is
`output_data`, and the environment variable `LASIEVE_CMDLINE` is the work
unit's command line (`LASIEVE_MEMBOUND`, in bytes, sets its memory bound).

The autotools build doesn't support a macOS client: it leaves out
`hostinfo_unix.cpp` and links with `-undefined dynamic_lookup`, so the
client dies at launch on a missing `get_system_uptime`. After `configure`
(`--disable-server --disable-manager --enable-client --with-ssl=` Homebrew's
OpenSSL), remove `-Wl,-flat_namespace,-undefined,dynamic_lookup` from
`client/Makefile` and add `boinc_client-hostinfo_unix.$(OBJEXT)` to
`am_boinc_client_OBJECTS`. Run it in its own data directory with its own
`--gui_rpc_port` so it leaves an installed client alone, and with a
`global_prefs_override.xml` that sets `run_on_batteries` and
`run_if_user_active` on a laptop.

Checked this way with the 1.60 universal files under BOINC 8.3.0:

- 14e, `nfs512` `-a -f 15300000 -c 200`: 18 s on Apple Silicon, the same
  539 relations as a standalone run. The x86_64 slice under the same client
  (via Rosetta) took 28 s for the same 539.
- 16e, `nfs631` `-a -f 50000000 -c 60`: suspended with `boinccmd
  --set_run_mode never` (CPU time stayed still) and resumed; then the
  client quit mid-task, which stopped the app, and restarted. The task
  resumed from its output file and finished with the same 179 distinct
  relations as an uninterrupted run. Resume re-sieves the last special-q
  in the file, so the relations of that q appear twice (101 here); that's
  the same on every platform and goes away in filtering.
- The code in each universal slice is byte-identical to the single-arch
  build; only the ad hoc signatures differ.

## 9. Things that bit during the port

- **`fopen(..., "ab+")`.** Where reading starts in append-update mode is up to
  the C library. glibc and the Windows CRT start at the beginning of the file;
  macOS and the BSDs start at the end. So on a Mac, resume read nothing,
  re-sieved the whole range, and glued the first new relation onto the cut-off
  line. `gnfs-lasieve4e.c` now calls `rewind()` before reading.
- **GMP needs `--with-pic`** for x86_64 (see section 2).
- **`<immintrin.h>` also brings in `<stdlib.h>`.** `recurrence6.c` relied on
  that for `exit()`, so it failed to compile on arm64 until it included
  `<stdlib.h>` itself.
- **`-Ofast` overrides `-ffp-model=precise`.** The Makefile passes both to
  clang, and clang warns that `-Ofast` wins. So clang builds use fast-math,
  like gcc's `-Ofast`.
