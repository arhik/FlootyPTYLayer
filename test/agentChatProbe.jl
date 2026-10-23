# agentChatProbe.jl — renders the activity rail for real and checks that it is a
# CHAT WINDOW, not a log dump.
#
# The window is the real one (same page, same handlers the app uses), and an
# actual session is ADOPTED into it. Both directions are covered:
#   * Julia → page: pushAgentEventToWindow with an AgentTextEvent /
#     AgentThinkingEvent lands as a role-tagged chat message in that session's
#     transcript;
#   * page → transcript: the production producers (window.handleAgentEvent with
#     kind text/thinking/toolcall/toolresult/status, the assist Send button,
#     window.handleTerminalExit) drive a transcript whose DOM is then asserted.
#
# The scope rule this pins down: the chat carries the agent's TEXT and REASONING
# only. Tool calls, commands and their output live in the terminal pane, so
# kind=toolcall/toolresult/status must NOT add chat messages — they feed the
# status strip alone (running / ok / err / plain).
#
# Assertions: per-role bubbles, you-right/agent-left alignment, distinct styling
# per role, streamed same-role lines coalescing into ONE growing message, labels
# carrying role + clock, per-tab isolation, parked messages flushed once the PTY
# id is known, the 200-message cap trimming the DOM with the model, tail-follow
# scrolling, the empty-state hint, and textContent-only rendering (agent text can
# never inject markup).
#
# Requires a desktop session: it opens the native window (same as
# createdTabReplayProbe.jl).
#
# Run: julia --startup-file=no --project=. test/agentChatProbe.jl
# Verdict line on stdout: [CHAT-PROBE] {"failed":N,"checks":M}
import FlootyPTYLayer
using FlootyPTYLayer
import Webviews

