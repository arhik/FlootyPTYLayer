# debugSpawnProbe.jl — why do spawned children die/vanish right after spawn?
import FlootyPTYLayer
using FlootyPTYLayer: spawnPty, writeToPty, outputChannel, closePty!, getWindowSizeOn

function waitStatus(pid::Int32)
    st = Ref{Cint}(0)
    r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, st, Cint(1))
    return (r, st[])
end

h = spawnPty(`/bin/cat -u`)
println("spawned pid=", h.pid, " masterFd=", h.masterFd)

sleep(0.3)
r, st = waitStatus(h.pid)
println("after 0.3s: waitpid(WNOHANG)=", r,
        r > 0 ? " exitedWith=" : " (still running) statusBits=", st)
println("kill(pid,0): ", ccall(:kill, Cint, (Cint, Cint), h.pid, 0))

# Warm-path sanity: shim GET on master should work now.
println("getWindowSizeOn(master) = ", try
    getWindowSizeOn(h.masterFd)
catch e
    "ERROR: $e"
end)

println("writeToPty: ", try
    string(writeToPty(h, Vector{UInt8}(codeunits("ping\n")); source=:agent)), " bytes"
catch e
    "ERROR: $e"
end)

sleep(0.3)
ch = outputChannel(h)
println("channel open=", isopen(ch), " ready=", isready(ch))
while isready(ch) && isopen(ch)
    chunk = try
        take!(ch)
    catch
        break
    end
    println("chunk: ", String(copy(chunk)))
end

# Surface any exception that killed the read task.
if h.readTask !== nothing
    println("readTask done=", istaskdone(h.readTask),
            " failed=", istaskfailed(h.readTask))
    if istaskfailed(h.readTask)
        try
            wait(h.readTask)
        catch e
            println("readTask exception: ", sprint(showerror, e))
        end
    end
end

closePty!(h)
sleep(0.2)
r2, st2 = waitStatus(h.pid)
println("post-close: waitpid=", r2, r2 > 0 ? " exitedWith=" : " (running)", st2,
        " ; kill(pid,0)=", ccall(:kill, Cint, (Cint, Cint), h.pid, 0))
