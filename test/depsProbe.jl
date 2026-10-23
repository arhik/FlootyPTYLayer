# depsProbe.jl — confirm Webviews / HTTP resolve and load under this project.
# Run as a script:
#   julia --startup-file=no --project=. test/depsProbe.jl
using Pkg
if Base.identify_package("FlootyPTYLayer") === nothing
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end

using Webviews
using HTTP
using FlootyPTYLayer  # force the whole dependency graph (incl. Webviews) to load

println("Webviews loaded OK: ", typeof(Webviews.Webview))
println("HTTP loaded OK: ", typeof(HTTP.serve!))
