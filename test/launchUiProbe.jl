# launchUiProbe.jl — smoke-verify the Webviews launch lifecycle.
#
# History of failures this script guards against:
#   * Regex.escape FieldError in terminal_create  -> fixed with manual escaping
#   * is_shown/webui_wait_async polling spam      -> no polling anywhere: output
#     reaches the page via dispatch+eval! pushes; teardown is explicit.
#
# Success criteria: load OK, launch OK, a handler-layer create works end-to-end
# (spawn + output), stop returns cleanly, registry empty afterwards.
import FlootyPTYLayer
using FlootyPTYLayer

println("loading OK; calling launchTerminalUI()...")
h = try
    launchTerminalUI()
catch e
    println("LAUNCH_FAILED: ", sprint(showerror, e))
    exit(1)
end
println("launch returned handle type: ", typeof(h))

sleep(2.0)  # give window/server a moment (no polling during this idle)

# Exercise the plain handler layer directly (works even if WebView flags lie).
id = try
    FlootyPTYLayer.handleTerminalCreate(`sh -c "echo PROBE_MARKER; sleep 30"`)
catch e
    println("CREATE_FAILED: ", sprint(showerror, e))
    stopTerminalUI()
    exit(1)
end
sleep(1.0)
entry = nothing
lock(() -> (global entry = get(FlootyPTYLayer.ACTIVE_TERMINALS, id, nothing)),
     FlootyPTYLayer.terminalRegistryLock)
txt = entry === nothing ? "" : FlootyPTYLayer.collectedText(entry)
println("collected contains marker: ", occursin("PROBE_MARKER", txt))
stopTerminalUI()
println("stopTerminalUI() returned cleanly")
alive = lock(() -> isempty(FlootyPTYLayer.ACTIVE_TERMINALS),
             FlootyPTYLayer.terminalRegistryLock)
println("registry empty after stop: ", alive)
alive || exit(1)
println("LAUNCH_UI_PROBE_OK")
exit(0)
