#!/usr/bin/env bash
#
# mayhem/build.sh — build aide's fuzz targets and its test suite.
#
#  1. autogen (only when ./configure is missing; it is gitignored, so a cleaned tree regenerates it)
#  2. mayhem/build-fuzz: aide with $SANITIZER_FLAGS $DEBUG_FLAGS + SanCov (-fsanitize=fuzzer-no-link)
#     -> mayhem/out/aide_{compare,list,config}: aide's own objects with main() renamed
#        (objcopy) + mayhem/aide_fuzz_main.c, a file-input driver (one input file per process).
#  3. mayhem/build-test: aide + upstream's check_aide unit suite with the project's NORMAL flags,
#     for mayhem/test.sh.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
M="$SRC/mayhem"
CONFIGURE_OPTS=(--without-gcrypt --with-nettle --with-zlib --with-xattr --with-posix-acl
                --without-curl --without-selinux --without-audit --without-e2fsattrs
                --without-capabilities)

# 1) autotools bootstrap. version.sh runs `git describe`, which fails when the tree belongs to
#    another uid (git's safe.directory check) — so supply the version when git cannot.
if [ ! -x configure ]; then
    if [ -z "${GIT_VERSION:-}" ]; then
        GIT_VERSION="$(git describe --always 2>/dev/null || echo 0.19-mayhem)"
    fi
    export GIT_VERSION
    sh ./autogen.sh
fi

# 2) Sanitized + SanCov build of aide.
FUZZ_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1"
mkdir -p "$M/build-fuzz" "$M/out"
cd "$M/build-fuzz"
if [ ! -f config.status ]; then
    "$SRC/configure" "${CONFIGURE_OPTS[@]}" CC="$CC" CFLAGS="$FUZZ_CFLAGS" LDFLAGS="$FUZZ_CFLAGS" \
        CPPFLAGS="-I$M/build-fuzz/src"
fi
# `all` (not just `aide`) so BUILT_SOURCES (bison's src/conf_yacc.h) is generated first; in this
# out-of-tree build it lands in build-fuzz/src, hence the CPPFLAGS above.
make -j"$MAYHEM_JOBS" all

# aide is a single program: link its objects (main renamed) with the file-input driver.
mkvar() { make -s -f Makefile -f "$M/print-var.mk" "print-$1"; }
OBJS=()
for o in $(mkvar aide_OBJECTS); do
    if [ "$o" = src/aide-aide.o ]; then
        objcopy --redefine-sym main=aide_original_main "$o" "$M/build-fuzz/aide-main-renamed.o"
        OBJS+=("$M/build-fuzz/aide-main-renamed.o")
    else
        OBJS+=("$M/build-fuzz/$o")
    fi
done
# shellcheck disable=SC2207
LIBS_ALL=($(mkvar aide_LDADD) $(mkvar LIBS))
$CC $FUZZ_CFLAGS -c "$M/lsan_off.c" -o "$M/build-fuzz/lsan_off.o"
for t in compare:1 list:2 config:3; do
    name="aide_${t%%:*}"; mode="${t##*:}"
    $CC $FUZZ_CFLAGS -DAIDE_FUZZ_MODE="$mode" -c "$M/aide_fuzz_main.c" -o "$M/build-fuzz/$name-main.o"
    $CC $FUZZ_CFLAGS -o "$M/out/$name" "$M/build-fuzz/$name-main.o" "${OBJS[@]}" \
        "$M/build-fuzz/lsan_off.o" "${LIBS_ALL[@]}"
done

# 3) Normal-flags build of aide + upstream's libcheck unit suite (the functional oracle).
mkdir -p "$M/build-test"
cd "$M/build-test"
if [ ! -f config.status ]; then
    env -u CFLAGS -u LDFLAGS "$SRC/configure" "${CONFIGURE_OPTS[@]}" \
        CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" CPPFLAGS="-I$M/build-test/src"
fi
make -j"$MAYHEM_JOBS" all
make -j"$MAYHEM_JOBS" check_aide
cp -f aide "$M/out/aide" && cp -f check_aide "$M/out/check_aide"
ls -l "$M/out"
