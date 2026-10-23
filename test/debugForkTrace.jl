# debugForkTrace.jl — which checkpoint does the forked child reach?
# All child-side writes use PREALLOCATED buffers; no post-fork allocation.
const TRACE_PATH = "/tmp/flootyChildTrace.txt"
rm(TRACE_PATH; force=true)

master = Ref{Cint}(-1)
slave = Ref{Cint}(-1)
rc = ccall((:openpty, "libc"), Cint,
           (Ref{Cint}, Ref{Cint}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
           master, slave, C_NULL, C_NULL, C_NULL)
println("openpty rc=", rc, " m=", master[], " s=", slave[])

# Resolve slave path via shim (same as production code).
import FlootyPTYLayer
pathBuf = FlootyPTYLayer.slaveDevicePath(master[])
println("shim ptsname -> ", rstrip(String(copy(pathBuf)), '\0'), "|")

# Preallocated trace lines + args.
mInChild   = Vector{UInt8}(codeunits("A_in_child\n"))
mAfterSets = Vector{UInt8}(codeunits("B_after_setsid\n"))
mOpenOk    = Vector{UInt8}(codeunits("C_open_ok\n"))
mOpenFail  = Vector{UInt8}(codeunits("C_open_FAIL\n"))
mDupDone   = Vector{UInt8}(codeunits("D_dup_done\n"))
mEnvDone   = Vector{UInt8}(codeunits("E_env_done\n"))
mExecTry   = Vector{UInt8}(codeunits("F_exec_try\n"))
mExecFail  = Vector{UInt8}(codeunits("G_exec_FAILED\n"))

function appendLine(fd::Cint, bytes::Vector{UInt8})
    ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
          fd, pointer(bytes), length(bytes))
    nothing
end

traceFdParent = ccall((:open, "libc"), Cint,
                      (Ptr{UInt8}, Cint, Cint), TRACE_PATH,
                      Cint(0x0200 | 0x0008 | 0x0400), # O_CREAT|O_APPEND|O_WRONLY
                      Cint(0o644))
println("trace fd(parent view)=", traceFdParent)

argv = Vector{Vector{UInt8}}(undef, 3)
argv[1] = Vector{UInt8}(codeunits("/bin/cat"))
argv[2] = Vector{UInt8}(codeunits("-u"))
argvPtrs = Vector{Ptr{UInt8}}(undef, 3)
for i in 1:2
    argvPtrs[i] = pointer(argv[i])
end
argvPtrs[3] = C_NULL

pid = ccall((:fork, "libc"), Cint, ())
if pid == 0
    # ---- child ----
    traceFd = traceFdParent
    appendLine(traceFd, mInChild)
    ccall((:setsid, "libc"), Cint, ())
    appendLine(traceFd, mAfterSets)
    opened = ccall((:open, "libc"), Cint, (Ptr{UInt8}, Cint),
                   pointer(pathBuf), Cint(2))
    appendLine(traceFd, opened >= 0 ? mOpenOk : mOpenFail)
    opened < 0 && ccall((:_exit, "libc"), Cvoid, (Cint,), 51)
    ccall(:dup2, Cint, (Cint, Cint), opened, 0)
    ccall(:dup2, Cint, (Cint, Cint), opened, 1)
    ccall(:dup2, Cint, (Cint, Cint), opened, 2)
    opened != slave[] && ccall((:close, "libc"), Cint, (Cint,), slave[])
    opened > 2 && ccall((:close, "libc"), Cint, (Cint,), opened)
    appendLine(traceFd, mDupDone)
    ccall(:setenv, Cint, (Cstring, Cstring, Cint), "TERM", "xterm-256color", Cint(1))
    appendLine(traceFd, mEnvDone)
    appendLine(traceFd, mExecTry)
    ccall(:execv, Cint, (Cstring, Ptr{Ptr{UInt8}}),
          "/bin/cat", argvPtrs)
    appendLine(traceFd, mExecFail)
    ccall((:_exit, "libc"), Cvoid, (Cint,), 52)
end

# ---- parent ----
sleep(1.0)
status = Ref{Cint}(0)
r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, Cint(1))
println("waitpid(WNOHANG)=", r, " rawStatus=0x", string(status[], base=16))
r == 0 && println("(child still running)")
ccall(:kill, Cint, (Cint, Cint), pid, Cint(15))
sleep(0.3)
ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, Cint(0))
println("--- trace ---")
print(read(TRACE_PATH, String))
