# loadCheck.jl — verify both packages load and the contract surface exists.
# Run as a script:
#   julia --startup-file=no --project=. test/loadCheck.jl
using Pkg
if Base.identify_package("FlootyPTYLayer") === nothing
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end

using FlootyPTYLayer
import FlootyREPLBridge

failures = String[]
function check(name::String, ok::Bool)
    println(ok ? "PASS  " : "FAIL  ", name)
    ok || push!(failures, name)
end

check("FlootyPTYLayer loads", true)

# Contract exports exist as callables.
for fname in (:spawnPty, :writeToPty, :outputChannel, :resizePty!, :closePty!,
              :ControlState, :setControlState!, :canAgentWrite, :tagIn, :tagOut,
              :ReplSession, :startReplSession, :agentWriteAndWait, :userWrite,
              :writeStatusSidecar!)
    check("export $fname", isdefined(FlootyPTYLayer, fname))
end

# Control machine behavior (pure logic, no PTY).
cs = ControlState(:user)
check("initial :user", currentState(cs) == :user)
check("agent blocked in :user", !canAgentWrite(cs))
tagIn(cs; mode = :shared)
check("tagIn(:shared) allows agent", canAgentWrite(cs) && currentState(cs) == :shared)
tagOut(cs)
check("tagOut returns to :user", currentState(cs) == :user && !canAgentWrite(cs))
okHist = length(controlHistory(cs)) == 3  # init, shared, user
check("history records transitions", okHist)
badCall = try
    setControlState!(cs, :bogus)
    false
catch e
    e isa ArgumentError
end
check("invalid state rejected", badCall)

println()
if isempty(failures)
    println("ALL LOAD CHECKS PASSED")
else
    println("FAILED: ", join(failures, ", "))
    exit(1)
end