# Raw string: no Julia escapes/interpolation, so the JS keeps its own backslashes.
# __SID__ is replaced with the adopted session's terminal id.
const _CHAT_PROBE_JS = raw"""
(function () {
  function report(payload) {
    try { window.flootyDebug && window.flootyDebug('[CHAT-PROBE-PAGE] ' + payload); } catch (e) {}
    if (typeof probeChatReport === 'function') probeChatReport(payload);
    else { try { window.flootyDebug && window.flootyDebug('[CHAT-PROBE-PAGE] reporter MISSING'); } catch (e) {} }
  }
  const checks = [];
  try {
  window.flootyDebug && window.flootyDebug('[CHAT-PROBE-PAGE] script-start reporter=' +
                                           (typeof probeChatReport));
  const SID = "__SID__";
  function ok(name, cond, extra) {
    checks.push({ name: name, ok: !!cond,
                  extra: (cond || extra === undefined) ? null : extra });
    try { window.flootyDebug && window.flootyDebug('[CHAT-PROBE-PAGE] ' +
        (cond ? 'ok   ' : 'FAIL ') + name); } catch (e) {}
  }
  const log = document.getElementById('agentChatLog');
  const rect = n => n.getBoundingClientRect();
  const logRect = log.getBoundingClientRect();
  const byRole = (root, r) =>
    [...root.querySelectorAll('.chat-msg')].filter(n => n.classList.contains('role-' + r));
  const bubbleBg = n => getComputedStyle(n.querySelector('.chat-bubble')).backgroundColor;
  const mkInfo = jid => ({ term: { write: function () {}, rows: 24,
                                   buffer: { active: { length: 0,
                                                       getLine: function () { return undefined; } } } },
                          fitAddon: null, name: 'synthetic', juliaId: jid,
                          view: 'user', exited: false, popups: [], chat: [] });

  // ---- Julia → page → bubble ---------------------------------------------
  const sidTab = Object.values(terminals).find(i => i.juliaId === SID);
  ok('the adopted session has a tab in the page', !!sidTab);
  if (sidTab) {
    const texts = (sidTab.chat || []).map(m => m.text).join('\n');
    ok('Julia-pushed agent TEXT reached that transcript',
       texts.includes('integration: text from Julia'));
    ok('Julia-pushed thinking reached that transcript',
       texts.includes('integration: reason from Julia'));
    const roles = (sidTab.chat || []).map(m => m.role);
    ok('thinking is tagged as reasoning, text as speech',
       roles.includes('thinking') && roles.includes('text') &&
       !roles.includes('agent'));
    const sidKey = Object.keys(terminals).find(k => terminals[k] === sidTab);
    switchToTerminal(sidKey);
    ok('its transcript is what the rail shows while its tab is active',
       log.textContent.includes('integration: text from Julia') &&
       log.textContent.includes('integration: reason from Julia'));
  }

  // ---- a synthetic session drives the rest deterministically -------------
  const info = mkInfo('probe-sid');
  info.fitAddon = { fit: function () {} };
  terminals['term-probe'] = info;
  switchToTerminal('term-probe');
  ok('an empty transcript shows a hint, not a bubble',
     !!log.querySelector('.chat-empty') && log.querySelectorAll('.chat-msg').length === 0);

  // The status strip carries NO agent activity by design (the chat/tool blocks and
  // the live phase line are the surfaces).
  ok('the status strip has no agent-activity slot',
     document.getElementById('status-agent') === null);
  window.handleAgentEvent('probe-sid',
      { kind: 'toolcall', id: 'p1', tool: 'send', text: 'echo hello' });
  ok('the call opens ONE folded block in the transcript',
     log.querySelectorAll('.chat-tool').length === 1 &&
     log.querySelector('.chat-tool').open === false,
     log.querySelectorAll('.chat-tool').length);
  window.handleAgentEvent('probe-sid',
      { kind: 'toolresult', id: 'p1', ok: true, text: 'hello' });
  ok('its result fills the SAME block (id-paired) and keeps it folded',
     log.querySelectorAll('.chat-tool').length === 1 &&
     log.querySelector('.chat-tool').open === false &&
     log.querySelector('.tool-body pre').textContent === 'hello',
     [log.querySelectorAll('.chat-tool').length,
      log.querySelector('.tool-body pre').textContent]);
  ok('the block shows where the call is',
     log.querySelector('.tool-name').textContent === 'send' &&
     log.querySelector('.tool-detail').textContent === 'echo hello');
  ok('the block shows the ok outcome (no status strip anymore)',
     log.querySelector('.tool-state').className.indexOf('ok') >= 0,
     log.querySelector('.tool-state').className);
  window.handleAgentEvent('probe-sid',
      { kind: 'toolcall', id: 'p2', tool: 'send', text: 'boom' });
  window.handleAgentEvent('probe-sid',
      { kind: 'toolresult', id: 'p2', ok: false, text: 'ERROR: nope' });
  ok('a failed result marks its block err',
     log.querySelectorAll('.chat-tool')[1].querySelector('.tool-state').className
        .indexOf('err') >= 0,
     log.querySelectorAll('.chat-tool')[1].querySelector('.tool-state').className);
  window.handleAgentEvent('probe-sid',
      { kind: 'status', text: '[turn 2] wait 2.0s' });
  ok('bookkeeping info lines stay OUT of the transcript',
     !log.textContent.includes('[turn 2] wait 2.0s'));
  ok('tool blocks are the ONLY chat rows so far',
     log.querySelectorAll('.chat-msg').length === 2 &&
     log.querySelectorAll('.chat-msg.role-tool').length === 2,
     log.querySelectorAll('.chat-msg').length);
  // Markdown for agent prose, with raw HTML kept as text. The bundles arrive as an
  // ES module, so wait for them before judging (the page rebuilds on arrival).
  let mdNodesBefore = log.querySelectorAll('.chat-msg').length;
  window.handleAgentEvent('probe-sid', { kind: 'text',
      text: '# Heading\n\n- one\n- two\n\n\`\`\`julia\nprintln(6*7)\n\`\`\`\n\ninjected <img src=x onerror=alert(1)> stays text' });
  let md = log.querySelector('.chat-bubble.md');
  if (typeof window.micromark !== 'function') {
    // Not loaded yet in this run: report what we have and skip the formatting claim.
    ok('micromark bundle loaded (module present)', false,
       'typeof window.micromark = ' + typeof window.micromark);
  }
  ok('agent text renders as markdown (heading, list, fenced code)',
     !!md && !!md.querySelector('h1') && !!md.querySelector('ul li') &&
     !!md.querySelector('pre code'),
     md ? md.innerHTML.slice(0, 90) : 'no markdown bubble');
  // Reasoning is markdown too (same renderer, its own dim chrome).
  window.handleAgentEvent('probe-sid', { kind: 'thinking',
      text: '- ' + '\`' + 'names(WGPUCompute, all=true)' + '\`' + '\n\n\`\`\`julia\nusing WGPUCompute\n\`\`\`' });
  const think = [...log.querySelectorAll('.chat-bubble.md')].pop();
  const thinkIsThinking = think && think.parentElement.classList.contains('role-thinking');
  ok('reasoning renders as markdown as well (list, fenced code)',
     typeof window.micromark === 'function' && !!think && thinkIsThinking &&
     !!think.querySelector('ul li') && !!think.querySelector('pre code'),
     think ? think.innerHTML.slice(0, 80) : 'no thinking bubble');
  ok('reasoning keeps its own chrome (italic prose, upright code)',
     !!think && getComputedStyle(think).fontStyle === 'italic' &&
     (!think.querySelector('pre code') ||
      getComputedStyle(think.querySelector('pre code')).fontStyle === 'normal'));
  mdNodesBefore = log.querySelectorAll('.chat-msg').length;   // markdown rows are done
  ok('markdown never injects markup from agent text',
     !!md && md.querySelectorAll('img, script').length === 0 &&
     md.textContent.indexOf('<img src=x') >= 0,
     md ? md.querySelectorAll('img, script').length : -1);
  log.querySelectorAll('.chat-msg');

  // Text streams into ONE growing bubble, like any chat.
  window.handleAgentEvent('probe-sid',
      { kind: 'text', text: 'Booting the project and running the test suite' });
  window.handleAgentEvent('probe-sid',
      { kind: 'text', text: 'Tests pass; patching the parser next' });
  window.handleAgentEvent('probe-sid',
      { kind: 'thinking', text: 'The failure sits in the tokenizer, so I will fix that first.' });
  const typed = 'fix the failing parser tests and show me the diff';
  assistCm.setValue(typed);
  document.getElementById('assistSend').click();
  window.handleTerminalExit('probe-sid', 0);

  let nodes = [...log.querySelectorAll('.chat-msg')].slice(mdNodesBefore);
  ok('messages appear in arrival order: text, thinking, you, system',
     nodes.map(n => n.className.replace('chat-msg role-', '')).join(',') ===
     'text,thinking,user,system',
     nodes.map(n => n.className));
  const textRows = nodes.filter(n => n.classList.contains('role-text'));
  ok('two streamed text lines grew ONE message', textRows.length === 1, textRows.length);
  const firstText = textRows[0].querySelector('.chat-bubble').textContent;
  ok('that message kept both lines',
     firstText.indexOf('Booting the project') >= 0 &&
     firstText.indexOf('patching the parser') >= 0, firstText.slice(0, 80));
  ok('your message shows the text you sent',
     nodes.some(n => n.classList.contains('role-user') &&
                     n.querySelector('.chat-bubble').textContent === typed));
  ok('your bubble hugs the right edge',
     Math.abs(rect(byRole(log, 'user')[0].querySelector('.chat-bubble')).right - logRect.right) < 30,
     [Math.round(rect(byRole(log, 'user')[0].querySelector('.chat-bubble')).right),
      Math.round(logRect.right)]);
  ok('the agent bubble hugs the left edge',
     Math.abs(rect(byRole(log, 'text')[0].querySelector('.chat-bubble')).left - logRect.left) < 24,
     [Math.round(rect(byRole(log, 'text')[0].querySelector('.chat-bubble')).left),
      Math.round(logRect.left)]);
  ok('the four roles are styled differently',
     new Set([bubbleBg(byRole(log, 'user')[0]), bubbleBg(byRole(log, 'text')[0]),
              bubbleBg(byRole(log, 'thinking')[0]), bubbleBg(byRole(log, 'system')[0])]).size === 4,
     [bubbleBg(byRole(log, 'user')[0]), bubbleBg(byRole(log, 'text')[0]),
      bubbleBg(byRole(log, 'thinking')[0]), bubbleBg(byRole(log, 'system')[0])]);
  ok('reasoning is rendered as dimmed italic',
     getComputedStyle(byRole(log, 'thinking')[0].querySelector('.chat-bubble')).fontStyle === 'italic');
  ok('every message carries a role label and a clock',
     nodes.every(n => /^(You|Agent|Thinking|System) · \d\d:\d\d$/
                          .test(n.querySelector('.chat-who').textContent)),
     nodes.map(n => n.querySelector('.chat-who').textContent));
  ok('the old flat log strip is gone', !document.getElementById('thinkingContent'));

  // ---- agent text is data, never markup ---------------------------------
  window.handleAgentEvent('probe-sid',
      { kind: 'text', text: '<img src=x onerror="alert(1)"> **not markdown**' });
  const injected = [...log.querySelectorAll('.chat-msg')].pop();
  ok('agent text is never parsed as markup',
     injected.querySelectorAll('img').length === 0 &&
     injected.querySelector('.chat-bubble').textContent.includes('<img'));

  // ---- cap + tail following ----------------------------------------------
  info.chat = [];
  info.chatTrimmed = false;
  renderActiveAgentChat();
  for (let i = 0; i < 220; i++) {
    if (i % 2 === 0) window.handleAgentEvent('probe-sid',
        { kind: 'text', text: 'agent line ' + i });
    else window.handleAgentEvent('probe-sid',
        { kind: 'thinking', text: 'thinking line ' + i });
  }
  const domCount = log.querySelectorAll('.chat-msg').length;
  ok('the transcript is capped at 200 messages, DOM included',
     domCount === 200 && info.chat.length === 200, [domCount, info.chat.length]);
  ok('the trimmed message left the DOM with the model',
     !log.textContent.includes('agent line 0') && log.textContent.includes('thinking line 219'));
  ok('the rail stays pinned to the newest message',
     (log.scrollHeight - log.scrollTop - log.clientHeight) < 40,
     [log.scrollHeight, Math.round(log.scrollTop), log.clientHeight]);

  // ---- per-tab isolation -------------------------------------------------
  const other = mkInfo('other-sid');
  terminals['term-other'] = other;
  switchToTerminal('term-other');
  ok('a second session starts with an empty transcript',
     !!log.querySelector('.chat-empty') && log.querySelectorAll('.chat-msg').length === 0);
  window.handleAgentEvent('other-sid', { kind: 'text', text: 'text of the OTHER session' });
  const otherText = log.textContent;
  switchToTerminal('term-probe');
  ok('each tab keeps its own conversation',
     otherText.includes('OTHER session') && !log.textContent.includes('OTHER session'));
  ok('switching back repaints that tab in full',
     log.textContent.includes('thinking line 219') &&
     log.querySelectorAll('.chat-msg').length === 200);

  // ---- messages for a session with no tab yet ---------------------------
  window.handleAgentEvent('future-sid', { kind: 'text', text: 'pushed while nothing was bound' });
  ok('a message for an unbound session is parked, not lost', parkedChat.length === 1,
     parkedChat.length);
  const future = mkInfo(null);
  terminals['term-future'] = future;
  switchToTerminal('term-future');
  ok('it stays parked until that PTY id is bound',
     parkedChat.length === 1 && !log.textContent.includes('nothing was bound'));
  future.juliaId = 'future-sid';
  renderActiveAgentChat();
  ok('binding the id surfaces it exactly once',
     parkedChat.length === 0 && log.querySelectorAll('.chat-msg').length === 1 &&
     log.textContent.includes('nothing was bound'));

  // ---- blank pushes ------------------------------------------------------
  const before = future.chat.length;
  window.handleAgentEvent('future-sid', { kind: 'text', text: '   ' });
  window.handleAgentEvent('future-sid', { kind: 'thinking', text: '' });
  ok('blank lines never create a message', future.chat.length === before);

  const failed = checks.filter(c => !c.ok);
  const payload = JSON.stringify({ failed: failed.length, checks: checks.length,
                                   failures: failed.map(c => c.name + (c.extra === null ? '' : ' ' + JSON.stringify(c.extra))) });
  report(payload);
  // Ask Julia to close the window through the app's own close binding: that is
  // the proven teardown path (the close button uses it) and it ends the event
  // loop without depending on a timer or a background task being scheduled.
  try { callJulia('flootyCloseWindow', '{}').catch(function () {}); } catch (e) {}
  return payload;
  } catch (err) {
    const diag = { terms: Object.keys(typeof terminals === 'object' ? terminals : {}),
                   active: typeof activeTerminalId === 'string' ? activeTerminalId : String(activeTerminalId),
                   hasEventFn: typeof window.handleAgentEvent,
                   hasPushChat: typeof pushChat,
                   probeChat: (typeof terminals === 'object' && terminals['term-probe'] &&
                               terminals['term-probe'].chat) ? terminals['term-probe'].chat.length : -1 };
    report(JSON.stringify({ failed: -2, checks: -2,
                            failures: ['probe script threw: ' + (err && err.message)],
                            done: checks,
                            diag: diag,
                            stack: String(err && err.stack).slice(0, 300) }));
    return 'probe script threw: ' + err;
  }
})()
"""

