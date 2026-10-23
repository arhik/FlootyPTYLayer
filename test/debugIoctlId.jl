# debugIoctlId.jl — is ccall(:ioctl) even reaching the kernel?
master = Ref{Cint}(-1)
slave = Ref{Cint}(-1)
rc = ccall((:openpty, "libc"), Cint,
           (Ref{Cint}, Ref{Cint}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
           master, slave, C_NULL, C_NULL, C_NULL)
println("openpty rc=", rc, " m=", master[], " s=", slave[])
m = master[]

reqGet = Culong(0x40087468)

# Test 1: nonsense request on a REAL tty fd. Real ioctl must fail with ENOTTY.
g = Ref((Cushort(9), Cushort(9), Cushort(9), Cushort(9)))
rcBad = ccall(:ioctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}),
              m, Culong(0xdeadbeef), g)
println("nonsense request: rc=", rcBad, " errno=", Libc.errno())

# Test 2: dlsym the ioctl symbol directly and call through the pointer.
using Libdl
h = Libdl.dlopen("libsystem_kernel.dylib")
pIoctl = Libdl.dlsym(h, :ioctl)
println("dlsym ioctl ptr = ", pIoctl)
g2 = Ref((Cushort(8), Cushort(8), Cushort(8), Cushort(8)))
rcD = ccall(pIoctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}),
            m, reqGet, g2)
enD = Libc.errno()
println("dlsym'd GET(master): rc=", rcD, " errno=", enD,
        " -> ", g2[][1], " x ", g2[][2])

# Test 3: SET through the dlsym'd pointer, then GET again.
reqSet = Culong(0x80087467)
ws = Ref((Cushort(40), Cushort(120), Cushort(0), Cushort(0)))
rcS = ccall(pIoctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}), m, reqSet, ws)
g3 = Ref((Cushort(9), Cushort(9), Cushort(9), Cushort(9)))
rcG = ccall(pIoctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}), m, reqGet, g3)
println("dlsym'd SET rc=", rcS, "; GET rc=", rcG,
        " -> ", g3[][1], " x ", g3[][2])
