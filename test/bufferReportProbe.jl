# bufferReportProbe.jl — end-to-end check of the rendered-viewport report path.
#
# Proves, in one run against the REAL page, that:
#   page xterm buffer -> serializeTerminalViewport -> debounced
#   callJulia('flootyTerminalBufferReport') -> Julia cache -> terminalBufferFor
#
# The probe creates a session, ADOPTS it into the running window (which is what
# binds a tab to a PTY id and registers the session in OWNERSHIP_SESSIONS), then
# asks the page to push the current viewport of every bound tab via
# window.flootyPushTerminalBuffer — the very path agentSnapshot relies on. It
# polls FlootyPTYLayer.terminalBufferFor(sess) until a report lands and asserts a
# non-empty rendered screen carrying a prompt.
#
# All sequencing uses Webviews timers, which run ON the event loop: a background
# task parked in sleep()/lock() is only resumed when something pumps Julia's
# scheduler, so an @async driver stalls whenever the window is quiet.
#
# Requires a desktop session: it opens the native window (same as
# createdTabReplayProbe.jl).
#
# Run: julia --startup-file=no --project=. test/bufferReportProbe.jl
# Verdict line on stdout: [BUFFER-PROBE] {"ok":...,"chars":N}
import FlootyPTYLayer
using FlootyPTYLayer
import Webviews

println("starting a session for the buffer report probe ...")
sess = startReplSession(`julia --startup-file=no -q`)
try
    agentWriteAndWait(sess, "BUFFER_PROBE_READY = 1"; timeout = 90.0).ok ||
        (println("SESSION_FAILED: no idle prompt"); exit(1))
catch e
    println("SESSION_FAILED: ", sprint(showerror, e))
    exit(1)
end

println("loading OK; launching UI for terminal buffer report probe ...")
wv = try
    launchTerminalUI()
catch e
    println("LAUNCH_FAILED: ", sprint(showerror, e))
    exit(1)
end

adoptId = ""
chars = Ref(0)
buffered = Ref("")
idMatch = Ref(false)
t0 = time()
prog(msg) = (println("[BUFFER-PROBE-RUN] ", round(time() - t0; digits = 1), "s ", msg);
             flush(stdout))

function probeClose()
    try
        Webviews.close(wv)
    catch e
        FlootyPTYLayer.requestStopEventLoop!(wv)
    end
    nothing
end

# The page auto-creates its own session-backed tab on load; its registration in
# OWNERSHIP_SESSIONS proves the page script (and adoptTerminal) is up.
function probeWaitReady()
    adopted = lock(() -> length(FlootyPTYLayer.OWNERSHIP_SESSIONS),
                   FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK)
    if adopted == 0
        if time() - t0 > 30.0
            println("[BUFFER-PROBE] {\"ok\":false,\"error\":\"page never came up\"}")
            probeClose()
            return
        end
        Webviews.set_timeout(probeWaitReady, wv, 0.25)
        return
    end
    prog("page ready (" * string(adopted) * " adopted) — adopting the probe session")
    try
        global adoptId = adoptSessionTerminal!(sess; name = "buffer probe")
    catch e
        println("ADOPT_FAILED: ", sprint(showerror, e))
    end
    prog("adopted as " * adoptId)
    Webviews.set_timeout(probePush, wv, 1.5)   # let the page render the tab
end

function probePush()
    prog("asking the page for every visible viewport")
    try
        Webviews.eval!(wv, """
            for (const [, i] of Object.entries(terminals)) {
                window.flootyPushTerminalBuffer(i.juliaId);
            }
        """)
    catch e
        println("EVAL_FAILED: ", sprint(showerror, e))
    end
    Webviews.set_timeout(() -> probePoll(0), wv, 0.5)   # page debounces by 120ms
end

function probePoll(attempt::Int)
    if chars[] == 0
        for (_, s) in lock(() -> collect(FlootyPTYLayer.OWNERSHIP_SESSIONS),
                           FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK)
            t = try
                FlootyPTYLayer.terminalBufferFor(s)
            catch e
                ""
            end
            if !isempty(t)
                buffered[] = t
                chars[] = length(t)
                idMatch[] = (adoptId == sessionIdFor(sess))
                break
            end
        end
    end
    if chars[] == 0 && attempt < 40 && time() - t0 < 25.0
        Webviews.set_timeout(() -> probePoll(attempt + 1), wv, 0.5)
        return
    end
    prog("report: " * string(chars[]) * " chars")
    probeClose()
end

Webviews.set_timeout(probeWaitReady, wv, 2.0)   # let the page load
Webviews.set_timeout(function ()
    prog("watchdog: nothing closed the window — closing it here")
    probeClose()
end, wv, 120.0)

FlootyPTYLayer.runEventLoopAndTeardown!(wv)
closeSession!(sess)

hasPrompt = occursin(r"[%$#>]", buffered[])
# The excerpt must be the RENDERED screen, which is right-trimmed per line:
# xterm's translateToString(true) alone leaves real spaces an app wrote (zsh's
# PROMPT_SP pad), so the serializer trims the string; this guards that.
paddedLines = count(l -> !isempty(l) && (endswith(l, ' ') || endswith(l, '\t')),
                    split(buffered[], '\n'))
ok = chars[] > 0 && hasPrompt && idMatch[] && paddedLines == 0
println("[BUFFER-PROBE] {\"ok\":", ok, ",\"chars\":", chars[],
        ",\"hasPrompt\":", hasPrompt, ",\"sessionIdMatches\":", idMatch[],
        ",\"paddedLines\":", paddedLines,
        ",\"tail\":", repr(last(buffered[], 200)), "}")
ok || exit(1)
println("BUFFER_REPORT_PROBE_OK")
exit(0)
