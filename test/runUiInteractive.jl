# runUiInteractive.jl — MANUAL keyboard-focus verification for the Webviews UI.
#
# Launches the terminal UI WITHOUT auto-close and parks in the native
# NSApplication event loop so a human can interact with the window:
#   * type into the xterm pane (julia REPL should echo keystrokes)
#   * try the glass Close button / red traffic light to end the loop
# Watchdog force-quits after `timeoutS` if the loop never unwinds.
#
# Run as a script:
#   julia --startup-file=no --project=. test/runUiInteractive.jl [timeoutS]
import FlootyPTYLayer
using FlootyPTYLayer

timeoutS = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 120.0

println("loading OK; launching INTERACTIVE UI (no autoclose) ...")
wv = try
    launchTerminalUI()
catch e
    println("LAUNCH_FAILED: ", sprint(showerror, e))
    exit(1)
end

println(">>> TYPE INTO THE WINDOW NOW. Keystrokes should echo in the julia")
println(">>> REPL pane within ~2s (two focus passes at 0.05s / 1.5s).")

id = try
    FlootyPTYLayer.handleTerminalCreate(`sh -c "echo INTERACTIVE_MARKER; sleep 600"`)
catch e
    println("CREATE_FAILED: ", sprint(showerror, e))
    FlootyPTYLayer.stopTerminalUI()
    exit(1)
end
println("marker terminal: ", id)

t = @async begin
    deadline = time() + timeoutS
    while time() < deadline && FlootyPTYLayer.terminalUiRunning[]
        sleep(0.25)
    end
    if time() >= deadline && FlootyPTYLayer.terminalUiRunning[]
        println("WATCHDOG: still running after ", timeoutS, "s — failing")
        exit(42)
    end
end

println("entering event loop on main thread ...")
FlootyPTYLayer.runEventLoopAndTeardown!(wv)
wait(t)

alive = lock(() -> isempty(FlootyPTYLayer.ACTIVE_TERMINALS),
             FlootyPTYLayer.terminalRegistryLock)
serverStopped = FlootyPTYLayer.terminalUiAssetServer[] === nothing
println("registry empty: ", alive, " | asset server stopped: ", serverStopped)
(alive && serverStopped) || exit(1)
println("RUN_UI_INTERACTIVE_OK (loop unwound cleanly)")
exit(0)
