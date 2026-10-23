# nestedShellProbe.jl — commands must keep working when the pane leaves the
# OSC-integrated shell.
#
# Reported symptom: "on linux the commands are failing" — reproduced by typing
# `ssh <linux box>` inside the app's tab (or any nested shell: bash, docker exec,
# a REPL). `sess.oscSeen` is a STICKY flag, so the agent kept choosing NATIVE
# dispatch (type the code plain, resolve from the shell's OSC 133 D mark). A
# nested foreground process emits no marks: the shell reported C when it started
# and reports D only when it exits, so every agent write timed out as
# `incompleteInput` — measured inside a real ssh session, before the fix.
#
# The fix: native dispatch only while the integrated shell is AT a marked prompt
# (`_oscAtIdlePrompt`, i.e. no command open); otherwise fall back to BEGIN/END
# sentinels, which any POSIX shell echoes back.
#
# Run: julia --startup-file=no --project=. test/nestedShellProbe.jl
using FlootyPTYLayer
using FlootyPTYLayer: startReplSession, closeSession!, agentWriteAndWait, userWrite,
    tagIn, tailText, _oscAtIdlePrompt
import FlootyREPLBridge

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# ---- 1..3: zsh (integrated) -> nested bash -> back --------------------------
sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.5)
    tagIn(sess.control; mode = :agent)
    check("the integrated shell is detected", sess.oscSeen && _oscAtIdlePrompt(sess),
          (sess.oscSeen, _oscAtIdlePrompt(sess)))

    o1 = agentWriteAndWait(sess, "echo LOCAL_OK"; timeout = 10.0)
    check("a command in the integrated shell succeeds", o1.ok, o1.errorKind)

    # Enter a nested shell exactly like `ssh host`: an interactive program that
    # never returns, so `agentWriteAndWait` must resolve as STARTED (`:running`)
    # instead of waiting out the eval timeout.
    tEnter = time()
    oEnter = agentWriteAndWait(sess, "bash"; timeout = 20.0)
    check("an interactive launcher resolves as STARTED, not a timeout",
          oEnter.ok && oEnter.errorKind == :running, oEnter.errorKind)
    check("…and it does so promptly (no eval-timeout burn)",
          time() - tEnter < 5.0, round(time() - tEnter; digits = 2))
    sleep(0.5)
    check("the nested shell leaves the outer shell mid-command",
          sess.oscSeen && !_oscAtIdlePrompt(sess),
          (sess.oscSeen, _oscAtIdlePrompt(sess)))

    o2 = agentWriteAndWait(sess, "echo NESTED_OK"; timeout = 12.0)
    check("a command in the NESTED shell succeeds (sentinel fallback)", o2.ok, o2.errorKind)
    check("…and its output is really the nested shell's", occursin("NESTED_OK", o2.excerpt),
          first(strip(o2.excerpt), 120))

    o3 = agentWriteAndWait(sess, "exit"; timeout = 12.0)
    check("exiting the nested shell succeeds", o3.ok, o3.errorKind)
    sleep(0.5)
    o4 = agentWriteAndWait(sess, "echo BACK_OK"; timeout = 10.0)
    check("the integrated shell resumes after the nested one exits", o4.ok, o4.errorKind)
finally
    closeSession!(sess)
end

# ---- 4: a POSIX shell in a NON-UTF-8 locale still round-trips sentinels ----
# (the sentinel marker is a private-use codepoint; `LANG=C` must not mangle it)
csess = startReplSession(`bash -i`; waitPrompt = false)
try
    sleep(1.0)
    tagIn(csess.control; mode = :agent)
    # Simulate the locale on the shell side after boot (spawn env is the parent's).
    userWrite(csess, "export LANG=C LC_ALL=C\n")
    sleep(0.4)
    oc = agentWriteAndWait(csess, "echo LOCALE_OK"; timeout = 12.0)
    check("sentinel delivery works in a C-locale shell", oc.ok, oc.errorKind)
    check("…with visible output", occursin("LOCALE_OK", oc.excerpt),
          first(strip(oc.excerpt), 120))
finally
    closeSession!(csess)
end

