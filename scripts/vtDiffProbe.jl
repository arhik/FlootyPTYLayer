# vtDiffProbe.jl — headless ShadowTerminal vs xterm.js screen comparison.
# Runs ShadowTerminal over the corpus in vtDiffCorpus.txt, dumps its screens
# in corpus order to shadow.txt, and a companion Node script (compare.cjs,
# requires @xterm/headless) dumps xterm screens to xterm.txt. `diff` must be
# empty for this to have "quantified" Phase B fidelity.
#
# Prereqs: npm install @xterm/headless into a writable dir (or set
# FLOOTY_VT_DIFF_DIR). Produces shadow.txt / xterm.txt next to this file.
#
# Run: julia --startup-file=no --project=. scripts/vtDiffProbe.jl
using FlootyPTYLayer
const S = FlootyPTYLayer.ShadowTerminal
const HERE = @__DIR__
const CORPUS = joinpath(HERE, "vtDiffCorpus.txt")

open(joinpath(HERE, "shadow.txt"), "w") do io
    for line in eachline(CORPUS)
        isempty(strip(line)) && continue
        t = S.ShadowTerm(40, 8)
        S.shadowFeed!(t, hex2bytes(strip(line)))
        println(io, "=== ", strip(line))
        for l in S.shadowLines(t)
            println(io, rstrip(l))
        end
    end
end
println("wrote shadow.txt — run compare.cjs + diff vs scripts/shadow.txt")
exit(0)