"""Replace the __SID__ placeholder with the adopted session's terminal id."""
chatProbeScript(sid::AbstractString) = replace(_CHAT_PROBE_JS, "__SID__" => sid)

println("starting a session for the agent-chat probe ...")
sess = startReplSession(`julia --startup-file=no -q`)
try
    agentWriteAndWait(sess, "CHAT_PROBE_READY = 1"; timeout = 90.0).ok ||
        (println("SESSION_FAILED: no idle prompt"); exit(1))
catch e
    println("SESSION_FAILED: ", sprint(showerror, e))
    exit(1)
end

println("loading OK; launching UI for agent-chat probe ...")
wv = try
    launchTerminalUI()
catch e
    println("LAUNCH_FAILED: ", sprint(showerror, e))
    exit(1)
end

# The page reports its verdict through THIS binding (registered before the
# window loads), so the probe asserts in Julia instead of scraping stdout.
report = Ref("")
Webviews.bind(wv, "probeChatReport") do args
    report[] = args isa Tuple && !isempty(args) ? String(args[1]) : ""
    return "{\"success\":true}"
end

adoptId = ""
t0 = time()
prog(msg) = (println("[CHAT-PROBE-RUN] ", round(time() - t0; digits = 1), "s ", msg);
             flush(stdout))

