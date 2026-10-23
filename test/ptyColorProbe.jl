# ptyColorProbe.jl — pane children must run color-capable, whatever launched the app.
#
# Regression guard for "the terminal went all grey": a launcher (harness, CI-ish
# shell, terminal) that sets NO_COLOR — or TERM=dumb — is talking about ITS OWN
# stdout. Leaking that into app panes tells every child (shell prompts, git, ls,
# the julia REPL) to print without color, so the pane renders plain grey and the
# escape sequences never even reach xterm.
#
# Headless: spawns a julia REPL through the PTY layer (a real PTY — exactly what a
# pane uses) and checks that the child (a) reports the app's terminal identity,
# (b) believes it has color, and (c) actually emits SGR sequences for styled text.
#
# Run: julia --startup-file=no --project=. test/ptyColorProbe.jl
import FlootyPTYLayer
using FlootyPTYLayer

failures = String[]
function check(name::String, ok::Bool; detail::String = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [$detail]")
    ok || push!(failures, name)
end

launcher = "NO_COLOR=" * repr(get(ENV, "NO_COLOR", "")) *
           " TERM=" * repr(get(ENV, "TERM", ""))
println("launcher environment: ", launcher,
        isempty(get(ENV, "NO_COLOR", "")) ? "" : "   (a grey-pane trigger — must not reach panes)")

const SGR_RE = r"\e\[[0-9;]*m"      # color/attributes only: NOT cursor moves (\e[0K, \e[7C)

sess = startReplSession(`julia --startup-file=no -q`)
try
    sgrSeen = Ref(false)
    tap = addOutputTap!(sess) do chunk
        text = String(copy(chunk))
        occursin(SGR_RE, text) && (sgrSeen[] = true)
        nothing
    end

    env = agentWriteAndWait(sess,
        "println(\"PROBE_TERM \", get(ENV, \"TERM\", \"unset\")); " *
        "println(\"PROBE_COLOR \", Base.have_color)")
    check("child reports the pane's terminal identity",
          occursin("PROBE_TERM xterm-256color", env.excerpt);
          detail = first(replace(env.excerpt, r"\s+" => " "), 300))
    check("child believes it has color (Base.have_color)", env.excerpt !== "" &&
          occursin("PROBE_COLOR true", env.excerpt);
          detail = first(replace(env.excerpt, r"\s+" => " "), 300))

    sgrSeen[] = false
    agentWriteAndWait(sess, "printstyled(\"PROBE_RED\\n\"; color = :red)")
    sleep(0.3)
    check("styled child output still carries SGR sequences for xterm", sgrSeen[];
          detail = sgrSeen[] ? "" : "child emitted no \\e[…m escape")

    removeOutputTap!(sess, tap)
catch e
    println("PROBE_FAILED: ", sprint(showerror, e))
    push!(failures, "probe error")
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("PTY_COLOR_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
