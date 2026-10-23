# controlState.jl — duplex control model for one live REPL session.
# States: :user | :agent | :shared.
#   * User writes ALWAYS pass (duplex guarantee), in every state.
#   * Agent writes require the state to be :agent or :shared.
# Tag-in (:user → :agent/:shared) and tag-out (:agent/:shared → :user)
# transitions are recorded with wall-clock timestamps.

"""Valid control states."""
const CONTROL_STATES = (:user, :agent, :shared)

"""
Mutable control machine for a ReplSession. All transitions go through
`setControlState!` so history stays consistent; reads are lock-protected.
"""
mutable struct ControlState
    state::Symbol
    history::Vector{Pair{Float64,Symbol}}   # (time, newState) in transition order
    lock::ReentrantLock
    # Listeners scoped to THIS state: a per-session listener must not hear
    # another session's transitions.
    listeners::Vector{Function}
end

function ControlState(initial::Symbol = :shared)
    s = validState(initial)
    return ControlState(s, Pair{Float64,Symbol}[time() => s], ReentrantLock(),
                        Function[])
end

function validState(s::Symbol)
    s in CONTROL_STATES ||
        throw(ArgumentError("control state must be one of $CONTROL_STATES, got $s"))
    return s
end

const CONTROL_STATE_LISTENERS = Vector{Function}()

"""
    addControlStateListener!(f) :: Function

Register a PROCESS-WIDE listener `f(action::Symbol)` fired on EVERY control
transition of ANY session: `:takeover` (:user), `:resume` (:agent/:shared).
Returns a removal closure.

Prefer the scoped form `addControlStateListener!(cs, f)`: a listener that
belongs to one session must not report another session's ownership.
"""
function addControlStateListener!(f::Function)
    push!(CONTROL_STATE_LISTENERS, f)
    return () -> begin
        filter!(g -> g !== f, CONTROL_STATE_LISTENERS)
        return nothing
    end
end

"""
    addControlStateListener!(cs::ControlState, f) :: Function

Register a listener `f(action::Symbol)` fired on THIS session's control
transitions only (`:takeover` when the user takes the REPL, `:resume` when it
goes back to the agent). Returns a removal closure.

The scoped form is what per-session UI needs: a process-wide listener would
report other sessions' ownership and repaint the wrong pane.
"""
function addControlStateListener!(cs::ControlState, f::Function)
    lock(cs.lock) do
        push!(cs.listeners, f)
    end
    return () -> begin
        lock(cs.lock) do
            filter!(g -> g !== f, cs.listeners)
        end
        return nothing
    end
end

"""
    setControlState!(cs::ControlState, state::Symbol) :: Symbol

Transition to `state` (`:user`, `:agent`, or `:shared`). Returns the new state;
identical-state transitions are not recorded twice in the history. Every actual
transition fires the registered listeners with `:takeover` / `:resume` — the
ones scoped to this session first, then the process-wide ones.
"""
function setControlState!(cs::ControlState, state::Symbol)
    validState(state)
    changed = false
    lock(cs.lock) do
        changed = cs.state != state
        changed && push!(cs.history, time() => state)
        cs.state = state
    end
    if changed
        action = state == :user ? :takeover : :resume
        for f in copy(lock(() -> cs.listeners, cs.lock))
            try
                f(action)
            catch err
                @debug "controlState: scoped ownership listener failed" exception = err
            end
        end
        for f in copy(CONTROL_STATE_LISTENERS)
            try
                f(action)
            catch err
                @debug "controlState: ownership listener failed" exception = err
            end
        end
    end
    return state
end

"Current control state."
currentState(cs::ControlState) = lock(() -> cs.state, cs.lock)

"Transition record: `Vector{Pair{timestamp, state}}` oldest-first."
controlHistory(cs::ControlState) = lock(() -> copy(cs.history), cs.lock)

"""
    canAgentWrite(cs::ControlState) :: Bool

Agent writes are permitted only while the session is in `:agent` or `:shared`.
User writes are always permitted and never consult this gate.
"""
function canAgentWrite(cs::ControlState)
    s = currentState(cs)
    return s == :agent || s == :shared
end

"""
    tagIn(cs::ControlState; mode::Symbol=:agent)

User hands the REPL to the agent. `mode` is `:agent` (exclusive agent driving)
or `:shared` (both may write). Returns the resulting state.
"""
function tagIn(cs::ControlState; mode::Symbol = :agent)
    mode in (:agent, :shared) ||
        throw(ArgumentError("tagIn mode must be :agent or :shared, got $mode"))
    return setControlState!(cs, mode)
end

"Agent yields the REPL back to the user. Returns the resulting state (`:user`)."
tagOut(cs::ControlState) = setControlState!(cs, :user)
