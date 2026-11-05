#!/bin/sh
# Build the Windows x86_64 BOINC sievers gnfs-lasieve4I{14,15,16}e.
#
# Each siever is built in two flavours:
#   generic  -march=x86-64    -mtune=generic             (any x86_64 CPU)
#   avx512   -march=x86-64-v4 -mtune=generic AVX512_ALL=1 (AVX-512 F/BW/CD/DQ/VL)
# and the two are then linked into ONE executable that picks the AVX-512 or
# generic code path at startup (see cpu_dispatch.c; --cpu=auto|generic|avx512
# overrides the choice).  That combined executable is the deliverable.
#
# Run from an MSYS2 UCRT64 shell (gcc, m4, make, binutils, static GMP in /ucrt64).
# BOINC_PREFIX must point at a MinGW build of the BOINC libraries, as made by
# BOINC's lib/Makefile.mingw "install" target (include/boinc and lib).
#
# Usage: BOINC_PREFIX=/path/to/boinc-install sh build_boinc_windows.sh [outdir]
#
# Output (all stripped):
#   <outdir>/gnfs-lasieve4I<n>e.exe          combined, dispatching executables
#   <outdir>/{generic,avx512}/...exe         single-flavour builds, for testing
#
# Each flavour is built in its own copy of this directory under
# <outdir>/build/<flavour>, so the source tree (which carries prebuilt Linux
# binaries named gnfs-lasieve4I1*e) is never touched by make clean.
#
# Combining: the Makefile's gnfs-lasieve4I<n>e.ro target partially links each
# flavour (everything but GMP, BOINC and the C runtime) into one relocatable
# object.  The generic copy's main is renamed lasieve_main_generic; in the
# AVX-512 copy every global symbol it defines is prefixed avx512_ (main
# becomes lasieve_main_avx512), so the two copies share nothing but the
# libraries.  GMP is one shared copy; it dispatches on the CPU by itself.
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
    for s in $SIZES; do targets="$targets gnfs-lasieve4I${s}e gnfs-lasieve4I${s}e.ro"; done

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

combine() {
    s=$1
    c="$OUT/build/combined"
    g="$c/generic_I$s.ro"; a="$c/avx512_I$s.ro"
    objcopy --redefine-sym main=lasieve_main_generic \
        "$OUT/build/generic/gnfs-lasieve4I${s}e.ro" "$g"
    # every global symbol the AVX-512 copy defines (nm types in upper case,
    # except U = undefined)
    nm -g "$OUT/build/avx512/gnfs-lasieve4I${s}e.ro" |
        awk 'NF >= 3 && $(NF-1) ~ /^[A-TV-Z]$/ { print $NF }' | sort -u |
        awk '$1 == "main" { print "main lasieve_main_avx512"; next }
             { print $1 " avx512_" $1 }' > "$c/avx512_I$s.map"
    objcopy --redefine-syms="$c/avx512_I$s.map" \
        "$OUT/build/avx512/gnfs-lasieve4I${s}e.ro" "$a"
    # MinGW records the alignment of each common symbol as a linker directive,
    # -aligncomm:"name",log2, in .drectve -- by name, so objcopy's renaming
    # does not reach it.  Rename those too, or the AVX-512 copy's commons
    # lose their alignment (a 32-byte-aligned jmp_buf ended up at ...eec and
    # setjmp faulted).  The compiler only emits these for commons the object
    # defines, all of which are in the map.
    objcopy -O binary --only-section=.drectve "$a" "$c/avx512_I$s.drectve"
    LC_ALL=C sed 's/-aligncomm:"\([^"]*\)"/-aligncomm:"avx512_\1"/g' \
        "$c/avx512_I$s.drectve" > "$c/avx512_I$s.drectve.new"
    objcopy --update-section .drectve="$c/avx512_I$s.drectve.new" "$a"
    g++ -static -o "$c/gnfs-lasieve4I${s}e.exe" "$c/cpu_dispatch.o" "$g" "$a" \
        "$GMP_PREFIX/lib/libgmp.a" -L"$BOINC_PREFIX/lib" -lboinc_api -lboinc -lpsapi -lm
    strip -o "$OUT/gnfs-lasieve4I${s}e.exe" "$c/gnfs-lasieve4I${s}e.exe"
    echo "    I$s: $(wc -l < "$c/avx512_I$s.map") AVX-512 symbols renamed"
}

build_flavour generic ARCH=x86-64 TUNE=generic
build_flavour avx512  ARCH=x86-64-v4 TUNE=generic AVX512_ALL=1

echo "=== combined"
rm -rf "$OUT/build/combined"; mkdir -p "$OUT/build/combined"
# baseline x86-64: the dispatcher runs before either copy is chosen
gcc -O2 -Wall -march=x86-64 -mtune=generic -c -o "$OUT/build/combined/cpu_dispatch.o" \
    "$SRC/cpu_dispatch.c"
for s in $SIZES; do combine "$s"; done

ls -l "$OUT"/*.exe "$OUT"/generic/*.exe "$OUT"/avx512/*.exe
