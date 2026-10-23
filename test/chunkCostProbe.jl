# chunkCostProbe.jl — the PER-CHUNK sink cost must not scale with the size of
# the rolling output tail.
#
# `sessionReaderLoop` runs three sinks on every PTY chunk: the OSC 133 scan,
# the sentinel parse, and (when adopted) the UI push. The sentinel parse used
# to re-read and re-scan the WHOLE tail (up to 1 MiB) on every chunk, so a busy
# session paid a tail-sized cost per chunk. This probe drives ~4 KiB and then
# ~512 KiB of output through a real session and measures `@allocated` for ONE
# internal chunk step at each size; the ratio must stay near 1.
#
# Run: julia --startup-file=no --project=. test/chunkCostProbe.jl
using FlootyPTYLayer

const F = FlootyPTYLayer

"One reader-loop sink step, as `sessionReaderLoop` runs it for a fresh chunk."
function chunkStep(sess)
    chunk = Vector{UInt8}(codeunits("x\n"))
    return @allocated begin
        F.processOsc133!(sess, chunk)
        F.notifySentinels!(sess)
    end
end

"Push `nBytes` of output through a real eval so it lands in the tail."
pushBytes(sess, nBytes) =
    F.agentWriteAndWait(sess, "print(\"x\" ^ $nBytes)"; timeout = 180.0)

sess = F.startReplSession(`julia --startup-file=no -q -i`)
try
    # Warm up: JIT the sinks and let the OSC raw window reach its cap so both
    # measurements carry the SAME constant overhead.
    F.agentWriteAndWait(sess, "1 + 1"; timeout = 60.0)

    pushBytes(sess, 4 * 1024)
    small = chunkStep(sess)

    pushBytes(sess, 512 * 1024)
    large = chunkStep(sess)

    ratio = small == 0 ? Inf : large / small
    println("[CHUNK-COST] {\"small\":", small, ",\"large\":", large,
            ",\"ratio\":", round(ratio; digits = 3), "}")
    if ratio < 4
        println("CHUNK_COST_PROBE_OK (per-chunk cost independent of tail size)")
    else
        println("CHUNK_COST_PROBE_FAILED: per-chunk allocations scale with the tail")
        exit(1)
    end
finally
    F.closeSession!(sess)
end