# Everything is sequenced with Webviews timers, which run ON the event loop
# (main thread). A background task would not do: while AppKit spins the native
# loop, a task parked in sleep()/lock() is only resumed when something pumps
# Julia's scheduler, so the old @async + dispatch probes only progressed when
# stray native events (clicks, keystrokes) happened to arrive.
function chatProbeWaitReady()
    adopted = lock(() -> length(FlootyPTYLayer.OWNERSHIP_SESSIONS),
                   FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK)
    if adopted == 0
        # The page auto-creates its own session-backed tab on load, and
        # handleTerminalCreate registering it proves the page script is up
        # (adopting earlier is silently dropped: "adoptTerminal MISSING on page").
        if time() - t0 > 30.0
            println("[CHAT-PROBE] FAIL: the page never created its session tab")
            FlootyPTYLayer.requestStopEventLoop!(wv)
            return
        end
        Webviews.set_timeout(chatProbeWaitReady, wv, 0.25)
        return
    end
    prog("page ready (" * string(adopted) * " adopted) — adopting the probe session")
    try
        global adoptId = adoptSessionTerminal!(sess; name = "chat probe")
    catch e
        println("ADOPT_FAILED: ", sprint(showerror, e))
    end
    prog("adopted as " * adoptId)
    Webviews.set_timeout(chatProbePush, wv, 1.5)   # let the page render the tab
