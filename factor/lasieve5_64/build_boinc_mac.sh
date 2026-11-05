#!/bin/sh
# Build the macOS BOINC sievers gnfs-lasieve4I{14,15,16}e, for Intel and
# Apple Silicon Macs.
#
#   x86_64  clang -arch x86_64 -mmacosx-version-min=10.13 -march=penryn
#           -mtune=generic, with the x86-64 assembly in asm/.
#           10.13 is the oldest macOS that BOINC's own Mac builds target.
#           macOS 10.12 and later run only on Penryn or newer CPUs (SSE4.1),
#           which is why clang already defaults to -march=penryn for these
#           targets; GMP and the BOINC libraries get that default, and the
#           siever uses it explicitly.
#   arm64   clang -arch arm64 -mmacosx-version-min=11.0 (clang's default CPU
#           for this target is the M1).  asm/ is x86-64 only, so this uses
#           the C versions of those routines (siever-config.h, mpqs-config.h,
#           asm/c-arith.c).  11.0 is the first macOS for Apple Silicon.
#
# Run on a Mac with the Xcode command line tools and m4.  X86_64_PREFIX and
# ARM64_PREFIX must each hold a static GMP (include/gmp.h, lib/libgmp.a) and
# BOINC's libboinc.a and libboinc_api.a (include/boinc, lib), built for that
# architecture and deployment target.  GMP for x86_64 should be a fat build
# (--enable-fat --with-pic) so it picks its CPU-specific code at run time.
# See BOINC_MAC.md.
#
# Usage: X86_64_PREFIX=... ARM64_PREFIX=... sh build_boinc_mac.sh [outdir]
#        ARCHS="x86_64" or ARCHS="arm64" builds just one.
#
# Output (stripped, ad-hoc signed):
#   <outdir>/x86_64/gnfs-lasieve4I<n>e      Intel
#   <outdir>/arm64/gnfs-lasieve4I<n>e       Apple Silicon
#   <outdir>/universal/gnfs-lasieve4I<n>e   both in one file (lipo), when
#                                           both are built
#   <outdir>/build/<arch>-generic/          the build trees, unstripped
#
# Each flavour is built in its own copy of this directory, so the source tree
# (which carries prebuilt Linux binaries named gnfs-lasieve4I1*e) is never
# touched by make clean.
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$SRC/boinc-mac}
SIZES=${SIZES:-"14 15 16"}
ARCHS=${ARCHS:-"x86_64 arm64"}
MACOS_MIN_X86_64=${MACOS_MIN_X86_64:-10.13}
MACOS_MIN_ARM64=${MACOS_MIN_ARM64:-11.0}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}

for arch in $ARCHS; do
    case $arch in
        x86_64) prefix=$X86_64_PREFIX ;;
        arm64)  prefix=$ARM64_PREFIX ;;
        *) echo "unknown arch $arch" >&2; exit 1 ;;
    esac
    [ -n "$prefix" ] || { echo "set ${arch}_PREFIX" | tr a-z A-Z >&2; exit 1; }
    for f in "$prefix/include/boinc/boinc_api.h" "$prefix/lib/libboinc_api.a" \
             "$prefix/lib/libboinc.a" "$prefix/include/gmp.h" "$prefix/lib/libgmp.a"; do
        [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
    done
    if [ "$(lipo -archs "$prefix/lib/libgmp.a")" != "$arch" ]; then
        echo "$prefix/lib/libgmp.a is not $arch" >&2; exit 1
    fi
done

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# build_flavour <name> <prefix> <outsubdir> <target flags> [make vars...]
build_flavour() {
    name=$1 prefix=$2 sub=$3 tflags=$4; shift 4
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
             GMP_INCDIR="$prefix/include" GMP_LIBDIR="$prefix/lib" BOINC=1 \
             BOINC_INC_DIR="$prefix/include/boinc" BOINC_LIB_DIR="$prefix/lib" \
             "$@" asm/liblasieve.a > build.log 2>&1 &&
        make -j"$JOBS" CC=clang CXX=clang++ TARGET_FLAGS="$tflags" \
             GMP_INCDIR="$prefix/include" GMP_LIBDIR="$prefix/lib" BOINC=1 \
             BOINC_INC_DIR="$prefix/include/boinc" BOINC_LIB_DIR="$prefix/lib" \
             "$@" $targets >> build.log 2>&1) || {
        echo "build failed, see $bdir/build.log" >&2
        grep -E "error" "$bdir/build.log" | head -20 >&2
        exit 1
    }
    for s in $SIZES; do
        f="$OUT/$sub/gnfs-lasieve4I${s}e"
        strip -o "$f" "$bdir/gnfs-lasieve4I${s}e"
        codesign -s - -f "$f" 2>/dev/null   # arm64 macOS runs only signed code
    done
    echo "    $(grep -c 'warning:' "$bdir/build.log") compiler warnings"
}

for arch in $ARCHS; do
    case $arch in
        x86_64) build_flavour x86_64-generic "$X86_64_PREFIX" x86_64 \
                    "-arch x86_64 -mmacosx-version-min=$MACOS_MIN_X86_64" \
                    ARCH=penryn TUNE=generic ;;
        arm64)  build_flavour arm64-generic "$ARM64_PREFIX" arm64 \
                    "-arch arm64 -mmacosx-version-min=$MACOS_MIN_ARM64" \
                    ARCH= TUNE= ;;
    esac
done

has_arch() { case " $ARCHS " in *" $1 "*) return 0 ;; esac; return 1; }
if has_arch x86_64 && has_arch arm64; then
    echo "=== universal"
    mkdir -p "$OUT/universal"
    for s in $SIZES; do
        f="$OUT/universal/gnfs-lasieve4I${s}e"
        lipo -create -output "$f" "$OUT/x86_64/gnfs-lasieve4I${s}e" \
            "$OUT/arm64/gnfs-lasieve4I${s}e"
        codesign -s - -f "$f" 2>/dev/null
    done
fi

# minimum macOS of each architecture in a file
minos() {
    for a in $(lipo -archs "$1"); do
        printf ' %s:%s' "$a" "$(otool -arch "$a" -l "$1" |
            awk '/LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION/ {v=1} v && /version|minos/ {print $2; exit}')"
    done
}
for d in x86_64 arm64 universal; do
    [ -d "$OUT/$d" ] || continue
    for f in "$OUT/$d"/gnfs-lasieve4I*e; do
        printf '%s/%s: macOS%s\n' "$d" "$(basename "$f")" "$(minos "$f")"
    done
done
