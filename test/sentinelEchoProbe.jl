# sentinelEchoProbe.jl — the pane must never show a TRUNCATED sentinel wrapper,
# and every flavor's payload must still emit the tokens the bridge resolves on.
#
# Why: the agent types its eval payload into the child, the tty echoes every byte,
# and the child's line editor repaints the line on EVERY keystroke. A display
# scrubber that blanks the segment carrying the token therefore leaves the PREVIOUS
# repaint on screen — a truncated wrapper nobody can erase later
# (`println('\uf0a7', "FLOOTY_EV`). The emitters avoid it by construction: the tag is
# split in the TYPED source (`"FLOOTY_" * "EVAL_BEGIN:"`), so no echoed segment
# holds the complete token and nothing is blanked mid-row, while the child's
# PRINTED marker line still carries it (a whole line, blanked cleanly).
#
# Part 1 (no window) — each flavor's payload, executed by its own interpreter,
#     emits the complete BEGIN/END tokens plus the statement's output, while the
#     TYPED text never contains the token itself.
# Part 2 (real window) — an eval through the agent path in a julia pane and in a
#     zsh pane, then the XTERM BUFFER is read directly (the screen the user sees):
#     statement output visible, no complete token on screen, and no row holding a
#     marker/tag fragment without its tag half.
#
# Run: julia --startup-file=no --project=. test/sentinelEchoProbe.jl
import FlootyPTYLayer
using FlootyPTYLayer
import Webviews

