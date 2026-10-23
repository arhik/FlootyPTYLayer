# updateManifest.jl — re-resolve/instantiate the FlootyPTYLayer environment
# after editing Project.toml.
# Run as a script:
#   julia --startup-file=no --project=<pkgdir> scripts/updateManifest.jl
import Pkg

const pkgDir = dirname(@__DIR__)
Pkg.activate(pkgDir; io = devnull)
Pkg.resolve(io = devnull)
Pkg.instantiate(; io = devnull)
println("Manifest updated at ", joinpath(pkgDir, "Manifest.toml"))
