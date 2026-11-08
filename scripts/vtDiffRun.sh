#!/bin/sh
# Compare ShadowTerminal against xterm.js for the corpus in scripts/vtDiffCorpus.txt.
# Requires @xterm/headless to be resolvable via NODE_PATH (e.g. install into a
# scratch dir and export NODE_PATH) or run in that dir.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
julia --startup-file=no --project="$HERE/.." "$HERE/vtDiffProbe.jl"
node "$HERE/vtDiffCompare.cjs"
diff "$HERE/shadow.txt" "$HERE/xterm.txt" && echo VT_IDENTICAL
