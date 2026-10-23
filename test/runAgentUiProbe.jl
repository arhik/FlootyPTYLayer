# runAgentUiProbe.jl — verify the agent-feedback POPUP channel end-to-end in
# the real WebView UI:
#   1. FLOOTY_AGENT_POPUP_PROBE=1 makes flootyUiReady push two synthetic
#      popups (dispatch+eval!) and tell the page to linger ~2s.
#   2. index.html renders them (glass stack) and acks each via the
#      flootyAgentPopupShown binding → "[agent-popup-shown]" on stdout.
#   3. The page then performs the proven native autoclose path; the loop must
#      unwind cleanly with an empty registry and stopped asset server.
#
# Run: julia --startup-file=no --project=. test/runAgentUiProbe.jl [timeoutS]
import FlootyPTYLayer
using FlootyPTYLayer

timeoutS = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 60.0

ENV["FLOOTY_UI_AUTOCLOSE"] = "1"
ENV["FLOOTY_AGENT_POPUP_PROBE"] = "1"

println("loading OK; launching UI for popup probe ...")
wv = try
    launchTerminalUI()
catch e
    println("LAUNCH_FAILED: ", sprint(showerror, e))
    exit(1)
end
println("launch returned handle type: ", typeof(wv))

id = try
    FlootyPTYLayer.handleTerminalCreate(`sh -c "echo AGENT_UI_MARKER; sleep 300"`)
catch e
    println("CREATE_FAILED: ", sprint(showerror, e))
    FlootyPTYLayer.stopTerminalUI()
    exit(1)
end
sleep(1.0)
entry = nothing
lock(() -> (global entry = get(FlootyPTYLayer.ACTIVE_TERMINALS, id, nothing)),
     FlootyPTYLayer.terminalRegistryLock)
txt = entry === nothing ? "" : FlootyPTYLayer.collectedText(entry)
println("collected contains marker: ", occursin("AGENT_UI_MARKER", txt))

t = @async begin
    deadline = time() + timeoutS
    while time() < deadline && FlootyPTYLayer.terminalUiRunning[]
        sleep(0.25)
    end
    if time() >= deadline && FlootyPTYLayer.terminalUiRunning[]
        println("WATCHDOG: event loop still running after ", timeoutS,
                "s — failing")
        exit(42)
    end
end

println("entering event loop (popups should appear then autoclose) ...")
FlootyPTYLayer.runEventLoopAndTeardown!(wv)
wait(t)

alive = lock(() -> isempty(FlootyPTYLayer.ACTIVE_TERMINALS),
             FlootyPTYLayer.terminalRegistryLock)
serverStopped = FlootyPTYLayer.terminalUiAssetServer[] === nothing
println("registry empty after run: ", alive)
println("asset server stopped: ", serverStopped)
(alive && serverStopped && occursin("AGENT_UI_MARKER", txt)) || exit(1)

# NOTE: [agent-popup-shown] lines are asserted by the caller from stdout;
# this script itself only guarantees clean lifecycle.
println("RUN_AGENT_UI_PROBE_OK")
exit(0)
