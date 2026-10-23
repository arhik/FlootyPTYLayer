# debugWinsizeVec.jl — Julia SET, then a C helper GETs the same PTY via its
# device path (fd numbers don't transfer across processes).
using Libdl
master = Ref{Cint}(-1)
slave = Ref{Cint}(-1)
rc = ccall((:openpty, "libc"), Cint,
           (Ref{Cint}, Ref{Cint}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
           master, slave, C_NULL, C_NULL, C_NULL)
println("openpty rc=", rc, " m=", master[], " s=", slave[])
m = master[]
s = slave[]

reqSet = Culong(0x80087467)
reqGet = Culong(0x40087468)

# Try Base's own winsize helpers first — they are known-good on Darwin.
using Base.Libc
println("Base winsize() = ", Base.Libc.gethostname() === nothing ? "" : "")  # noop import guard
try
    println("Displays.size via REPLTerminals? skip")
catch
end

# Direct approach: use the same TIOCGWINSZ against THIS terminal (fd 1) to see
# if ioctl works at all in this Julia process.
g0 = Ref((Cushort(7), Cushort(7), Cushort(7), Cushort(7)))
rc0 = ccall(:ioctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}),
            Cint(1), reqGet, g0)
en0 = Libc.errno()
println("GET(stdout fd1) rc=", rc0, " errno=", en0, " -> ", g0[][1], " x ", g0[][2])

ws = Ref((Cushort(40), Cushort(120), Cushort(0), Cushort(0)))
rcS = ccall(:ioctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}), m, reqSet, ws)
println("SET rc=", rcS)

# Is the slave fd even a tty from Julia's perspective? Also try TIOCGETD.
isTty = ccall(:isatty, Cint, (Cint,), s)
println("isatty(slave) = ", isTty)
isTtyM = ccall(:isatty, Cint, (Cint,), m)
println("isatty(master) = ", isTtyM)
# fstat both fds; S_IFCHR = 0o020000, check what kind of device they are.
for (label, fd) in (("master", m), ("slave", s))
    st = zeros(Cuint, 16)  # generous 64-byte buffer for struct stat
    rcc = ccall(:fstat, Cint, (Cint, Ptr{Cuint}), fd, st)
    mode = rcc == 0 ? st[2] : UInt32(0)
    println(label, " fstat rc=", rcc, " mode=", string(mode, base=8))
end

g = Ref((Cushort(9), Cushort(9), Cushort(9), Cushort(9)))
rcG = ccall(:ioctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}), m, reqGet, g)
println("GET(master) rc=", rcG, " -> ", g[][1], " x ", g[][2])

# Resolve the slave's tty name so the helper can open the SAME device.
# Darwin: ptsname lives in libutil. Load it explicitly.
libutilH = try
    Libdl.dlopen("libutil")
catch
    Libdl.dlopen("libutil.dylib")
end
pPtsName = Libdl.dlsym(libutilH, :ptsname)
println("ptsname sym = ", pPtsName)
p = ccall(pPtsName, Ptr{UInt8}, (Cint,), s)
println("ptsname returned ptr = ", p, " errno=", Libc.errno())
if p == C_NULL
    println("ptsname failed: ", Libc.strerror(Libc.errno()))
    exit(1)
end
ttyPath = unsafe_string(p)
println("slave tty path: ", ttyPath)

mktempdir() do dir
    src = joinpath(dir, "wsget.c")
    bin = joinpath(dir, "wsget")
    write(src, """
    #include <stdio.h>
    #include <stdlib.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <sys/ioctl.h>
    int main(int argc, char** argv) {
        struct winsize ws = {0,0,0,0};
        int fd = open(argv[1], O_RDWR);
        if (fd == -1) { perror("open"); return 1; }
        if (ioctl(fd, TIOCGWINSZ, &ws) == -1) { perror("ioctl"); return 1; }
        printf("%d %d\\n", ws.ws_row, ws.ws_col);
        return 0;
    }
    """)
    run(`cc $src -o $bin`)
    outSlave = read(`$bin $ttyPath`, String)
    println("C-helper GET(slave dev): ", chomp(outSlave))
end

# And Julia's own GET on the slave fd for comparison.
g2 = Ref((Cushort(9), Cushort(9), Cushort(9), Cushort(9)))
rcG2 = ccall(:ioctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}), s, reqGet, g2)
println("GET(slave fd) rc=", rcG2, " -> ", g2[][1], " x ", g2[][2])
