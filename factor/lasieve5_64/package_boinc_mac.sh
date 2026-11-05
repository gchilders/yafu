#!/bin/sh
# Lay out the universal macOS sievers as BOINC app versions for
# update_versions.
#
# Usage: sh package_boinc_mac.sh [bindir [outdir]]
#   bindir  holds universal/gnfs-lasieve4I{14,15,16}e (default boinc-mac,
#           as written by build_boinc_mac.sh)
#   outdir  default <bindir>/apps
# Environment:
#   VERSION  app version (default 1.60)
#   APPS     "I:appname ..." (default "14:lasieved 15:lasievee 16:lasieve5f")
#
# Each app gets the same universal file under two platforms:
#   <outdir>/<app>/<VERSION>/x86_64-apple-darwin/<app>_<VERSION>_universal-apple-darwin
#   <outdir>/<app>/<VERSION>/arm64-apple-darwin/<app>_<VERSION>_universal-apple-darwin
# Intel Macs run its x86_64 slice. Apple Silicon Macs run the arm64 slice
# natively whichever platform the scheduler picks, because the BOINC client
# starts apps with execv() and the kernel chooses the slice. The arm64
# platform is there for Apple Silicon hosts without Rosetta, which don't
# report x86_64-apple-darwin. update_versions copies the file to download/
# once; the second copy is accepted because it is identical.
#
# Code signing: sign each file on the signing machine with the project's
# code-signing key, e.g.
#   sign_executable <file> code_sign_private > <file>.sig
# and put the .sig next to the file in both platform directories before
# running update_versions.
set -e
BIN=${1:-boinc-mac}
OUT=${2:-$BIN/apps}
VERSION=${VERSION:-1.60}
APPS=${APPS:-"14:lasieved 15:lasievee 16:lasieve5f"}

for pair in $APPS; do
    I=${pair%%:*}; APP=${pair#*:}
    SRC="$BIN/universal/gnfs-lasieve4I${I}e"
    [ -f "$SRC" ] || { echo "missing $SRC (run build_boinc_mac.sh)"; exit 1; }
    [ "$(lipo -archs "$SRC")" = "x86_64 arm64" ] ||
        { echo "$SRC is not a universal x86_64+arm64 binary"; exit 1; }
    codesign -v --arch x86_64 "$SRC" && codesign -v --arch arm64 "$SRC" ||
        { echo "$SRC: bad code signature"; exit 1; }
    F=${APP}_${VERSION}_universal-apple-darwin
    for plat in x86_64-apple-darwin arm64-apple-darwin; do
        D="$OUT/$APP/$VERSION/$plat"
        mkdir -p "$D"
        cp "$SRC" "$D/$F"
        chmod 755 "$D/$F"
        cat > "$D/version.xml" <<EOF
<version>
    <file>
        <physical_name>$F</physical_name>
        <main_program/>
    </file>
</version>
EOF
    done
    echo "$APP $VERSION (I${I}e): $F  md5 $(md5 -q "$SRC")  $(stat -f %z "$SRC") bytes"
done
echo "Packaged in $OUT. Each file still needs a .sig (see the comments above)."
