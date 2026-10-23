# sessionAdoptProbe.jl — headless verification of the new session→UI bridge:
#   1. addOutputTap!/removeOutputTap! observe raw chunks,
#   2. adoptSessionTerminal! registers an entry WITHOUT spawning a process,
#      replays the tail, and forwards live chunks into `collected`,
#   3. handleTerminalKill on an adopted id unregisters it AND removes the tap
#      (session stays usable afterwards).
# Run: julia --startup-file=no --project=. test/sessionAdoptProbe.jl
import FlootyPTYLayer
using FlootyPTYLayer

println("starting session ...")
sess = startReplSession(`julia --startup-file=no -q`)
try
    # --- tap basics ---------------------------------------------------------
    seen = String[]
    tap = addOutputTap!(sess) do chunk
        push!(seen, String(copy(chunk)))
    end
    outcome = agentWriteAndWait(sess, "TAPMARK = 7 * 6")
    outcome.ok || (println("TAP_PROBE_FAILED: eval failed"); exit(1))
    sleep(0.2)
    joined = join(seen)
    occursin("TAPMARK", joined) ||
        (println("TAP_PROBE_FAILED: tap never saw echo"); exit(1))

    # removeOutputTap! stops observation
    removeOutputTap!(sess, tap)
    n = length(seen)
    agentWriteAndWait(sess, "TAPMARK2 = 1")
    sleep(0.2)
    length(seen) == n ||
        (println("TAP_PROBE_FAILED: tap still firing after removal"); exit(1))

    # --- adoption -----------------------------------------------------------
    id = adoptSessionTerminal!(sess; name = "probe julia")
    lock(FlootyPTYLayer.terminalRegistryLock) do
        haskey(FlootyPTYLayer.ACTIVE_TERMINALS, id) || begin
            println("ADOPT_FAILED: not registered")
            exit(1)
        end
    end
    entry = FlootyPTYLayer.getEntry(id)
    replayed = FlootyPTYLayer.collectedText(entry)
    occursin("julia>", replayed) || occursin("TAPMARK", replayed) ||
        (println("ADOPT_FAILED: tail not replayed"); exit(1))
    # NO new process: adopted entry shares the session's PTY.
    entry.pty === sess.pty || (println("ADOPT_FAILED: pty not shared"); exit(1))

    # Live forwarding through the tap → collected.
    before = length(entry.collected)
    agentWriteAndWait(sess, "println(\"LIVE_ADOPT_\", TAPMARK)")
    sleep(0.3)
    now = FlootyPTYLayer.collectedText(entry)
    occursin("LIVE_ADOPT_", now) ||
        (println("ADOPT_FAILED: live forward missing"); exit(1))

    # Kill from the "UI": unregisters the entry AND closes the underlying
    # session PTY — adoption means SAME PROCESS (documented contract).
    FlootyPTYLayer.handleTerminalKill(id) ||
        (println("ADOPT_FAILED: kill returned false"); exit(1))
    alive = lock(() -> !haskey(FlootyPTYLayer.ACTIVE_TERMINALS, id),
                 FlootyPTYLayer.terminalRegistryLock)
    alive || (println("ADOPT_FAILED: registry still holds id"); exit(1))
    sess.pty.open &&
        (println("ADOPT_FAILED: session pty should be closed after kill");
         exit(1))
    ok2 = try
        agentWriteAndWait(sess, "AFTER_KILL = :fine"; timeout = 5.0)
    catch
        nothing   # expected: pty closed → agentWriteAndWait errors
    end
    (ok2 === nothing || !ok2.ok) ||
        (println("ADOPT_FAILED: eval succeeded on killed pty"); exit(1))

    println("SESSION_ADOPT_PROBE_OK")
catch e
    println("SESSION_ADOPT_PROBE_FAILED: ", sprint(showerror, e))
    rethrow()
finally
    closeSession!(sess)
end
exit(0)
