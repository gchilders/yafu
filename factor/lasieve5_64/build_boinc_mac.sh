#!/bin/sh
# Build the macOS BOINC sievers gnfs-lasieve4I{14,15,16}e.
#
# For now this builds the Intel (x86_64-apple-darwin) generic flavour:
#   clang -arch x86_64 -mmacosx-version-min=10.13 -march=penryn -mtune=generic
# 10.13 is the oldest macOS that BOINC's own Mac builds target.  macOS 10.12
# and later run only on Penryn or newer CPUs (SSE4.1), which is why clang
# already defaults to -march=penryn for these targets; GMP and the BOINC
# libraries get that default, and the siever uses it explicitly.
#
# Run on a Mac with the Xcode command line tools and m4.  The prefixes must
# hold a static GMP (include/gmp.h, lib/libgmp.a) and BOINC's libboinc.a and
# libboinc_api.a (include/boinc, lib), all built for the same architecture
# and deployment target.  GMP for x86_64 should be a fat build
# (--enable-fat --with-pic) so it picks its CPU-specific code at run time.
#
# Usage: GMP_PREFIX=... BOINC_PREFIX=... sh build_boinc_mac.sh [outdir]
#        (PREFIX=... sets both)
#
# Output (stripped, ad-hoc signed):
#   <outdir>/x86_64/gnfs-lasieve4I<n>e
#   <outdir>/build/x86_64-generic/   the build tree, unstripped binaries
#
# Each flavour is built in its own copy of this directory, so the source tree
# (which carries prebuilt Linux binaries named gnfs-lasieve4I1*e) is never
# touched by make clean.
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$SRC/boinc-mac}
SIZES=${SIZES:-"14 15 16"}
GMP_PREFIX=${GMP_PREFIX:-$PREFIX}
BOINC_PREFIX=${BOINC_PREFIX:-$PREFIX}
MACOS_MIN_X86_64=${MACOS_MIN_X86_64:-10.13}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}

if [ -z "$GMP_PREFIX" ] || [ -z "$BOINC_PREFIX" ]; then
    echo "set PREFIX, or GMP_PREFIX and BOINC_PREFIX" >&2
    exit 1
fi
for f in "$BOINC_PREFIX/include/boinc/boinc_api.h" "$BOINC_PREFIX/lib/libboinc_api.a" \
         "$BOINC_PREFIX/lib/libboinc.a" "$GMP_PREFIX/include/gmp.h" "$GMP_PREFIX/lib/libgmp.a"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# build_flavour <name> <arch> <outsubdir> <target flags> [make vars...]
build_flavour() {
    name=$1 arch=$2 sub=$3 tflags=$4; shift 4
    bdir="$OUT/build/$name"
    echo "=== $name: $tflags $*"
    rm -rf "$bdir"
    mkdir -p "$bdir" "$OUT/$sub"
    # Copy the sources, leaving out prebuilt binaries and any output tree.
    (cd "$SRC" && tar --exclude=./bin --exclude='./gnfs-lasieve4I1*' \
        --exclude=./boinc-win --exclude=./boinc-mac --exclude="./$(basename "$OUT")" -cf - .) |
        (cd "$bdir" && tar -xf -)

    targets=""
    for s in $SIZES; do targets="$targets gnfs-lasieve4I${s}e"; done

    # The shared asm library first, so the per-I asm sub-makes that run in
    # parallel afterwards don't race on its generated files.
    (cd "$bdir" &&
        make CC=clang CXX=clang++ TARGET_FLAGS="$tflags" \
             GMP_INCDIR="$GMP_PREFIX/include" GMP_LIBDIR="$GMP_PREFIX/lib" BOINC=1 \
             BOINC_INC_DIR="$BOINC_PREFIX/include/boinc" BOINC_LIB_DIR="$BOINC_PREFIX/lib" \
             "$@" asm/liblasieve.a > build.log 2>&1 &&
        make -j"$JOBS" CC=clang CXX=clang++ TARGET_FLAGS="$tflags" \
             GMP_INCDIR="$GMP_PREFIX/include" GMP_LIBDIR="$GMP_PREFIX/lib" BOINC=1 \
             BOINC_INC_DIR="$BOINC_PREFIX/include/boinc" BOINC_LIB_DIR="$BOINC_PREFIX/lib" \
             "$@" $targets >> build.log 2>&1) || {
        echo "build failed, see $bdir/build.log" >&2
        grep -E "error" "$bdir/build.log" | head -20 >&2
        exit 1
    }
    for s in $SIZES; do
        f="$OUT/$sub/gnfs-lasieve4I${s}e"
        strip -o "$f" "$bdir/gnfs-lasieve4I${s}e"
        codesign -s - -f "$f" 2>/dev/null
    done
    echo "    $(grep -c 'warning:' "$bdir/build.log") compiler warnings"
}

build_flavour x86_64-generic x86_64 x86_64 \
    "-arch x86_64 -mmacosx-version-min=$MACOS_MIN_X86_64" ARCH=penryn TUNE=generic

for f in "$OUT"/x86_64/gnfs-lasieve4I*e; do
    printf '%s: %s, macOS %s+\n' "$(basename "$f")" "$(lipo -archs "$f")" \
        "$(otool -l "$f" | awk '/LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION/ {v=1} v && /version|minos/ {print $2; exit}')"
done
ls -l "$OUT"/x86_64/
