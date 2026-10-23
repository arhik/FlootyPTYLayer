# debugWinsize3.jl — verified constants; vary only the 3rd-arg marshaling.
master = Ref{Cint}(-1)
slave  = Ref{Cint}(-1)
rc = ccall((:openpty, "libc"), Cint,
           (Ref{Cint}, Ref{Cint}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
           master, slave, C_NULL, C_NULL, C_NULL)
println("openpty rc=", rc, " master=", master[], " slave=", slave[])

fd = master[]
# Compile-time probe values from <sys/ioctl.h> (see /tmp/winsize_probe.c):
# TIOCGWINSZ=0x40087468 TIOCSWINSZ=0x80087467 sizeof(winsize)=8
TIOCSWINSZ = Culong(0x80087467)
TIOCGWINSZ = Culong(0x40087468)

wsRef = Ref((Cushort(40), Cushort(120), Cushort(0), Cushort(0)))
# Verify what is actually IN the buffer before the call:
println("pre-call bytes: ", reinterpret(UInt8, [wsRef[]]))
# Sanity-check what the marshaling layer actually passes: compare the pointer
# ccall would use vs the raw object address.
convPtr = Base.cconvert(Ref{NTuple{4,Cushort}}, wsRef)
unconvPtr = Base.unsafe_convert(Ptr{NTuple{4,Cushort}}, convPtr)
println("unsafe_convert ptr = ", UInt(unconvPtr),
        "  raw obj addr = ", UInt(pointer_from_objref(wsRef)))

pWs = pointer_from_objref(wsRef)  # bypass ccall's automatic cconvert/unsafe_convert
rcA = ccall(:ioctl, Cint, (Cint, Culong, Ptr{NTuple{4,Cushort}}),
            fd, TIOCSWINSZ, pWs)
println("Ref{NTuple}: rc=", rcA, " errno=", Libc.errno(),
        " (", Libc.strerror(Libc.errno()), ")")

buf = zeros(Cushort, 4); buf[1] = 40; buf[2] = 120
rcB = ccall(:ioctl, Cint, (Cint, Culong, Ptr{Cushort}),
            fd, TIOCSWINSZ, pointer(buf))
println("Ptr{Cushort}: rc=", rcB, " errno=", Libc.errno(),
        " (", Libc.strerror(Libc.errno()), ")")

wsBuf2 = zeros(Cushort, 4)   # heap Vector, stable address
pOut = pointer(wsBuf2)
rcG = ccall(:ioctl, Cint, (Cint, Culong, Ptr{NTuple{4,Cushort}}),
            fd, TIOCSWINSZ, pWs)  # re-SET via raw pointer first
rcG = ccall(:ioctl, Cint, (Cint, Culong, Ptr{NTuple{4,Cushort}}),
            fd, TIOCGWINSZ, pOut)
enG = Libc.errno()
println("GET into heap Vector: rc=", rcG, " errno=", enG,
        " rows=", Int(wsBuf2[1]), " cols=", Int(wsBuf2[2]))

# Also read back from the slave fd — the child's side.
rcS = ccall(:ioctl, Cint, (Cint, Culong, Ptr{Cvoid}), slave[], TIOCGWINSZ, C_NULL)
wsBuf = zeros(Cushort, 4)
rcS2 = ccall(:ioctl, Cint, (Cint, Culong, Ptr{Cushort}),
             slave[], TIOCGWINSZ, pointer(wsBuf))
println("GET on slave: rc=", rcS2, " rows=", Int(wsBuf[1]), " cols=", Int(wsBuf[2]))
