# spawnRaceRegression.jl — regression for the Darwin zero-slave-fd EOF race.
#
# Between posix_spawnp returning and flootySpawnHelper doing setsid ->
# open(slavePath), NO slave fds exist and read(master) returns 0 (EOF-shaped)
# instead of blocking. Before the SPAWN_EOF_GRACE_SECONDS fix in
# masterReadLoop, a reader task that won that race killed healthy sessions
# (observed symptom: "only the first spawn works").
#
# Covered here:
#   R1  repeated sequential spawns with immediately-started readers
#   R2  overlapping concurrent spawns, all readers started instantly
#   R3  real EOF AFTER output still ends the loop promptly (< 5 s)
#   R4  data-less EOF (child exits silently) still terminates, bounded
#       by the grace window (< 6 s), never hangs forever
import FlootyPTYLayer
using FlootyPTYLayer

const TIMEOUT_S = 15.0

"""Consume outputChannel until `needle` appears or deadline passes."""
function waitFor(h, needle::AbstractString; seconds::Float64 = TIMEOUT_S)
    ch = outputChannel(h)
    deadline = time() + seconds
    parts = String[]
    found() = occursin(needle, join(parts))
    while time() < deadline
        if isready(ch)
            push!(parts, String(take!(ch)))
        elseif !h.open
            break
        else
            sleep(0.02)
        end
        found() && return true
    end
    return found()
end

"""Poll until `h.open` flips false; returns elapsed seconds (capped)."""
function secondsUntilClose(h; cap::Float64 = 12.0)
    t0 = time()
    while h.open && time() - t0 < cap
        isready(outputChannel(h)) && take!(outputChannel(h))
        sleep(0.02)
    end
    return time() - t0
end

failures = String[]

println("== R1: six sequential spawns, reader started immediately ==")
for i in 1:6
    h = spawnPty(`sh -c "tty; echo MARKER_$i"`)  # double quotes: Julia interpolates $i
    ok = waitFor(h, "MARKER_$i")
    openAtEnd = h.open
    closePty!(h)
    if ok
        println("   R1.$i PASS")
    else
        push!(failures, "R1.$i: marker missing (h.open=$openAtEnd)")
        println("   R1.$i FAIL (marker missing, h.open=$openAtEnd)")
    end
end

println("== R2: five overlapping spawns, all readers instant ==")
handles = [spawnPty(`sh -c "sleep 0.2; tty; echo CONC_$i"`) for i in 1:5]  # ditto
oks = Bool[waitFor(h, "CONC_$i") for (i, h) in enumerate(handles)]
foreach(closePty!, handles)
if all(oks)
    println("   R2 PASS")
else
    push!(failures, "R2: concurrent spawns results=$oks")
    println("   R2 FAIL results=", oks)
end

println("== R3: real EOF after output closes the handle promptly ==")
h = spawnPty(`sh -c 'echo EARLY_BYE; exit 0'`)
gotOutput = waitFor(h, "EARLY_BYE")
delay = secondsUntilClose(h; cap = 8.0)
closePty!(h)
if gotOutput && !h.open && delay < 5.0
    println("   R3 PASS (closed after ", round(delay, digits = 2), "s)")
else
    push!(failures, "R3: gotOutput=$gotOutput openAfter=$(h.open) delay=$(round(delay, digits=2))s")
    println("   R3 FAIL gotOutput=", gotOutput, " delay=", round(delay, digits = 2), "s")
end

println("== R4: silent-exit child still terminates within the grace bound ==")
h = spawnPty(`sh -c 'exit 0'`)
delay = secondsUntilClose(h; cap = 10.0)
closePty!(h)
if !h.open && delay < 6.0
    println("   R4 PASS (closed after ", round(delay, digits = 2), "s)")
else
    push!(failures, "R4: openAfter=$(h.open) delay=$(round(delay, digits=2))s")
    println("   R4 FAIL open=", h.open, " delay=", round(delay, digits = 2), "s")
end

if isempty(failures)
    println("SPAWN_RACE_REGRESSION_ALL_PASS")
else
    foreach(f -> println("FAILURE: ", f), failures)
    error("spawnRaceRegression: $(length(failures)) failure(s)")
end