failures = String[]
function check(name::String, ok::Bool; detail::String = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [$detail]")
    ok || push!(failures, name)
end

"""First element of a possibly empty collection, else an empty string."""
firstOr(v) = isempty(v) ? "" : String(first(v))

const PUA = string(Char(0xf0a7))
const ID = "eval900001"

"""Run `payload` through `cmd`'s interpreter with the payload on stdin."""
function runViaStdin(cmd::Cmd, payload::String)
    path = tempname() * ".txt"
    write(path, payload)
    try
        return read(pipeline(`cat $path`, cmd), String)
    finally
        rm(path; force = true)
    end
end

println("--- Part 1: payloads still emit the tokens (interpreters, no window)")
const PAYLOADS = [
    ("julia",  "julia",  "println(\"MARK_julia 42\")",
     (p, bytes) -> read(`julia --startup-file=no -q -e $p`, String)),
    ("shell",  "zsh",    "echo MARK_shell 42",
     (p, bytes) -> read(`zsh -c $p`, String)),
    ("python", "python3", "print(\"MARK_python\", 42)",
     (p, bytes) -> runViaStdin(`python3 -`, p)),
    ("node",   "node",   "console.log('MARK_node', 42)",
     (p, bytes) -> runViaStdin(`node`, p)),
]

for (flavor, exe, code, runFn) in PAYLOADS
    Sys.which(exe) === nothing && begin
        println("SKIP  ", flavor, " (", exe, " not installed)")
        continue
    end
    typedSource = flavor == "julia" ? String(FlootyPTYLayer.agentPayload(code, ID)) :
                  flavor == "shell" ? String(FlootyPTYLayer.shellPayload(code, ID)) :
                  flavor == "python" ? String(FlootyPTYLayer.pythonPayload(code, ID)) :
                                       String(FlootyPTYLayer.nodePayload(code, ID))
    check(flavor * ": the TYPED source never holds the complete sentinel token",
          !occursin("FLOOTY_EVAL_", typedSource);
          detail = firstOr(filter(l -> occursin("FLOOTY", l), split(typedSource, '\n'))))
    out = try
        runFn(typedSource, Vector{UInt8}(codeunits(typedSource)))
    catch e
        "RUN_FAILED: " * sprint(showerror, e)
    end
    check(flavor * ": executed payload emits BEGIN with the id",
          occursin(PUA * "FLOOTY_EVAL_BEGIN:" * ID, out);
          detail = String(first(replace(out, r"\s+" => " "), 200)))
    check(flavor * ": executed payload emits END with :ok",
          occursin(PUA * "FLOOTY_EVAL_END:" * ID, out);
          detail = String(first(replace(out, r"\s+" => " "), 200)))
    check(flavor * ": the statement's own output is in the payload stream",
          occursin("MARK_" * flavor, out);
          detail = String(first(replace(out, r"\s+" => " "), 200)))
end

println()
println("--- Part 2: what the PANE shows (real window, xterm buffer readback)")
if !isinteractive()
    println("(always runs; needs a desktop session)")
end

function awaitFlavor(sess; want::Symbol, timeoutS::Float64 = 20.0)
    deadline = time() + timeoutS
    while time() < deadline
        FlootyPTYLayer.sessionKind(sess) === want && return true
        sleep(0.2)
    end
    return false
end

const PTY_CASES = [
    ("julia", `julia --startup-file=no -q`, :julia, "println(\"ECHO_julia \", 6 * 7)"),
    ("shell", `/bin/zsh -i`,                :shell, "echo ECHO_shell 42"),
]

sessions = Tuple{String,String,Any}[]      # (flavor, adoptId, sess)
for (flavor, cmd, want, code) in PTY_CASES
    sess = startReplSession(cmd; waitPrompt = false)
    awaitFlavor(sess; want = want) ||
        @warn "sentinelEchoProbe: prompt never matched" flavor want
    push!(sessions, (flavor, code, sess))
end

wv = launchTerminalUI()
report = Ref("")
Webviews.bind(wv, "probePaneReport") do args
    report[] = args isa Tuple && !isempty(args) ? String(args[1]) : ""
    return "{\"success\":true}"
end

t0 = time()
prog(m) = (println("[ECHO-PROBE] ", round(time() - t0; digits = 1), "s ", m); flush(stdout))
closeWv() = (try Webviews.close(wv) catch e; FlootyPTYLayer.requestStopEventLoop!(wv) end; nothing)
adoptIds = Dict{String,String}()
index = Ref(0)

function stepWait()
    n = lock(() -> length(FlootyPTYLayer.OWNERSHIP_SESSIONS),
             FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK)
    if n == 0
        time() - t0 > 30.0 && (prog("no page"); closeWv(); return)
        Webviews.set_timeout(stepWait, wv, 0.25)
        return
    end
    for (flavor, _, sess) in sessions
        adoptIds[flavor] = adoptSessionTerminal!(sess; name = flavor * " pane")
    end
    prog("adopted " * join(values(adoptIds), ", "))
    Webviews.set_timeout(stepRunNext, wv, 1.5)
end

function stepRunNext()
    index[] += 1
    index[] > length(sessions) && return stepDone()
    (flavor, code, sess) = sessions[index[]]
    prog("agent eval in the " * flavor * " pane")
    outcome = try
        FlootyPTYLayer.agentWriteAndWait(sess, code; timeout = 30.0)
    catch e
        nothing
    end
    check(flavor * " pane: eval resolved", outcome !== nothing && outcome.ok;
          detail = outcome === nothing ? "no outcome" :
                   String(first(replace(outcome.excerpt, r"\s+" => " "), 160)))
    raw = FlootyPTYLayer.tailText(sess.tail)
    if occursin("FLOOTY_EVAL", raw) || !FlootyPTYLayer.oscIntegrated(sess)
        # Sentinel-driven evals must keep BOTH tokens in the raw stream.
        check(flavor * " pane: raw stream still carries both tokens",
              occursin("FLOOTY_EVAL_BEGIN", raw) && occursin("FLOOTY_EVAL_END", raw);
              detail = String(first(replace(raw, r"\s+" => " "), 160)))
    else
        check(flavor * " pane: OSC-integrated shell needs no sentinels", true)
    end
    Webviews.set_timeout(stepReadPane, wv, 1.5)
end

function stepReadPane()
    (flavor, _, _) = sessions[index[]]
    try
        Webviews.eval!(wv, """
        (function () {
          const info = terminals[Object.keys(terminals).find(k => terminals[k].juliaId === "$(adoptIds[flavor])")];
          const b = info.term.buffer.active;
          const rows = [];
          for (let y = 0; y < b.length; y++) {
            const line = b.getLine(y);
            if (!line) continue;
            const text = line.translateToString(false);
            if (!text.trim()) continue;
            rows.push(text.replace(/\\uf0a7/g, '<PUA>'));
          }
          probePaneReport(rows.join('\u0001'));
        })()
        """)
    catch e
        check(flavor * " pane: readback", false; detail = sprint(showerror, e))
        Webviews.set_timeout(stepRunNext, wv, 0.2)
        return
    end
    # The report binding fires on the main thread; give it a beat, then judge.
    Webviews.set_timeout(() -> stepJudge(flavor, report[]), wv, 0.5)
end

function stepJudge(flavor::String, payload::String)
    rows = String[String(r) for r in split(payload, '\u0001')]
    suspect = filter(r -> (occursin("FLOOTY_", r) || occursin("uf0a7", r) ||
                           occursin(PUA, r) || occursin("<PUA>", r)) &&
                          !occursin("EVAL_BEGIN:", r) &&
                          !occursin("EVAL_END:", r), rows)
    check(flavor * " pane: statement output visible on screen",
          any(r -> occursin("ECHO_" * flavor, r), rows);
          detail = join([String(first(r, 80)) for r in Iterators.take(rows, 6)], " | "))
    check(flavor * " pane: no complete sentinel token on screen",
          !any(r -> occursin("FLOOTY_EVAL", r), rows);
          detail = firstOr(filter(r -> occursin("FLOOTY", r), rows)))
    check(flavor * " pane: no truncated wrapper row on screen", isempty(suspect);
          detail = join([String(first(r, 100)) for r in Iterators.take(suspect, 4)], " | "))
    flush(stdout)
    Webviews.set_timeout(stepRunNext, wv, 0.5)
end

function stepDone()
    prog("closing")
    closeWv()
end

Webviews.set_timeout(stepWait, wv, 2.0)
Webviews.set_timeout(() -> (prog("watchdog"); closeWv()), wv, 120.0)
FlootyPTYLayer.runEventLoopAndTeardown!(wv)
for (_, _, sess) in sessions
    closeSession!(sess)
end

println()
if isempty(failures)
    println("SENTINEL_ECHO_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
