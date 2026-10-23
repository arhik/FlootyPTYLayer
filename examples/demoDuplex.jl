# demoDuplex.jl — watch the duplex agent↔REPL loop work live.
# Run as a script:
#   julia --startup-file=no --project=. examples/demoDuplex.jl
#
# Spawns a REAL julia REPL on a PTY, drives three evaluations through
# agentWriteAndWait (printing full EvalOutcomes), lets you see interleaved
# user input pass through, writes the status sidecar, then shuts down.
using Pkg
if Base.identify_package("FlootyPTYLayer") === nothing
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end
using FlootyPTYLayer

sidecar = joinpath(mktempdir(), ".warp", "repl-status.md")
println("spawning julia REPL on a pty…")
sess = startReplSession(`julia --startup-file=no -q`; sidecarPath = sidecar)
try
    println("flavor detected : ", sess.flavor)
    tagIn(sess.control; mode = :shared)          # hand control to the agent

    demos = [
        ("clean success",   "2^10"),
        ("method error",    "nosuchfunc(42)"),
        ("multi-line body", "for i in 1:3\n    print(i, \" \")\nend\nprintln()"),
    ]
    for (label, code) in demos
        println("\n== agent evaluates: ", repr(code))
        o = agentWriteAndWait(sess, code)
        println("   ok        = ", o.ok)
        println("   errorKind = ", o.errorKind)
        println("   duration  = ", round(o.duration; digits = 3), "s")
        excerpt = replace(o.excerpt, "\r" => "")
        # Keep only what followed this eval's BEGIN token, capped for display.
        tailPart = if occursin("FLOOTY_EVAL_BEGIN:" * o.evalId, excerpt)
            split(excerpt, "FLOOTY_EVAL_BEGIN:" * o.evalId; limit = 2)[2]
        else
            excerpt
        end
        println("   excerpt   = ", repr(first(tailPart, 200)))
    end

    # While nothing is pending, the human can still type into the same REPL.
    userWrite(sess, "# human typed this comment\r\n")
    sleep(0.2)

    println("\ncontrol history  : ", [p.second for p in controlHistory(sess.control)])
    path = writeStatusSidecar!(sess)
    println("status sidecar   : ", path)
finally
    closeSession!(sess)
end
println("\ndone.")
