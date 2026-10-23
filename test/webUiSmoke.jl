# webUiSmoke.jl — headless smoke test for the terminal handler layer.
#
# Exercises the plain handler functions (handleTerminalCreate/Input/Resize/Kill)
# WITHOUT opening any visible window: terminalUiWebview stays nothing so the pump
# only accumulates pushed chunks into the entry's collected log.
#
# Run as a script:
#   julia --startup-file=no --project=. test/webUiSmoke.jl
using Pkg
if Base.identify_package("FlootyPTYLayer") === nothing
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end
using FlootyPTYLayer
import FlootyPTYLayer: handleTerminalCreate, handleTerminalInput,
                       handleTerminalResize, handleTerminalKill,
                       ACTIVE_TERMINALS, collectedText, waitForExit

failures = String[]
function check(name::String, ok::Bool; detail::String = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [$detail]")
    ok || push!(failures, name)
end

println("flootyWebUi headless smoke test (no window will open)")

# --- 1. create a julia REPL terminal -------------------------------------------
id = handleTerminalCreate(`julia --startup-file=no -q`; rows = 24, cols = 80)
check("terminal_create returns id", id isa String && !isempty(id))
entry = get(ACTIVE_TERMINALS, id, nothing)
check("terminal registered", entry !== nothing)

sawBanner = false
deadline = time() + 90.0
while time() < deadline
    entry === nothing && break
    if occursin("julia>", collectedText(entry))
        global sawBanner = true
        break
    end
    sleep(0.05)
end
check("julia> banner within 90s", sawBanner;
      detail = first(collectedText(entry), 200))

if !sawBanner
    # Nothing else can work without a live REPL; bail out early.
    println()
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end

# --- 2. input round-trip ---------------------------------------------------------
okInput = handleTerminalInput(id, "println(40+2)\r\n")
check("terminal_input write ok", okInput)

sawFortyTwo = false
deadline = time() + 15.0
while time() < deadline
    if occursin("42", collectedText(entry))
        global sawFortyTwo = true
        break
    end
    sleep(0.05)
end
check("output contains 42 within 15s", sawFortyTwo;
      detail = repr(first(last(collectedText(entry), 300), 300)))

# --- 3. resize -------------------------------------------------------------------
okResize = handleTerminalResize(id, 40, 120)
check("terminal_resize ok", okResize)

# --- 4. kill + exit event ----------------------------------------------------------
okKill = handleTerminalKill(id)
check("terminal_kill ok", okKill)
exited = waitForExit(entry; timeoutS = 10.0)
check("exit event recorded after kill", exited &&
      lock(entry.lock) do; entry.exited; end)
check("registry emptied", !haskey(ACTIVE_TERMINALS, id))

println()
if isempty(failures)
    println("ALL WEBUI SMOKE CHECKS PASSED")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end