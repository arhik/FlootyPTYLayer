# runUiProbe.jl — verify the BLOCKING runTerminalUI path end-to-end.
#
# launchTerminalUI + stopTerminalUI (launchUiProbe.jl) never enters
# Webviews' native NSApplication event loop; this probe does: it launches the
# UI, creates a terminal, then triggers the SAME close primitive as the
# frontend's glass Close button via a BOUND FUNCTION called from inside the
# running loop (Webviews.close → our installed FlootyWindowDelegate's
# windowWillClose: → wake event + [NSApp stop:]). Bind callbacks execute on
# the main thread within the loop, exactly like upstream's passing test.
# The loop runs ON THE MAIN THREAD (never @async — AppKit requirement).
# A watchdog force-quits with diagnostics if run(wv) doesn't return.
#
# Run as a script:
#   julia --startup-file=no --project=. test/runUiProbe.jl [timeoutS]
import FlootyPTYLayer
using FlootyPTYLayer
using Webviews

timeoutS = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 60.0

# Tell index.html (via the flootyUiReady binding) that this probe wants the
# page itself to perform the native close once the UI is live — the same code
# path as clicking the glass Close button, from inside the loop.
ENV["FLOOTY_UI_AUTOCLOSE"] = "1"

println("loading OK; launching UI...")
wv = try
    launchTerminalUI()
catch e
    println("LAUNCH_FAILED: ", sprint(showerror, e))
    exit(1)
end
println("launch returned handle type: ", typeof(wv))

# Handler-layer create works regardless of window state.
id = try
    FlootyPTYLayer.handleTerminalCreate(`sh -c "echo PROBE_MARKER_RUN; sleep 300"`)
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
println("collected contains marker: ", occursin("PROBE_MARKER_RUN", txt))

# No external close scheduling needed: the page calls closeWindow() itself
# right after its flootyUiReady ping returns "autoclose" — bindings execute on
# the main thread inside the event loop, mirroring upstream's passing test.
t = @async begin
    # Watchdog: if the loop hasn't unwound by timeoutS, fail loudly.
    deadline = time() + timeoutS
    while time() < deadline && FlootyPTYLayer.terminalUiRunning[]
        sleep(0.25)
    end
    if time() >= deadline && FlootyPTYLayer.terminalUiRunning[]
        println("WATCHDOG: event loop still running after ", timeoutS,
                "s — failing")
        println("WATCHDOG: webview = ", FlootyPTYLayer.terminalUiWebview[])
        exit(42)
    end
end

println("entering runTerminalUI event loop on main thread ...")
FlootyPTYLayer.runEventLoopAndTeardown!(wv)
wait(t)

alive = lock(() -> isempty(FlootyPTYLayer.ACTIVE_TERMINALS),
             FlootyPTYLayer.terminalRegistryLock)
println("registry empty after run: ", alive)
serverStopped = FlootyPTYLayer.terminalUiAssetServer[] === nothing
println("asset server stopped: ", serverStopped)
(alive && serverStopped && occursin("PROBE_MARKER_RUN", txt)) || exit(1)
println("RUN_UI_PROBE_OK")
exit(0)
