# spawnSmoke.jl — end-to-end validation of FlootyPTYLayer's PTY transport
# (posix_spawn attach-exec path). Run as a script:
#   julia --startup-file=no --project=. test/spawnSmoke.jl
# Register only when not already resolvable from the active environment
# (running with `--project=.` makes this package the active project itself).
using Pkg
if Base.identify_package("FlootyPTYLayer") === nothing
    Pkg.develop(; path=dirname(@__DIR__), io=devnull)
end
using FlootyPTYLayer

const TIMEOUT_S = 20.0
b(bytes) = convert(Vector{UInt8}, codeunits(bytes))

"""Collect until `pred` matches; returns (text, matched). Dumps tail on timeout."""
function collectUntil(ch::Channel{Vector{UInt8}}, pred::Function;
                      timeoutS::Float64=TIMEOUT_S, label::String="")
    buf = IOBuffer()
    deadline = time() + timeoutS
    while true
        # Drain FIRST — a fast-exiting child can close the channel while
        # chunks are still queued; breaking on !isopen alone loses them.
        while isready(ch)
            write(buf, take!(ch))
        end
        text = String(take!(copy(buf)))
        if !isempty(text) && pred(text)
            return (text, true)
        end
        time() >= deadline && break
        !isopen(ch) && break  # closed AND fully drained above => child gone
        sleep(0.02)
    end
    text = String(take!(buf))
    println("  [timeout:$label open=$(isopen(ch))] tail=", repr(text[max(1, end-300):end]))
    return (text, false)
end

failures = String[]
function check(name::String, ok::Bool; detail::String="")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [$detail]")
    ok || push!(failures, name)
end

# --- 1. interactive Julia REPL on a real tty ---------------------------------
h = spawnPty(setenv(`julia --startup-file=no -q`, "FLOOTY_PROBE" => "flooty-ok"))
try
    sleep(0.3)
    st = Ref{Cint}(0)
    alive = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), h.pid, st, Cint(1)) == 0
    check("helper survived spawn", alive;
          detail=alive ? "" : "child already exited — attach failed (rawStatus=0x$(string(st[], base=16)))")

    (_, okBanner) = collectUntil(outputChannel(h),
                                  t -> occursin("julia>", t),
                                  timeoutS=90.0, label="banner")
    check("repl banner+prompt", okBanner)

    # NB: TTY is not exported; must qualify.
    writeToPty(h, b("println(isa(stdin,Base.TTY), isa(stdout,Base.TTY), isa(stderr,Base.TTY))\r\n"))
    (_, okTty) = collectUntil(outputChannel(h),
                              t -> occursin("truetruetrue", t); label="isatty")
    check("isatty(stdin/out/err)==true", okTty)

    writeToPty(h, b("println(ENV[\"FLOOTY_PROBE\"])\r\n"))
    (_, okEnv) = collectUntil(outputChannel(h), t -> occursin("flooty-ok", t);
                              timeoutS=15.0, label="env")
    check("Cmd.env override visible", okEnv)

    resizePty!(h, 40, 120)
    writeToPty(h, b("print(displaysize(stdout)); println()\r\n"))
    (_, okSize) = collectUntil(outputChannel(h), t -> occursin("(40, 120)", t);
                               label="winsize")
    check("resized winsize honored via SIGWINCH", okSize)

    writeToPty(h, b("exit(0)\r\n"))
    statusRef = Ref{Cint}(0)
    reaped = false
    deadline = time() + 15.0
    while time() < deadline
        r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), h.pid, statusRef, Cint(1))
        if r == h.pid
            reaped = true
            break
        end
        sleep(0.05)
    end
    exitCode = reaped ? statusRef[] >> 8 : -1
    fatalSig = reaped ? statusRef[] & 0x7f : -1
    check("clean exit(0) reaped",
          reaped && exitCode == 0 && fatalSig == 0;
          detail="rawStatus=0x$(string(statusRef[], base=16))")
finally
    closePty!(h)
end

# --- 2. dir handling via helper chdir ----------------------------------------
h2 = spawnPty(Cmd(`sh -c pwd`; dir="/tmp"))
try
    (_, okDir) = collectUntil(outputChannel(h2), t -> occursin("/tmp", t);
                              timeoutS=30.0, label="chdir")
    check("Cmd.dir applied by helper", okDir)
finally
    closePty!(h2)
end

# --- summary ------------------------------------------------------------------
if isempty(failures)
    println("\nALL ", 6, " CHECKS PASSED")
else
    println("\nFAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
