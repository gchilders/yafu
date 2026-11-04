#!/bin/sh
# Build the Windows x86_64 BOINC sievers gnfs-lasieve4I{14,15,16}e in two
# flavours:
#   generic  -march=x86-64    -mtune=generic             (any x86_64 CPU)
#   avx512   -march=x86-64-v4 -mtune=generic AVX512_ALL=1 (AVX-512 F/BW/CD/DQ/VL)
#
# Run from an MSYS2 UCRT64 shell (gcc, m4, make, static GMP in /ucrt64).
# BOINC_PREFIX must point at a MinGW build of the BOINC libraries, as made by
# BOINC's lib/Makefile.mingw "install" target (include/boinc and lib).
#
# Usage: BOINC_PREFIX=/path/to/boinc-install sh build_boinc_windows.sh [outdir]
#
# Each flavour is built in its own copy of this directory under
# <outdir>/build/<flavour>, so the source tree (which carries prebuilt Linux
# binaries named gnfs-lasieve4I1*e) is never touched by make clean.  Stripped
# executables land in <outdir>/<flavour>/.
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$SRC/boinc-win}
SIZES="14 15 16"
GMP_PREFIX=${GMP_PREFIX:-/ucrt64}
JOBS=${JOBS:-16}

if [ -z "$BOINC_PREFIX" ]; then
    echo "set BOINC_PREFIX to the MinGW BOINC install (with include/boinc and lib)" >&2
    exit 1
fi
for f in "$BOINC_PREFIX/include/boinc/boinc_api.h" "$BOINC_PREFIX/lib/libboinc_api.a" \
         "$BOINC_PREFIX/lib/libboinc.a" "$GMP_PREFIX/lib/libgmp.a"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

build_flavour() {
    flavour=$1; shift
    bdir="$OUT/build/$flavour"
    echo "=== $flavour: $*"
    rm -rf "$bdir"
    mkdir -p "$bdir" "$OUT/$flavour"
    # Copy the sources, leaving out prebuilt binaries and any output tree.
    (cd "$SRC" && tar --exclude=./bin --exclude='./gnfs-lasieve4I1*' \
        --exclude=./boinc-win --exclude="./$(basename "$OUT")" -cf - .) |
        (cd "$bdir" && tar -xf -)

    vars="GMP_INCDIR=$GMP_PREFIX/include GMP_LIBDIR=$GMP_PREFIX/lib BOINC=1 \
          BOINC_INC_DIR=$BOINC_PREFIX/include/boinc BOINC_LIB_DIR=$BOINC_PREFIX/lib $*"
    targets=""
    for s in $SIZES; do targets="$targets gnfs-lasieve4I${s}e"; done

    # The shared asm library first, so the per-I asm sub-makes that run in
    # parallel afterwards don't race on its generated files.
    (cd "$bdir" && make $vars asm/liblasieve.a > build.log 2>&1 &&
                   make -j"$JOBS" $vars $targets >> build.log 2>&1) || {
        echo "build failed, see $bdir/build.log" >&2
        grep -E "error" "$bdir/build.log" | head -20 >&2
        exit 1
    }
    for s in $SIZES; do
        strip -o "$OUT/$flavour/gnfs-lasieve4I${s}e.exe" "$bdir/gnfs-lasieve4I${s}e.exe"
    done
    echo "    $(grep -c 'warning:' "$bdir/build.log") compiler warnings"
}

build_flavour generic ARCH=x86-64 TUNE=generic
build_flavour avx512  ARCH=x86-64-v4 TUNE=generic AVX512_ALL=1

ls -l "$OUT"/generic/*.exe "$OUT"/avx512/*.exe
