# probeOsc133.jl — NATIVE command-lifecycle validation (generic-terminal model):
# the spawned zsh emits OSC 133 A/C/D marks via the injected ZDOTDIR shim,
# and agent evals resolve from REAL command boundaries + REAL exit codes
# with NO typed sentinel wrappers.
#
#   1. spawn /bin/zsh -i on a PTY (waitPrompt=false)
#   2. integration detected: first A/D mark flips oscSeen
#   3. echo arithmetic eval -> ok, excerpt carries the computed value,
#      and NO __flooty_rc / FLOOTY_EVAL wrapper text ever appears
#      (plain-text dispatch — the shell's C→D pairing is the protocol)
#   4. failing command -> ok=false from the REAL exit status
#   5. repeatability: third eval pairs cleanly
#   6. custom prompt ("flooty133:: ") that NO idle-prompt regex knows:
#      glyph heuristics go blind, yet the agent still evals instantly —
#      proving idle detection rides the A-mark fast path
#
# Run: julia --startup-file=no --project=. test/probeOsc133.jl
using Test
using FlootyPTYLayer

sess = startReplSession(`/bin/zsh -i`; waitPrompt = false)
try
    # --- 1. integration detected from boot-time marks ----------------------
    t0 = time()
    while time() - t0 < 15 && !FlootyPTYLayer.oscIntegrated(sess)
        sleep(0.05)
    end
    @test FlootyPTYLayer.oscIntegrated(sess)
    @test FlootyPTYLayer._oscAtIdlePrompt(sess)

    # --- 2. echo arithmetic resolves via C->D with the real exit code ------
    out1 = FlootyPTYLayer.agentWriteAndWait(sess, "echo FLOOTY_133_\$((6*7))";
                                            timeout = 30.0)
    out1.ok || println("eval1 excerpt: ", repr(out1.excerpt))
    @test out1.ok
    @test occursin("FLOOTY_133_42", out1.excerpt)
    # Native dispatch typed NO wrapper machinery:
    @test !occursin("__flooty_rc", out1.excerpt)
    @test !occursin("FLOOTY_EVAL_BEGIN:", out1.excerpt)
    @test !occursin("FLOOTY_EVAL_END:", out1.excerpt)

    # --- 3. failing command -> err from the REAL exit status ---------------
    out2 = FlootyPTYLayer.agentWriteAndWait(sess, "false"; timeout = 30.0)
    @test !out2.ok

    # --- 4. repeatability ---------------------------------------------------
    out3 = FlootyPTYLayer.agentWriteAndWait(sess, "echo AGAIN_\$((40+2))";
                                            timeout = 30.0)
    @test out3.ok
    @test occursin("AGAIN_42", out3.excerpt)
    @test length(unique([out1.evalId, out2.evalId, out3.evalId])) == 3

    # --- 5. custom prompt: A-mark idle fast path ----------------------------
    # A prompt NO idle-prompt regex matches: glyph detection is blind here,
    # so a successful eval proves idleness came from the OSC 133 A mark.
    FlootyPTYLayer.userWrite(sess, "PROMPT='flooty133:: '\n")
    t0 = time()
    while time() - t0 < 10 &&
          !occursin("flooty133::", FlootyPTYLayer.tailText(sess.tail))
        sleep(0.05)
    end
    @test occursin("flooty133::", FlootyPTYLayer.tailText(sess.tail))
    @test !FlootyPTYLayer._tailAtIdlePrompt(FlootyPTYLayer.tailText(sess.tail))
    out4 = FlootyPTYLayer.agentWriteAndWait(sess, "echo CUSTOM_PROMPT_OK_\$((1+1))";
                                            timeout = 30.0)
    out4.ok || println("eval4 excerpt: ", repr(out4.excerpt))
    @test out4.ok
    @test occursin("CUSTOM_PROMPT_OK_2", out4.excerpt)

    println("OSC133_PROBE_OK")
catch e
    println("OSC133_PROBE_FAILED: ", sprint(showerror, e))
    rethrow()
finally
    closeSession!(sess)
end
exit(0)
