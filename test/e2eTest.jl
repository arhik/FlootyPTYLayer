# e2eTest.jl — real-subsystem end-to-end validation of the duplex agent↔REPL
# loop. Run as a script:
#   julia --startup-file=no --project=. test/e2eTest.jl
#
# Scenario (per plan 14b3b8c9):
#   * startReplSession spawns a REAL `julia -q --startup-file=no` attached to a PTY
#   * flavor detected from the live banner/prompt
#   * successful eval → EvalOutcome(ok=true, errorKind=:none, duration>0)
#   * failing eval → classified (:methodError / :other)
#   * user keystrokes interleaved between sentinel lines still resolve cleanly
#   * control gating: agent write blocked in :user, allowed after tagIn(:shared)
#   * sidecar .warp/repl-status.md written with recent history
using Pkg
if Base.identify_package("FlootyPTYLayer") === nothing
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end
using FlootyPTYLayer
import FlootyREPLBridge: replJulia

failures = String[]
function check(name::String, ok::Bool; detail::String = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [$detail]")
    ok || push!(failures, name)
end

tmpSidecarDir = mktempdir()
sidecarPath = joinpath(tmpSidecarDir, ".warp", "repl-status.md")

println("starting real Julia REPL on a PTY…")
sess = startReplSession(`julia --startup-file=no -q`; sidecarPath = sidecarPath)
try
    check("flavor detected", sess.flavor == replJulia;
          detail = string(sess.flavor))

    # --- 1. successful eval ---------------------------------------------------
    o1 = agentWriteAndWait(sess, "x = 40 + 2")
    check("successful eval ok=true", o1.ok;
          detail = "kind=$(o1.errorKind) excerpt=$(repr(first(o1.excerpt, 120)))")
    check("successful eval kind=:none", o1.errorKind == :none)
    check("duration recorded", o1.duration >= 0.0)

    # --- 2. failing eval → MethodError classification -------------------------
    o2 = agentWriteAndWait(sess, "nope(1)")
    check("MethodError resolved ok=false", !o2.ok)
    check("MethodError classified", o2.errorKind == :methodError;
          detail = "kind=$(o2.errorKind) excerpt=$(repr(first(o2.excerpt, 160)))")

    # --- 3. generic runtime error → :other ------------------------------------
    o3 = agentWriteAndWait(sess, "error(\"flooty deliberate failure\")")
    check("error() classified :other", !o3.ok && o3.errorKind == :other;
          detail = "kind=$(o3.errorKind)")

    # --- 4. interleaved user typing between sentinel lines ---------------------
    # In :shared mode the human types while an agent eval is in flight; pairing
    # must still resolve by eval id.
    setControlState!(sess.control, :agent)   # exclusive for this scenario setup
    @sync begin
        t = @async agentWriteAndWait(sess, "y = sqrt(144)")
        sleep(0.05)                          # let BEGIN sentinel reach the child
        # Human types a comment line mid-eval (always permitted).
        userWrite(sess, "# human says hi\r\n")
        global oInterleave = fetch(t)
    end
    check("interleaved-user-write eval resolves ok",
          oInterleave.ok && oInterleave.errorKind == :none;
          detail = "kind=$(oInterleave.errorKind) excerpt=$(repr(first(oInterleave.excerpt, 160)))")

    # --- 5. control gating ------------------------------------------------------
    tagOut(sess.control)
    blocked = try
        agentWriteAndWait(sess, "z = 1")
        false
    catch e
        occursin("may not write", sprint(showerror, e))
    end
    check("agent write blocked in :user", blocked)
    tagIn(sess.control; mode = :shared)
    check("tagIn(:shared) re-enables agent writes", canAgentWrite(sess.control))

    # User write still allowed in every state (duplex guarantee) — verify it
    # reaches the child and echoes back.
    userWrite(sess, "# still-here\r\n")
    sawEcho = false
    deadline = time() + 5.0
    while time() < deadline
        if occursin("still-here", String(copy(sess.tail.buf)))
            sawEcho = true
            break
        end
        sleep(0.02)
    end
    check("userWrite echoes through pty", sawEcho)

    # --- 6. history + sidecar ---------------------------------------------------
    hist = sessionHistory(sess; n = 10)
    check("history has all evals", length(hist) >= 4;
          detail = "n=$(length(hist))")
    path = writeStatusSidecar!(sess)
    text = try
        read(path, String)
    catch
        ""
    end
    check("sidecar written", isfile(path) &&
          occursin("lastOutcome", text) && occursin("| eval |", text);
          detail = path)
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("ALL E2E CHECKS PASSED")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
