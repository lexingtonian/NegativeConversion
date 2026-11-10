#!/bin/bash
# Times one full-size conversion of a real raw file in an optimised (release)
# and an unoptimised (debug) build. Results go to timing.log.
cd "$(dirname "$0")"
F="${1:-$(find ~/Documents/colorconvtmp -maxdepth 1 -type f \( -iname '*.arw' -o -iname '*.dng' \) | head -1)}"
OUT=.build/timing
{
  echo "file: $F"
  swift build -c release --product NegativeConverter >/dev/null 2>&1 || echo "release build failed"
  swift build -c debug   --product NegativeConverter >/dev/null 2>&1 || echo "debug build failed"
  for cfg in release debug; do
    BIN="$(swift build -c $cfg --show-bin-path)/NegativeConverter"
    echo "== $cfg"
    rm -rf "$OUT/$cfg"; mkdir -p "$OUT/$cfg"
    /usr/bin/time -p "$BIN" --export jpeg "$OUT/$cfg" "$F" 2>&1
  done
} > timing.log 2>&1
cat timing.log
