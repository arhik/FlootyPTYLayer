# probeThinkingDisplay.jl — verify thinking extraction + UI no-op behavior.
# Run as a script:
#   julia --startup-file=no --project=. test/probeThinkingDisplay.jl
using FlootyPTYLayer

failures = String[]
function check(name::String, cond::Bool)
    println(cond ? "PASS  " : "FAIL  ", name)
    cond || push!(failures, name)
end

# --- extractThinking: captures the FIRST <thinking>…</thinking> block body -------
# Pull from Flooty where the function lives and is exported.
import Flooty: extractThinking

# Balanced block with surrounding answer text; body must come back verbatim.
balanced = "Here is my reasoning. <thinking>I should check the tail first\nand then write the payload.</thinking> Done!"
t = extractThinking(balanced)
check("extractThinking: returns block body", t == "I should check the tail first\nand then write the payload.")

# Multiple blocks — only the FIRST is captured.
multi = "<thinking>first</thinking> text <thinking>second</thinking> tail"
t2 = extractThinking(multi)
check("extractThinking: first block only", t2 == "first")

# No thinking block → empty string.
t3 = extractThinking("just a regular answer with no tags")
check("extractThinking: empty when no block", isempty(t3))

# Unbalanced trailing <thinking (still open) — extractThinking's regex requires a
# closing tag, so it should be empty (that is stripThinking's concern).
t4 = extractThinking("prefix <thinking>never closed")
check("extractThinking: empty on unbalanced open", isempty(t4))

# --- stripThinking: the complement (sanity that the pair are consistent) --------
import Flooty: stripThinking
s = stripThinking(balanced)
check("stripThinking: removes block, keeps answer",
      s == "Here is my reasoning.  Done!")
check("stripThinking: no thinking tags remain",
      !occursin("<thinking", s) && !occursin("</thinking>", s))
# --- pushAgentEventToWindow: NO-OP when there is no window -----------------------
# With wv === nothing the bridge must return nothing (no dispatch/eval! path).
result = FlootyPTYLayer.pushAgentEventToWindow(nothing,
    AgentThinkingEvent("sess-123", "model thinking about julia prompts"))
check("pushAgentEventToWindow: nil wv is no-op", result === nothing)

# The push must NOT have registered any terminal (no window was live).
check("no terminals leaked from thinking push",
      FlootyPTYLayer.activeTerminalCount() == 0)

println()
if isempty(failures)
    println("ALL THINKING-DISPLAY CHECKS PASSED")
else
    println("FAILED: ", join(failures, ", "))
    exit(1)
end
