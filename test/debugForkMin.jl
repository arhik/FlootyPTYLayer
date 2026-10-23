# debugForkMin.jl — does the pid==0 branch even execute after ccall(:fork)?
const TRACE_PATH = "/tmp/flootyForkMin.txt"
rm(TRACE_PATH; force=true)

# Preallocate + open trace file BEFORE fork.
fd = ccall((:open, "libc"), Cint,
           (Ptr{UInt8}, Cint, Cint), TRACE_PATH,
           Cint(0x0200 | 0x0008 | 0x0400), Cint(0o644))
msg = Vector{UInt8}(codeunits("in_child\n"))

pid = ccall((:fork, "libc"), Cint, ())
println("after fork, pid=", pid)
if pid == 0
    # Child.
    ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
          fd, msg, length(msg))
    ccall((:_exit, "libc"), Cvoid, (Cint,), 42)
end

# Parent-side bookkeeping (guarded: never touch pid<=0).
if pid < 0
    println("FORK FAILED errno=", Base.Libc.errno())
else
    status = Ref{Cint}(0)
    deadline = time() + 5
    r = 0
    while time() < deadline
        global r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint),
                         pid, status, Cint(1))  # WNOHANG poll, no kill()
        r != 0 && break
        sleep(0.05)
    end
    println("parent waitpid=", r,
            r == 0 ? " (timed out)" : " rawStatus=0x" * string(status[], base=16))
end
sleep(0.3)
println("trace content: ", isfile(TRACE_PATH) ? repr(read(TRACE_PATH, String)) : "(missing)")
