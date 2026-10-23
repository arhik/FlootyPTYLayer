# spawnProbe.jl — isolate which posix_spawnattr flag combination breaks.
# Run: julia --startup-file=no test/spawnProbe.jl
const HELPER = "/Users/arhik/.julia/dev/FlootyPTYLayer/deps/flootySpawnHelper"

function trySpawn(label::String, exe::String, flags::Culong)
    actionsBuf = zeros(UInt8, 512)
    attrBuf = zeros(UInt8, 512)
    maskBuf = zeros(UInt8, 128)
    defBuf = zeros(UInt8, 128)
    GC.@preserve actionsBuf attrBuf maskBuf defBuf begin
        actions = convert(Ptr{Cvoid}, pointer(actionsBuf))
        attr = convert(Ptr{Cvoid}, pointer(attrBuf))
        ccall((:posix_spawn_file_actions_init, "libc"), Cint, (Ptr{Cvoid},), actions)
        ccall((:posix_spawnattr_init, "libc"), Cint, (Ptr{Cvoid},), attr)
        flags != Culong(0) && ccall((:posix_spawnattr_setflags, "libc"), Cint,
                                    (Ptr{Cvoid}, Culong), attr, flags)
        ccall((:posix_spawnattr_setsigdefault, "libc"), Cint,
              (Ptr{Cvoid}, Ptr{Cvoid}), attr, convert(Ptr{Cvoid}, pointer(defBuf)))
        ccall((:posix_spawnattr_setsigmask, "libc"), Cint,
              (Ptr{Cvoid}, Ptr{Cvoid}), attr, convert(Ptr{Cvoid}, pointer(maskBuf)))
        argv = [exe]
        bufs = [vcat(codeunits(s), 0x00) for s in argv]
        arr = Ptr{UInt8}[pointer(b) for b in bufs]
        push!(arr, C_NULL)
        envpp = unsafe_load(convert(Ptr{Ptr{Ptr{Cchar}}},
                                    cglobal((:environ, "libc"))))
        pidRef = Ref{Cint}(0)
        rc = GC.@preserve bufs arr begin
            ccall((:posix_spawnp, "libc"), Cint,
                  (Ref{Cint}, Cstring, Ptr{Cvoid}, Ptr{Cvoid},
                   Ptr{Ptr{Cchar}}, Ptr{Ptr{Cchar}}),
                  pidRef, exe, actions, attr,
                  convert(Ptr{Ptr{Cchar}}, pointer(arr)), envpp)
        end
        ccall((:posix_spawn_file_actions_destroy, "libc"), Cint, (Ptr{Cvoid},), actions)
        ccall((:posix_spawnattr_destroy, "libc"), Cint, (Ptr{Cvoid},), attr)
    end
    println(label, ": rc=", rc, rc == 0 ? " pid=$(pidRef[])" : "")
    if rc == 0
        status = Ref{Cint}(0)
        deadline = time() + 3
        r = 0
        while time() < deadline
            global r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint),
                             pidRef[], status, Cint(1))
            r != 0 && break
            sleep(0.05)
        end
        println("   reaped r=", r, " rawStatus=0x", string(status[], base=16))
    end
end

println("== helper direct exec from shell ==")
run(`sh -c "$(HELPER) ; echo helper-exit=\$?"`)

println("\n== /usr/bin/true with flag combos ==")
trySpawn("true  flags=0", "/usr/bin/true", Culong(0))
trySpawn("true  flags=0x40C (SIGDEF|SIGMASK|SETSID)", "/usr/bin/true", Culong(0x040C))
trySpawn("true  flags=0x440C (+0x4000)", "/usr/bin/true", Culong(0x440C))
trySpawn("true  flags=0x140C (+0x1000)", "/usr/bin/true", Culong(0x140C))

println("\n== helper with flag combos ==")
trySpawn("help flags=0", HELPER, Culong(0))
trySpawn("help flags=0x40C", HELPER, Culong(0x040C))
trySpawn("help flags=0x440C", HELPER, Culong(0x440C))
