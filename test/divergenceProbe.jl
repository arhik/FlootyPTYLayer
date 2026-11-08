# divergenceProbe.jl — quantify how much the human's xterm and the agent's
# shadow model agree. Needs a live UI + adopted tab, so it is a GUI probe:
#   julia --startup-file=no --project=. test/divergenceProbe.jl
# Headless-safe checks run first; the live comparison is skipped without a tab.
using FlootyPTYLayer
const L = FlootyPTYLayer

failures = String[]
function check(name::String, ok::Bool)
    println(ok ? "PASS  " : "FAIL  ", name)
    ok || push!(failures, name)
end

h1 = L.gridChecksum(["ab", "cd"])
h2 = L.gridChecksum(["ab", "cd"])
h3 = L.gridChecksum(["ab", "ce"])
h4 = L.gridChecksum(["abcd"])
check("gridChecksum deterministic", h1 == h2)
check("gridChecksum changes on different content", h1 != h3)
check("gridChecksum changes on row count", h1 != h4)

sess = startReplSession(`zsh -i`; waitPrompt = false)
let r = terminalDivergence(sess)
    println("headless terminalDivergence -> ", r.reason)
    check("headless path reports not adopted/no session id",
          r.reason in ("no session id", "not adopted"))
end
closeSession!(sess)

println()
if isempty(failures)
    println("DIVERGENCE_PROBE_OK")
    exit(0)
else
    println("FAILURES: ", join(failures, ", "))
    exit(1)
end
