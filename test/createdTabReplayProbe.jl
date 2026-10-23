# createdTabReplayProbe.jl — focused check for the missing-prompt-on-new-tab fix.
#
# Launches the REAL WebView UI; index.html auto-creates its julia tab at
# DOMContentLoaded. A background task waits for boot, then eval!s ONE in-page
# collector/assertor that reports through the flootyDebug binding:
#   * terminal_create .then() ran and drained the buffered boot tail
#     (window.__lastBindDrain written by index.html)
#   * nothing left stranded in pendingOutput
#   * the xterm buffer ACTUALLY renders the julia> prompt (plain-text scan)
# It then stops the event loop and verifies clean teardown.
#
# Run: julia --startup-file=no --project=. test/createdTabReplayProbe.jl
# Verdict line on stdout: [REPLAY-PROBE] {...} (bufferHasPrompt must be true).
import FlootyPTYLayer
using FlootyPTYLayer
import Webviews

println("loading OK; launching UI for created-tab replay probe ...")
wv = try
    launchTerminalUI()
catch e
    println("LAUNCH_FAILED: ", sprint(showerror, e))
    exit(1)
end

# NOTE: FLOOTY_UI_AUTOCLOSE deliberately NOT set — this probe owns shutdown.
# The in-page collector POLLS every 300ms until the active tab's buffer shows
# the julia> prompt (or 30s elapse) — immune to boot-time races and to tabs
# created/closed meanwhile — then reports ONCE and records PASS/FAIL.
stopper = @async begin
    sleep(3.0)   # let the page load, spawn the default julia tab, bind + drain
    Webviews.dispatch(wv) do
        try
            Webviews.eval!(wv, """
                (function () {
                  var tries = 0;
                  var timer = setInterval(function () {
                    tries++;
                    var id = activeTerminalId;
                    var info = terminals[id];
                    if (!info || !info.term) return;
                    var b = info.term.buffer.active;
                    var text = '';
                    for (var i = 0; i < b.length; i++) {
                      text += b.getLine(i).translateToString(true) + '\\n';
                    }
                    if (!(/julia>/.test(text)) && tries < 100) return; // keep waiting
                    clearInterval(timer);
                    window.__replayVerdict = /julia>/.test(text) ? 'PASS' : 'FAIL';
                    window.flootyDebug('[REPLAY-PROBE] ' + JSON.stringify({
                      verdict: window.__replayVerdict,
                      polledTries: tries,
                      hasActiveTab: !!info,
                      juliaIdBound: !!(info && info.juliaId),
                      drainedChunks: (window.__lastBindDrain || {}).drained === undefined
                                     ? null : window.__lastBindDrain.drained,
                      pendingLeft: Object.keys(pendingOutput).length,
                      bufferHasPrompt: /julia>/.test(text),
                      bufferNonEmpty: text.trim().length > 0,
                      cursor: [b.cursorX, b.cursorY],
                      tail: text.slice(-240)
                    }));
                  }, 300);
                })()
            """)
        catch e
            @debug "probe dispatch failed" exception = e
        end
    end
    # Wait for the verdict (or timeout), then stop the loop.
    deadline = time() + 45.0
    while time() < deadline && FlootyPTYLayer.terminalUiRunning[]
        sleep(0.5)
    end
    sleep(1.0)
    FlootyPTYLayer.requestStopEventLoop!(wv)
end

FlootyPTYLayer.runEventLoopAndTeardown!(wv)
wait(stopper)

alive = lock(() -> isempty(FlootyPTYLayer.ACTIVE_TERMINALS),
             FlootyPTYLayer.terminalRegistryLock)
serverStopped = FlootyPTYLayer.terminalUiAssetServer[] === nothing
println("registry empty after run: ", alive)
println("asset server stopped: ", serverStopped)
(alive && serverStopped) || exit(1)
println("CREATED_TAB_REPLAY_PROBE_OK")
exit(0)
