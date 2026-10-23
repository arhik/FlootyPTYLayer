# pendingAssistProbe.jl — queued instructions are TAB-SCOPED.
#
# Reported: after closing an unresponsive terminal and opening a new tab, the new
# tab's agent was already running the prompts typed in the OLD tab. The queue was a
# single global vector drained by "the next session that registers", so an
# unconsumed prompt migrated into a brand-new tab.
#
# Run: julia --startup-file=no --project=. test/pendingAssistProbe.jl
import FlootyPTYLayer as L
using FlootyPTYLayer: startReplSession, closeSession!, pushPendingAssist!,
    takePendingAssistPrompts!, dropPendingAssist!, handleTerminalCreate,
    registerAdoptedSession!, handleTerminalKill

takeAssistPromptsProbe(sess) = L.takeAssistPrompts!(sess)

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# 1) A prompt queued for tab A is NOT taken by tab A's own close or by tab B.
pushPendingAssist!("tabA", "old prompt from the closed tab")
check("queue is per tab", takePendingAssistPrompts!("tabB") == String[],
      takePendingAssistPrompts!("tabB"))
pushPendingAssist!("tabA", "old prompt from the closed tab")
dropPendingAssist!("tabA")
check("closing the tab drops its queue", takePendingAssistPrompts!("tabA") == String[],
      takePendingAssistPrompts!("tabA"))

# 2) A session created for tab B never sees tab A's prompt.
pushPendingAssist!("tabA", "OLD-PROMPT")
id_b = handleTerminalCreate(`zsh -i`; rows = 24, cols = 80, tab = "tabB")
try
    sess_b = L.OWNERSHIP_SESSIONS[id_b]
    got_b = takeAssistPromptsProbe(sess_b)
    check("a new tab's session starts with NO inherited instruction",
          got_b == String[], got_b)
    check("tab A's prompt is still waiting for tab A",
          takePendingAssistPrompts!("tabA") == ["OLD-PROMPT"], "kept")
finally
    handleTerminalKill(id_b; force = true)
end

# 3) The tab that asked DOES get its own prompt (the intended chat-only path).
pushPendingAssist!("tabC", "first prompt")
sess_c = startReplSession(`zsh -i`; waitPrompt = false)
id_c, _ = registerAdoptedSession!(sess_c; replay = false, tab = "tabC")
try
    got_c = takeAssistPromptsProbe(sess_c)
    check("the tab that asked receives its queued prompt",
          got_c == ["first prompt"], got_c)
finally
    handleTerminalKill(id_c; force = true)
end

println()
if isempty(failures)
    println("PENDING_ASSIST_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
