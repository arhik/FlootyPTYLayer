# addDeps.jl — swap WebUI deps for Webviews + HTTP in the dev project.
using Pkg
Pkg.activate("/Users/arhik/.julia/dev/FlootyPTYLayer")
# Webviews is registered (same author as WebviewsGLFW); pin to the depot's 1.2.0.
Pkg.add(name = "Webviews", version = "1.2.0")
Pkg.add("HTTP")
Pkg.rm(["WebUI", "WebUI_jll"])
println("DEPS_UPDATED")
