# tuiPaintProbe.jl — how does a full-screen app (broot, micro) reach the screen?
#
# A TUI redraws the whole screen with cursor positioning. If the output
# arrives in many small pieces spread over time, the user watches the screen
# fill in band by band — a raster scan — instead of appearing at once.
#
# This probe types `broot` into a terminal and records, in the page:
#   * every output chunk (when it arrived, how many bytes),
#   * every parse completion (when xterm finished a chunk).
# The chunk timeline is the answer: one big write, or a dribble?
#
# RUN IT WITH THE WINDOW VISIBLE (focused). A background/occluded window is
# throttled by the OS, and the numbers then say nothing about the real
# machine.
#
#   julia --startup-file=no --project=. test/tuiPaintProbe.jl
import FlootyPTYLayer
using FlootyPTYLayer
using Logging
using Webviews

mutable struct CaptureLogger <: Logging.AbstractLogger
    lines::Vector{String}
end
CaptureLogger() = CaptureLogger(String[])
Logging.min_enabled_level(::CaptureLogger) = Logging.Debug
Logging.shouldlog(::CaptureLogger, args...) = true
function Logging.handle_message(l::CaptureLogger, level, msg, mod, group, id,
                                file, line; kwargs...)
    push!(l.lines, string(msg))
    return nothing
end

const COMMAND = length(ARGS) >= 1 ? ARGS[1] : "broot"

cap = CaptureLogger()
wv = FlootyPTYLayer.launchTerminalUI()
worker = @async begin
    deadline = time() + 30
    while time() < deadline && FlootyPTYLayer.gpuRendererReport() === nothing
        sleep(0.2)
    end
    sleep(1.0)

    # Record the output chunks and the parses.
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var ids = Object.keys(terminals);
          var t = terminals[ids[0]].term;
          window.__chunks = [];
          window.__parses = [];
          var orig = window.handleTerminalOutput;
          window.handleTerminalOutput = function (id, out) {
            var n = (out && out.length !== undefined) ? out.length
                    : (out && out.byteLength !== undefined) ? out.byteLength : 0;
            window.__chunks.push([+(performance.now()).toFixed(1), n]);
            return orig.apply(this, arguments);
          };
          t.onWriteParsed(function () {
            window.__parses.push(+(performance.now()).toFixed(1));
          });
          window.flootyDebug('TUIPREADY');
        })()
        """)
    end
    sleep(1.0)

    # Type the command.
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var ta = document.querySelector('.xterm-helper-textarea');
          ta.value = $(repr(COMMAND));
          ta.dispatchEvent(new InputEvent('input', {bubbles: true,
            data: $(repr(COMMAND)), inputType: 'insertText'}));
        })()
        """)
    end
    sleep(0.4)
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var ta = document.querySelector('.xterm-helper-textarea');
          ta.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter',
            keyCode: 13, which: 13, bubbles: true, cancelable: true}));
        })()
        """)
    end
    sleep(3.0)

    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var c = window.__chunks || [], p = window.__parses || [];
          var total = 0, biggest = 0;
          for (var i = 0; i < c.length; i++) { total += c[i][1]; if (c[i][1] > biggest) biggest = c[i][1]; }
          window.flootyDebug('TUIP ' + JSON.stringify({
            chunks: c.length, bytes: total, biggest: biggest,
            parses: p.length,
            timeline: c.slice(0, 40),
            parseTimes: p.slice(0, 40),
          }));
        })()
        """)
    end
    sleep(1.0)

    for l in cap.lines
        (occursin("TUIP ", l) || occursin("TUIPREADY", l)) && println(l)
    end
    try; Webviews.close(wv); catch; end
end

Logging.with_logger(cap) do
    FlootyPTYLayer.runEventLoopAndTeardown!(wv)
end
wait(worker)
println("TUI_PAINT_PROBE_DONE")
