module FlootyPTYLayer

using Dates
using Logging
using Sockets
using UUIDs

import FlootyREPLBridge
import ShadowTerm
using FlootyREPLBridge: EvalOutcome, EvalRegistry, registerEval!, resolveEval!,
    recentHistory, wrapWithSentinels, parseSentinels, detectReplFlavor,
    classifyError, classifyShellError, BeginEval, EndEval, ReplFlavor

# ---- flootyPty.jl ----------------------------------------------------------
export PtyHandle, spawnPty, writeToPty, outputChannel, resizePty!, closePty!, ptyWinsize
# ---- controlState.jl -------------------------------------------------------
export ControlState, setControlState!, currentState, controlHistory,
    canAgentWrite, tagIn, tagOut
# ---- session.jl ------------------------------------------------------------
export ReplSession, startReplSession, agentWriteAndWait, userWrite,
    writeStatusSidecar!, sessionHistory, closeSession!,
    addOutputTap!, removeOutputTap!,
    isInteractiveCommand, tailEnd, inAltScreen, replMode,
    addChatTabUi, addBrowserTabUi, addNewChatHandler!, addChatCloseHandler!,
    addNewBrowserHandler!, addNewPdfHandler!,
    addBrowserNavigateHandler!, pendingInputLine, unterminatedHeredoc, hasHeredoc, recoverStuckContinuation!, splitSession, setSplitSession!, splitParentSession,
    splitChildSession, splitChildren, splitChildAt, splitCount
# ---- flootyWebUi.jl --------------------------------------------------------
export launchTerminalUI, runTerminalUI, stopTerminalUI,
    addAssetMount!, removeAssetMount!,
    pushAgentFeedbackToWindow, activeTerminalUiWebview,
    adoptSessionTerminal!, attachSessionTerminalToWindow,
    registerAdoptedSession!, handleTerminalCreate, handleTerminalReconnect,
    pushOwnershipToWindow, addControlStateListener!,
    pushAssistPrompt!, takeAssistPrompts!, pushAgentEventToWindow,
    AbstractAgentEvent, AgentTextEvent, AgentThinkingEvent,
    AgentToolCallEvent, AgentToolResultEvent, AgentStatusEvent,
    AgentContextUsageEvent, AgentMonitorConfidenceEvent,
    AgentProgressEvent, AgentInsightEvent, AgentMonitorThinkingEvent,
    AgentBrowserNavigateEvent,
    sessionIdFor, setActiveOwnershipSession,
    addSessionTerminalHook!, addSessionTerminalCloseHook!,
    applyOwnershipAction!, createTerminalUi,
    terminalBufferFor, shadowLines, shadowText, shadowCursor, shadowResize!,
    shadowTextFor, shadowLinesFor,
    gridChecksum, terminalDivergence,
    openBrowserWindow!, navigateBrowserWindow!, closeBrowserWindow!, addPdfToolResultHandler!, addPdfInteractionHandler!,
    addNewTypstHandler!, addTypstTabUi,
    addNewFileTreeHandler!, addFileTreeTabUi, addFileTreeCloseHandler!,
    addEditorEventHandler!, addEditorListHandler!, addEditorToggleHandler!,
    addEditorReadHandler!,
    addWorkspaceHandler!,
    closeAllBrowserWindows!, browserWindowInfo, browserWindowOpen,
    addAgentModelHooks!, agentModelState, setSplitSession!, addWorkspaceHooks!,
    gpuRendererReport, openTerminalWindow, runTerminalWindow,
    startComputerUseServer!, computerUsePort

"""
    activeTerminalUiWebview() -> Union{Webviews.Webview, Nothing}

The webview of the running terminal UI (for pushing agent feedback popups),
or `nothing` when no UI is live.
"""
activeTerminalUiWebview() = terminalUiWebview[]

include("flootyPty.jl")
include("controlState.jl")
include("computerUseCapture.jl")
include("computerUse.jl")
include("session.jl")
include("shadowTerminal.jl")
include("flootyWebUi.jl")
include("divergence.jl")

include("browserWindow.jl")

const TerminalSession = ReplSession
const startTerminalSession = startReplSession
export TerminalSession, startTerminalSession
end # module FlootyPTYLayer
