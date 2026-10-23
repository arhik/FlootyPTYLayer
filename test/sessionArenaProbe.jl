# sessionArenaProbe.jl — the arena as it is: the session in view on the left,
# its (at most two) children on the right, a child filling the whole right
# half, and a session with no children taking the whole area.
#
# This is the layout guard for the arena that the page keeps.
#
#   julia --startup-file=no --project=. test/sessionArenaProbe.jl
import FlootyPTYLayer
using FlootyPTYLayer
using Logging
using Webviews

mutable struct Cap <: Logging.AbstractLogger
    lines::Vector{String}
end
Cap() = Cap(String[])
Logging.min_enabled_level(::Cap) = Logging.Debug
Logging.shouldlog(::Cap, args...) = true
function Logging.handle_message(l::Cap, level, msg, mod, group, id, file, line; kwargs...)
    push!(l.lines, string(msg)); nothing
end

cap = Cap()
wv = FlootyPTYLayer.launchTerminalUI()
worker = @async begin
    deadline = time() + 30
    while time() < deadline && FlootyPTYLayer.gpuRendererReport() === nothing
        sleep(0.2)
    end
    sleep(1.5)
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          try {
            window.__parent = Object.keys(terminals)[0];
            window.__child = window.splitTerminal('vertical', {});
          } catch (err) { window.flootyDebug('ARENA ERROR ' + err); }
        })()
        """)
    end
    sleep(3.0)
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          try {
            var c = document.getElementById('terminal-container');
            var p = document.getElementById(window.__parent);
            var k = document.getElementById(window.__child);
            var pr = p ? p.getBoundingClientRect() : null;
            var kr = k ? k.getBoundingClientRect() : null;
            var term = terminals[window.__child] && terminals[window.__child].term;
            var text = '';
            if (term && term.buffer) {
              var line = term.buffer.active.getLine(term.buffer.active.cursorY);
              text = line ? line.translateToString(true).trim() : '';
            }
            window.flootyDebug('ARENA split=' + c.classList.contains('split') +
              ' cols=' + getComputedStyle(c).gridTemplateColumns +
              ' parent=' + (pr ? Math.round(pr.width) + 'x' + Math.round(pr.height) : 'none') +
              ' child=' + (kr ? Math.round(kr.width) + 'x' + Math.round(kr.height) : 'none') +
              ' childText=' + JSON.stringify(text.slice(0, 40)));
          } catch (err) { window.flootyDebug('ARENA ERROR ' + err); }
        })()
        """)
    end
    sleep(1.5)
    for l in cap.lines
        occursin("ARENA ", l) && println(l)
    end
    try; Webviews.close(wv); catch; end
end
Logging.with_logger(cap) do
    FlootyPTYLayer.runEventLoopAndTeardown!(wv)
end
wait(worker)
println("SESSION_ARENA_PROBE_DONE")