end

function chatProbePush()
    prog("pushing through the real producers")
    pushAgentEventToWindow(wv, AgentTextEvent(adoptId, "integration: text from Julia"))
    pushAgentEventToWindow(wv, AgentThinkingEvent(adoptId, "integration: reason from Julia"))
    Webviews.set_timeout(chatProbeAssert, wv, 1.0)
end

function chatProbeAssert()
    prog("dispatching the page-side assertion suite")
    try
        Webviews.eval!(wv, chatProbeScript(adoptId))
    catch e
        println("EVAL_FAILED: ", sprint(showerror, e))
    end
    # The page reports its verdict and then closes the window through the app's
    # close binding, which ends the loop — no polling needed.
end

Webviews.set_timeout(() -> chatProbeWaitReady(), wv, 2.0)   # let the page load
Webviews.set_timeout(function ()
    prog("watchdog: nothing closed the window — closing it here")
    try
        Webviews.close(wv)
    catch e
        FlootyPTYLayer.requestStopEventLoop!(wv)
    end
end, wv, 120.0)

FlootyPTYLayer.runEventLoopAndTeardown!(wv)
closeSession!(sess)

# The report travels over the RPC channel; give the last message time to land.
waitDeadline = time() + 3.0
while time() < waitDeadline && isempty(report[])
    sleep(0.1)
end

verdict = report[]
parsed = FlootyPTYLayer.jsonArgs(verdict)
failed = FlootyPTYLayer.jsonInt(parsed, :failed, -1)
checks = FlootyPTYLayer.jsonInt(parsed, :checks, 0)
println("[CHAT-PROBE] ",
        isempty(verdict) ? "{\"failed\":-1,\"checks\":0}" : verdict,
        "  (failed=", failed, " of ", checks, ")")
failed == 0 || exit(1)
println("AGENT_CHAT_PROBE_OK")
exit(0)
