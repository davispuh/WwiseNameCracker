#!/bin/sh

set -euo pipefail

LDC_ARGS="-mcpu=native -O3 -release -enable-inlining=1 --boundscheck=off --flto=full -fno-plt -L-no-pie --linker=gold crackNames.d"

if [ "$#" -eq 0 ]; then
    ldc $LDC_ARGS
    echo "Built regular build"
else
    ldc --fprofile-generate=/tmp/crackNames.profraw -of=./crackNames-profile $LDC_ARGS
    ./crackNames-profile "$@" &> /dev/null || true
    ldc-profdata merge /tmp/crackNames.profraw -output /tmp/crackNames.profdata
    rm -f /tmp/crackNames.profraw crackNames-profile crackNames-profile.o
    ldc -fprofile-use=/tmp/crackNames.profdata $LDC_ARGS
    echo "Built Profile-Guided Optimizated (PGO) build"
fi
