# runInputProbe.jl — MINIMAL-PAGE input diagnostic.
#
# Serves a tiny plain <input> page (no xterm, no bindings beyond lifecycle)
# in a native WKWebView window and parks in the NSApplication event loop.
# Type into the text field:
#   * keys appear in the green log  -> native focus path is FINE; the problem
#     is specific to index.html/xterm.js
#   * nothing appears               -> events never reach web content at all
#
# Run as a script:
#   julia --startup-file=no --project=. test/runInputProbe.jl [timeoutS]
import FlootyPTYLayer
using FlootyPTYLayer

timeoutS = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 90.0

println("launching minimal input-probe window ...")
wv = try
    FlootyPTYLayer.launchInputProbeUI()
catch e
    println("LAUNCH_FAILED: ", sprint(showerror, e))
    exit(1)
end
println(">>> CLICK the text field and TYPE. Watch the green in-page log.")

t = @async begin
    deadline = time() + timeoutS
    while time() < deadline && FlootyPTYLayer.terminalUiRunning[]
        sleep(0.25)
    end
    if time() >= deadline && FlootyPTYLayer.terminalUiRunning[]
        println("WATCHDOG: still running after ", timeoutS, "s")
        exit(42)
    end
end

FlootyPTYLayer.runEventLoopAndTeardown!(wv)
wait(t)
println("RUN_INPUT_PROBE_OK (window closed)")
exit(0)
