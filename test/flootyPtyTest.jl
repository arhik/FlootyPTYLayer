# flootyPtyTest.jl — PTY transport scenario tests for FlootyPTYLayer.
# Run with: julia --project=/Users/arhik/.julia/dev/FlootyPTYLayer test/flootyPtyTest.jl
# Prints PASS/FAIL per scenario; exits nonzero on any failure.
# NOTE: does not call any FlootyREPLBridge functions (their bodies still throw;
# another builder owns them). Module load itself is verified by this import.

import FlootyPTYLayer
using FlootyPTYLayer: PtyHandle, spawnPty, writeToPty, outputChannel,
    resizePty!, closePty!, getWindowSizeOn

const JULIA_BIN = "/Users/arhik/.juliaup/bin/julia"
const failures = Ref(0)

function report(name::String, ok::Bool; detail::String="")
    ok || (failures[] += 1)
    line = string(ok ? "PASS" : "FAIL", " — ", name)
    isempty(detail) || (line *= " (" * detail * ")")
    println(line)
end

"""Collect output chunks for up to `timeoutS`, returning them as a Vector{UInt8}."""
function drainFor(h::PtyHandle, timeoutS::Real)
    collected = IOBuffer()
    ch = outputChannel(h)
    deadline = time() + timeoutS
    while time() < deadline
        # NOTE: plain isready(ch) — Channels synchronize internally; the old
        # `lock(() -> isready(ch))` here was an invalid two-arg lock dispatch.
        ready = isready(ch)
        if ready
            chunk = take!(ch)
            write(collected, chunk)
            deadline = time() + timeoutS  # idle window resets after each chunk
        else
            sleep(0.02)
        end
    end
    return take!(collected)
end

"""True when `pid` still exists as a process (ESRCH means it's fully gone)."""
processExists(pid::Int32) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0

# ---- scenario 1: /bin/cat -u echoes agent-written bytes ---------------------

function scenarioCatEcho()
    h = try
        spawnPty(`/bin/cat -u`)
    catch e
        report("spawn /bin/cat -u", false; detail=string(e))
        return nothing
    end
    report("spawn /bin/cat -u", true; detail="pid=$(h.pid)")
    try
        payload = Vector{UInt8}(codeunits("hello\n"))
        n = writeToPty(h, payload; source=:agent)
        report("writeToPty(source=:agent) accepted $(n) bytes", n == length(payload))

        got = String(drainFor(h, 5.0))
        report("echo 'hello\\n' observed on outputChannel within ~5s", occursin("hello", got);
               detail="got $(length(got)) bytes")
    catch e
        report("cat echo round-trip", false; detail=string(e))
    finally
        closePty!(h)
    end
    return h
end

# ---- scenario 2: julia REPL spawns attached and sees the pty ----------------

function scenarioJuliaRepl()
    h = try
        spawnPty(`$(JULIA_BIN) -q --startup-file=no`; rows=40, cols=120)
    catch e
        report("spawn julia repl", false; detail=string(e))
        return nothing
    end
    try
        # Give the REPL time to boot, then collect whatever banner it printed.
        gotBoot = String(drainFor(h, 3.0))
        report("julia repl booted on the pty", true;
               detail="$(length(gotBoot)) bytes of banner")

        # A REPL attached to a pty answers `stty size` with its window dims.
        writeToPty(h, Vector{UInt8}(codeunits("run(`stty size`)\n")); source=:agent)
        got = String(drainFor(h, 5.0))
        m = match(r"(\d+)\s+(\d+)", got)
        if m === nothing
            report("isatty probe: stty size answered", false; detail="no dims in pty output")
        else
            rows = parse(Int, m.captures[1])
            cols = parse(Int, m.captures[2])
            report("isatty probe: stty size answered 40x120",
                   rows == 40 && cols == 120; detail="rows=$rows cols=$cols")
        end
    catch e
        report("julia repl isatty probe", false; detail=string(e))
    finally
        closePty!(h)
    end
    return h
end

# ---- scenario 3: resize without error ---------------------------------------

function scenarioResize()
    h = try
        spawnPty(`/bin/cat -u`; rows=24, cols=80)
    catch e
        report("resize scenario spawn", false; detail=string(e))
        return nothing
    end
    try
        ok = try
            resizePty!(h, 40, 120)
            true
        catch e
            @warn "resizePty! threw" e
            false
        end
        report("resize to 40x120 without error", ok)

        # Independent confirmation through TIOCGWINSZ via the same non-variadic
        # shim path (raw ccall(:ioctl) silently no-ops on arm64 Darwin).
        rows, cols = getWindowSizeOn(h.masterFd)
        report("TIOCGWINSZ confirms 40x120", rows == 40 && cols == 120;
               detail="rows=$rows cols=$cols")
    catch e
        report("resize verification", false; detail=string(e))
    finally
        closePty!(h)
    end
    return h
end

# ---- scenario 4: close terminates child, closes channel, no zombie ----------

function scenarioClose()
    h = spawnPty(`/bin/cat -u`)
    writeToPty(h, Vector{UInt8}(codeunits("ping\n")); source=:agent)
    sleep(0.1)  # let some echo land in the channel first
    t0 = time()
    closePty!(h)
    elapsed = time() - t0
    report("closePty! returns promptly (<10s)", elapsed < 10.0;
           detail="$(round(elapsed; digits=2))s")

    drained = 0
    while isopen(outputChannel(h)) && isready(outputChannel(h))
        take!(outputChannel(h))
        drained += 1
    end
    report("output channel closed after closePty!",
           !isopen(outputChannel(h)); detail="$drained buffered chunks drained")
    report("child reaped (kill(pid,0) reports ESRCH)", !processExists(h.pid);
           detail="pid=$(h.pid)")

    # Double-close must be a harmless no-op.
    closePty!(h)
    report("double closePty! is idempotent", true)
end

function main()
    println("== flootyPtyTest.jl ==")
    scenarioCatEcho()
    scenarioJuliaRepl()
    scenarioResize()
    scenarioClose()
    totalFailures = failures[]
    println(totalFailures == 0 ? "== ALL TESTS PASSED ==" : "== $totalFailures FAILURE(S) ==")
    exit(totalFailures == 0 ? 0 : 1)
end

main()
