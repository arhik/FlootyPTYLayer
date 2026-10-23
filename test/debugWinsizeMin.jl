# debugWinsizeMin.jl — absolute minimal: openpty, one SET, one GET, print.
master = Ref{Cint}(-1)
slave = Ref{Cint}(-1)
rc = ccall((:openpty, "libc"), Cint,
           (Ref{Cint}, Ref{Cint}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
           master, slave, C_NULL, C_NULL, C_NULL)
println("openpty rc=", rc, " m=", master[], " s=", slave[])
m = master[]
s = slave[]

reqSet = Culong(0x80087467)  # TIOCSWINSZ from headers
reqGet = Culong(0x40087468)  # TIOCGWINSZ from headers

# SET: same rule — pass a Ref OBJECT, never a bare tuple.
ws = Ref((Cushort(40), Cushort(120), Cushort(0), Cushort(0)))
rcS = ccall(:ioctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}),
            m, reqSet, ws)
println("SET rc=", rcS)

# GET: sentinel buffer. NOTE: must pass a Ref OBJECT when argtype is Ref{...};
# passing a bare tuple makes ccall treat its inline data as T** → heap corruption.
g = Ref((Cushort(9), Cushort(9), Cushort(9), Cushort(9)))
rcG = ccall(:ioctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}), m, reqGet, g)
println("GET(master) rc=", rcG, " -> ", g[][1], " x ", g[][2])

g2 = Ref((Cushort(9), Cushort(9), Cushort(9), Cushort(9)))
rcG2 = ccall(:ioctl, Cint, (Cint, Culong, Ref{NTuple{4,Cushort}}), s, reqGet, g2)
println("GET(slave)  rc=", rcG2, " -> ", g2[][1], " x ", g2[][2])
