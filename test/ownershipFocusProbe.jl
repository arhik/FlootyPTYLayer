# ownershipFocusProbe.jl — the caret must not jump out of a terminal the
# user is TYPING in when the ownership flips to the agent.
#
# The ownership flips back and forth while the agent works: the user types
# (the agent yields), the agent resumes, the user types again. Every flip to
# the agent moved the caret to the instruction box, so the user's keystrokes
# went there and the cursor went back and forth between the two.
#
#   julia --startup-file=no --project=. test/ownershipFocusProbe.jl
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
    deadline = time() + 30
    while time() < deadline && FlootyPTYLayer.gpuRendererReport() === nothing
        sleep(0.2)
    end
    sleep(1.5)

    # The user is typing in the terminal: its helper textarea has the focus.
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var ids = Object.keys(terminals);
          var ta = document.querySelector('.xterm-helper-textarea');
          if (ta) ta.focus();
          var a = document.activeElement;
          window.flootyDebug('FOCUS before=' + (a ? (a.className || a.tagName) : 'none'));
        })()
        """)
    end
    sleep(1.0)

    # The agent resumes: the ownership flips to the agent.
    ids = collect(keys(FlootyPTYLayer.ACTIVE_TERMINALS))
    for id in ids
        sess = lock(() -> get(FlootyPTYLayer.OWNERSHIP_SESSIONS, String(id), nothing),
                    FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK)
        sess === nothing && continue
        FlootyPTYLayer.setControlState!(sess.control, :agent)
    end
    sleep(1.5)

    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var a = document.activeElement;
          window.flootyDebug('FOCUS after=' + (a ? (a.className || a.tagName) : 'none'));
        })()
        """)
    end
    sleep(1.0)

    for l in cap.lines
        occursin("FOCUS ", l) && println(l)
    end
    try; Webviews.close(wv); catch; end
end

Logging.with_logger(cap) do
    FlootyPTYLayer.runEventLoopAndTeardown!(wv)
end
wait(worker)
println("OWNERSHIP_FOCUS_PROBE_DONE")
