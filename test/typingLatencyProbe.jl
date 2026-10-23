# typingLatencyProbe.jl — how long does a keystroke take to come back?
#
# The path a keystroke takes: page (xterm onData) -> the terminal_input
# binding -> the PTY -> the shell's echo -> the PTY -> the reader -> the live
# push -> the page -> the model. Two waits used to sit on it (the PTY poll
# interval and the live-push coalescing timer); both are gone, so this probe
# is the regression guard for the typing latency.
#
# RUN IT WITH THE WINDOW VISIBLE (focused). A background/occluded window is
# throttled by the OS (the page goes hidden and Julia's timers are quantized),
# and the numbers then say nothing about the real machine.
#
#   julia --startup-file=no --project=. test/typingLatencyProbe.jl
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

cap = CaptureLogger()
wv = FlootyPTYLayer.launchTerminalUI()
worker = @async begin
    # Wait for the page (it pushes the renderer report itself).
    deadline = time() + 30
    while time() < deadline && FlootyPTYLayer.gpuRendererReport() === nothing
        sleep(0.2)
    end
    sleep(1.0)
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var ids = Object.keys(terminals);
          var t = terminals[ids[0]].term;
          window.__lat = [];
          var pending = 0;
          t.onWriteParsed(function () {
            if (pending > 0) {
              window.__lat.push(+(performance.now() - pending).toFixed(1));
              pending = 0;
            }
          });
          var ta = document.querySelector('.xterm-helper-textarea');
          window.__type = function (ch) {
            pending = performance.now();
            ta.value = ch;
            ta.dispatchEvent(new InputEvent('input', {bubbles: true, data: ch,
                                                     inputType: 'insertText'}));
          };
          window.flootyDebug('LATREADY');
        })()
        """)
    end
    sleep(1.0)
    for _ in 1:8
        Webviews.dispatch(wv) do
            Webviews.eval!(wv, "window.__type('x');")
        end
        sleep(0.5)
    end
    sleep(1.0)
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, "window.flootyDebug('LAT ' + JSON.stringify(window.__lat));")
    end
    sleep(1.0)
    for l in cap.lines
        (occursin("LAT ", l) || occursin("LATREADY", l)) && println(l)
    end
    try; Webviews.close(wv); catch; end
end

Logging.with_logger(cap) do
    FlootyPTYLayer.runEventLoopAndTeardown!(wv)
end
wait(worker)
println("TYPING_LATENCY_PROBE_DONE")
