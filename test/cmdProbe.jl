# cmdProbe.jl — what do Cmd fields look like?
c1 = `julia --startup-file=no -q`
println("plain   exec=", typeof(getfield(c1, :exec)), " ", repr(getfield(c1, :exec)))
println("plain   dir =", repr(getfield(c1, :dir)))
println("plain   env =", typeof(getfield(c1, :env)), " ", repr(getfield(c1, :env)))
c2 = setenv(c1, "FLOOTY_PROBE" => "flooty-ok")
println("setenv  dir =", repr(getfield(c2, :dir)))
println("setenv  env=", typeof(getfield(c2, :env)))
