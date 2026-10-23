# shadowTerminalProbe.jl - verify the server-side shadow terminal model.
# Run as a script:
#   julia --startup-file=no --project=. test/shadowTerminalProbe.jl
using Pkg
if Base.identify_package("FlootyPTYLayer") === nothing
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end

using FlootyPTYLayer
const S = FlootyPTYLayer.ShadowTerminal

failures = String[]
function check(name::String, ok::Bool)
    println(ok ? "PASS  " : "FAIL  ", name)
    ok || push!(failures, name)
end

function term(cols, rows, input)
    t = S.ShadowTerm(cols, rows)
    S.shadowFeed!(t, input)
    return t
end

let t = term(20, 4, "hello")
    check("plain text lands on row 0", S.shadowLines(t)[1] == "hello")
    check("cursor advances", S.shadowCursor(t).col == 5)
end

let t = term(20, 4, "ab\r\ncd")
    ls = S.shadowLines(t)
    check("CRLF starts a new row", ls[1] == "ab" && ls[2] == "cd")
    check("cursor on row 1", S.shadowCursor(t).row == 1)
end

let t = term(20, 4, "\e[2;5HXY")
    check("CUP addresses row 1 col 4", S.shadowLines(t)[2] == "    XY")
end

let t = term(20, 4, "abcdef\e[1;3H")
    check("CUP moves cursor back", S.shadowCursor(t).col == 2)
end

let t = term(20, 4, "abcdef\e[2J")
    check("ED 2 clears the screen", all(isempty, S.shadowLines(t)))
end

let t = term(20, 4, "abcdef\e[1;4H\e[K")
    check("EL 0 erases to end of line", S.shadowLines(t)[1] == "abc")
end

let t = term(20, 4, "abcdef\e[1;4H\e[1K")
    check("EL 1 erases to start of line", S.shadowLines(t)[1] == "    ef")
end

let t = term(20, 4, "\e[31mR\e[0mN")
    check("SGR 31 sets fg=1", S.getcell(t.grid, 0, 0).fg == 1)
    check("SGR 0 resets fg", S.getcell(t.grid, 0, 1).fg == S.DEFAULT_COLOR)
end

let t = term(20, 4, "\e[1mB\e[22mN")
    check("SGR 1 sets bold", S.isbold(S.getcell(t.grid, 0, 0)))
    check("SGR 22 clears bold", !S.isbold(S.getcell(t.grid, 0, 1)))
end

let t = term(5, 3, "abcdefgh")
    ls = S.shadowLines(t)
    check("autowrap continues on next row", ls[1] == "abcde" && ls[2] == "fgh")
end

let t = term(10, 3, "a\r\nb\r\nc\r\nd")
    ls = S.shadowLines(t)
    check("scrolling drops the top row", ls[1] == "b" && ls[3] == "d")
end

let t = term(10, 4, "1\r\n2\r\n3\r\n4")
    S.shadowResize!(t, 6, 2)
    check("resize changes row count", length(S.shadowLines(t)) == 2)
    check("resize changes col count", t.cols == 6)
end

let t = term(20, 4, "\e[2;3r")
    check("DECSTBM sets scroll region", t.scroll_top == 1 && t.scroll_bottom == 2)
end

# ---- live PTY: the model tracks a real session ----------------------------

let s = startReplSession(`/bin/sh -i`; rows = 8, cols = 40, waitPrompt = false)
    id, e = registerAdoptedSession!(s)
    sleep(0.7)
    writeToPty(s.pty, Vector{UInt8}(codeunits("echo SHADOW_LIVE_OK\n")))
    sleep(0.7)
    txt = shadowTextFor(s)
    check("live PTY output reaches the shadow", occursin("SHADOW_LIVE_OK", txt))
    check("shadow row count matches winsize", length(shadowLinesFor(s)) == 8)
    check("entry accessor agrees with session accessor", shadowText(e) == txt)
    FlootyPTYLayer.handleTerminalResize(id, 4, 30)
    sleep(0.3)
    check("resize is tracked by the shadow", length(shadowLinesFor(s)) == 4)
    closeSession!(s)
end

println()
if isempty(failures)
    println("ALL SHADOW MODEL CHECKS PASSED")
else
    println(length(failures), " FAILURE(S):")
    foreach(f -> println("  - ", f), failures)
    exit(1)
end
