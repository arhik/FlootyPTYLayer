# dbgOsc133.jl — diagnostic: trace mark chunks + rc resolution for a good and
# a failing command. Run:
#   rm -f /tmp/flooty_osc_dbg.log
#   FLOOTY_OSC_DEBUG=1 julia --startup-file=no --project=. test/dbgOsc133.jl
using FlootyPTYLayer

println("src version: ", FlootyPTYLayer.OSC133_SRC_VERSION)
sess = FlootyPTYLayer.startReplSession(`/bin/zsh -i`; waitPrompt = false)
t0 = time()
while time() - t0 < 15 && !FlootyPTYLayer.oscIntegrated(sess)
    sleep(0.05)
end
o1 = FlootyPTYLayer.agentWriteAndWait(sess, "echo AAA"; timeout = 30.0)
println("o1.ok=", o1.ok)
o2 = FlootyPTYLayer.agentWriteAndWait(sess, "false"; timeout = 30.0)
println("o2.ok=", o2.ok, " kind=", o2.errorKind)
closeSession!(sess)
println("done — trace in /tmp/flooty_osc_dbg.log")