# ---- 4b: the classifier (no PTY) -------------------------------------------
for (code, want) in (("ssh host", true), ("FOO=1 ssh host", true),
                     ("ssh host \"uname -srm\"", false), ("ssh -p 22 host", true),
                     ("ls -la", false), ("bash", true),
                     ("bash -c \"echo hi\"", false),
                     ("docker exec -it c sh", true), ("docker ps", false),
                     ("tail -f log", true), ("tail -n 5 log", false),
                     ("python -c \"print(1)\"", false), ("python", true),
                     ("julia -e \"1+1\"", false), ("vim file", true),
                     ("nc -z host 22", false))
    got = FlootyPTYLayer.isInteractiveCommand(code)
    check("classify " * repr(code), got == want, (got, want))
end

# ---- 4c: a full-screen TUI owns the keyboard -------------------------------
# Reported: "if I run broot on the remote linux machine I see keyinputs in the
# broot". A sentinel wrapper typed into a TUI is read as KEYSTROKES. Two guards:
# known TUI names are classified interactive, and the ALTERNATE-SCREEN flag
# (`?1049h`) catches every TUI whose name we never heard of.
check("broot is classified interactive", FlootyPTYLayer.isInteractiveCommand("broot"))
check("lazygit/fzf/ncdu are classified interactive",
      all(n -> FlootyPTYLayer.isInteractiveCommand(n), ("lazygit", "fzf", "ncdu")))

tuiDir = mktempdir()
fakeTui = joinpath(tuiDir, "faketui")
open(fakeTui, "w") do f
    println(f, "#!/bin/sh")
    println(f, "printf '\\033[?1049h'")
    println(f, "while IFS= read -r line; do printf 'KEY:%s\\r\\n' \"\$line\"; done")
end
chmod(fakeTui, 0o755)

tuiSess = startReplSession(`bash -i`; waitPrompt = false)
try
    sleep(1.0)
    tagIn(tuiSess.control; mode = :agent)
    userWrite(tuiSess, fakeTui * "\n")     # the USER opens the TUI
    sleep(0.8)
    check("alternate screen is detected", FlootyPTYLayer.inAltScreen(tuiSess))
    tW = time()
    oA = agentWriteAndWait(tuiSess, "hello-from-agent"; timeout = 10.0)
    check("an agent write inside the TUI resolves as STARTED", oA.ok, oA.errorKind)
    check("…without waiting for a prompt that never comes", time() - tW < 1.5,
          round(time() - tW; digits = 2))
    sleep(0.3)
    tuiTail = FlootyPTYLayer._stripAnsi(tailText(tuiSess.tail))
    check("no sentinel wrapper is typed into the TUI", !occursin("FLOOTY_", tuiTail))
    check("the TUI receives exactly the agent's line",
          occursin("KEY:hello-from-agent", tuiTail),
          first(last(tuiTail, 120), 120))
finally
    closeSession!(tuiSess)
end

# ---- 5: the parser itself tolerates CRLF (remote/ssh line endings) ---------
begin
    marker = FlootyREPLBridge._SENTINEL_MARKER
    beginTok = string(marker, "FLOOTY_EVAL_BEGIN:eval000042")
    endTok = string(marker, "FLOOTY_EVAL_END:eval000042:ok")
    prompt = "arhik@ubuntu:~\$ "
    crlf = string(prompt, beginTok, "\r\n",
                  "Linux 5.10.104-tegra aarch64\r\n",
                  prompt, endTok, "\r\n")
    events = FlootyREPLBridge.parseSentinels(Vector{UInt8}(codeunits(crlf)))
    ends = [e for e in events if e isa FlootyREPLBridge.EndEval]
    check("CRLF streams pair the END sentinel", length(ends) == 1, length(events))
    check("…with the ok flag and a clean excerpt",
          length(ends) == 1 && ends[1].ok &&
          occursin("aarch64", ends[1].excerpt) &&
          !occursin("FLOOTY_", ends[1].excerpt),
          length(ends) == 1 ? first(strip(ends[1].excerpt), 120) : "")
end

println()
if isempty(failures)
    println("NESTED_SHELL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
