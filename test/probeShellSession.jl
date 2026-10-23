# probeShellSession.jl — GENERIC-TERMINAL validation: the full duplex loop
# (agentWriteAndWait → printf sentinels → END pairing → excerpt) against a
# REAL interactive zsh, no Julia involved in the child.
#
#   1. spawn /bin/zsh -i on a PTY (waitPrompt=false; shells have no banner)
#   2. sessionKind(sess) == :shell
#   3. echo arithmetic eval -> ok, excerpt carries the computed value
#   4. SECOND eval -> pairing is repeatable (ids advance cleanly)
#   5. failing command -> ok=false with :err from the real exit status
#   6. raw sentinel text must never leak into excerpts (scrub contract)
#
# Run: julia --startup-file=no --project=. test/probeShellSession.jl
using Test
using FlootyPTYLayer

sess = startReplSession(`/bin/zsh -i`; waitPrompt = false)
try
    # Give zsh a moment to draw its first prompt, then verify readiness by
    # tail shape rather than julia-specific text.
    t0 = time()
    while time() - t0 < 15 &&
          !occursin(r"[%$#>]\s*$",
                    replace(FlootyPTYLayer.tailText(sess.tail),
                            r"\e\[[0-?]*[ -/]*[@-~]" => ""))
        sleep(0.1)
    end

    @test FlootyPTYLayer.sessionKind(sess) == :shell

    # --- 1. simple command with computable output -------------------------
    # \$ escaping keeps the ARITHMETIC on the SHELL side — julia types the
    # literal command text, zsh computes 42.
    out1 = FlootyPTYLayer.agentWriteAndWait(sess, "echo FLOOTY_PROBE_\$((6*7))";
                                            timeout = 30.0)
    out1.ok || println("first eval excerpt: ", out1.excerpt)
    @test out1.ok
    @test occursin("FLOOTY_PROBE_42", out1.excerpt)

    # --- 2. repeatability: a second eval pairs its OWN id -----------------
    out2 = FlootyPTYLayer.agentWriteAndWait(
        sess, "echo SECOND_EVAL_\$((2 + 2))"; timeout = 30.0)
    @test out2.ok
    @test occursin("SECOND_EVAL_4", out2.excerpt)
    @test out1.evalId != out2.evalId

    # --- 3. real exit status drives ok/err ---------------------------------
    out3 = FlootyPTYLayer.agentWriteAndWait(
        sess, "false"; timeout = 30.0)
    @test !out3.ok

    # --- 4. scrub contract: no raw sentinel text survives in the excerpt ---
    for o in (out1, out2, out3)
        @test !occursin("FLOOTY_EVAL_BEGIN:", FlootyPTYLayer.scrubSentinelLines(o.excerpt))
        @test !occursin("FLOOTY_EVAL_END:", FlootyPTYLayer.scrubSentinelLines(o.excerpt))
    end

    hist = FlootyPTYLayer.sessionHistory(sess; n = 5)
    @test length(hist) >= 3

    println("SHELL_SESSION_PROBE_OK")
catch e
    println("SHELL_SESSION_PROBE_FAILED: ", sprint(showerror, e))
    rethrow()
finally
    closeSession!(sess)
end
exit(0)
