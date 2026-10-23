# chatIsolationProbe.jl — TWO tabs, one chat transcript each. Events for tab A must
# never appear in tab B; an event with NO session id belongs to the ACTIVE tab only.
#
# Reported: "mixing happening in the chat window in multiple tabs". The page treated
# an empty session id as a broadcast (events fired before the bind, or sessions that
# were never registered), and parked events with an empty sid were flushed into
# whichever tab rendered next.
#
# The whole scenario runs INSIDE ONE page evaluation: sleeps inside run-loop
# callbacks block the UI thread, so dispatched evals land late and a probe that
# waits between them asserts one step behind. In-page timers have none of that skew;
# the page also computes the verdicts itself (nested JSON is a parsing trap).
#
# Run: julia --startup-file=no --project=. test/chatIsolationProbe.jl  (opens a window)
import FlootyPTYLayer
import Webviews
const L = FlootyPTYLayer

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

wv = L.launchTerminalUI()

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHAT_ISOLATION_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function run()
    # waitPrompt=false: the default waits for a JULIA prompt (90 s x two shells).
    s1 = L.startReplSession(`zsh -i`; waitPrompt = false)
    s2 = L.startReplSession(`zsh -i`; waitPrompt = false)
    id1 = L.adoptSessionTerminal!(s1; name = "one")
    id2 = L.adoptSessionTerminal!(s2; name = "two")
    println("ids: one=", id1, " two=", id2)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__iso__"), L.TERMINAL_BUFFER_LOCK)
    script = """
    (function () {
        var ID1 = "$(id1)", ID2 = "$(id2)";
        var out = [];
        function ok(name, cond, detail) { out.push({ name: name, ok: !!cond,
                                                     detail: String(detail || '') }); }
        // Page state is read through the page's own hook: `terminals` is a
        // script-scoped `let` and evaluations cannot rely on seeing it.
        function state() { return window.flootyChatState(); }
        function tabOf(id) {
            var st = state();
            for (var k in st.tabs) if (st.tabs[k].juliaId === id) return st.tabs[k];
            return null;
        }
        function textOf(tab) {
            return ((tab && tab.chat) || []).map(function (m) { return m.text; }).join('|');
        }
        function activeTab() { var st = state(); return st.tabs[st.active] || null; }
        function done() {
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__iso__',
                text: JSON.stringify({ checks: out }) })).catch(function () {});
        }
        var tries = 0;
        function waitTabs(then) {
            if (tabOf(ID1) && tabOf(ID2)) return then();
            if (tries++ > 200) { ok('both tabs appeared', false, 'timeout'); return done(); }
            setTimeout(function () { waitTabs(then); }, 100);
        }
        function body() {
        waitTabs(function () {
            // Give the UI's own default tab time to appear (it is created by the
            // boot, AFTER adoption) so it cannot steal the active slot mid-test.
            setTimeout(function () {
                var t1 = tabOf(ID1), t2 = tabOf(ID2);
                window.handleAgentEvent(ID1, { kind: 'text', text: 'MSG-FOR-ONE' });
                window.handleAgentEvent(ID2, { kind: 'text', text: 'MSG-FOR-TWO' });
                setTimeout(function () {
                    ok('tab ONE holds only its own message',
                       textOf(tabOf(ID1)).indexOf('MSG-FOR-ONE') >= 0 &&
                       textOf(tabOf(ID1)).indexOf('MSG-FOR-TWO') < 0, textOf(tabOf(ID1)));
                    ok('tab TWO holds only its own message',
                       textOf(tabOf(ID2)).indexOf('MSG-FOR-TWO') >= 0 &&
                       textOf(tabOf(ID2)).indexOf('MSG-FOR-ONE') < 0, textOf(tabOf(ID2)));
                    // Empty session id: ACTIVE tab only.
                    switchToTerminal(ID2);
                    var act = activeTab();
                    window.handleAgentEvent('', { kind: 'text', text: 'UNBOUND-EVENT' });
                    setTimeout(function () {
                        ok('an unbound event lands in the ACTIVE tab',
                           textOf(activeTab()).indexOf('UNBOUND-EVENT') >= 0, textOf(activeTab()));
                        ok('…and NOT in the other tab',
                           textOf(tabOf(ID1)).indexOf('UNBOUND-EVENT') < 0, textOf(tabOf(ID1)));
                        // A session with no tab: parked, not leaked into any tab.
                        window.handleAgentEvent('ghost-session',
                                                { kind: 'text', text: 'GHOST-MSG' });
                        setTimeout(function () {
                            switchToTerminal(ID1);
                            setTimeout(function () {
                                ok('an event for a session with NO tab never leaks into a tab',
                                   textOf(tabOf(ID1)).indexOf('GHOST-MSG') < 0 &&
                                   textOf(tabOf(ID2)).indexOf('GHOST-MSG') < 0,
                                   textOf(tabOf(ID1)) + ' / ' + textOf(tabOf(ID2)));
                                window.handleAgentEvent(ID1, { kind: 'toolcall', id: 'call-1',
                                    tool: 'send', text: 'ls' });
                                setTimeout(function () {
                                    ok('tool calls are per-tab',
                                       textOf(tabOf(ID1)).indexOf('ls') >= 0 &&
                                       textOf(tabOf(ID2)).indexOf('ls') < 0,
                                       textOf(tabOf(ID1)) + ' / ' + textOf(tabOf(ID2)));
                                    // AMBIENT MONITOR insight vs the agent's own text:
                                    // same tab, DIFFERENT roles, so the user can tell
                                    // them apart.
                                    window.handleAgentEvent(ID1, { kind: 'insight',
                                        text: 'MONITOR-SAYS' });
                                    window.handleAgentEvent(ID1, { kind: 'text',
                                        text: 'AGENT-SAYS' });
                                    setTimeout(function () {
                                        var roles1 = (tabOf(ID1).chat || []).map(
                                            function (m) { return m.role + '=' + m.text; });
                                        var roles2 = (tabOf(ID2).chat || []).map(
                                            function (m) { return m.role + '=' + m.text; });
                                        ok('…and the agent text is role text in the SAME tab',
                                           roles1.indexOf('text=AGENT-SAYS') >= 0,
                                           roles1.join('|'));
                                        ok('…neither leaks to the other tab',
                                           roles2.join('|').indexOf('MONITOR-SAYS') < 0 &&
                                           roles2.join('|').indexOf('AGENT-SAYS') < 0,
                                           roles2.join('|'));
                                        // MONITOR vs AGENT streams: separate
                                        // transcripts, separate rail tabs.
                                        window.handleAgentEvent(ID1, { kind: 'monitorThinking',
                                            text: 'MON-THINK' });
                                        window.handleAgentEvent(ID1, { kind: 'insight',
                                            text: 'MON-SAY' });
                                        setTimeout(function () {
                                            var t1 = tabOf(ID1), t2 = tabOf(ID2);
                                            var mon1 = (t1.monitor || []).map(function (m) {
                                                return m.role + '=' + m.text; }).join('|');
                                            var ag1 = (t1.chat || []).map(function (m) {
                                                return m.role + '=' + m.text; }).join('|');
                                            var mon2 = (t2.monitor || []).map(function (m) {
                                                return m.role + '=' + m.text; }).join('|');
                                            ok('the monitor keeps its OWN transcript',
                                               mon1.indexOf('thinking=MON-THINK') >= 0 &&
                                               mon1.indexOf('monitor=MON-SAY') >= 0, mon1);
                                            ok('…and those never enter the agent transcript',
                                               ag1.indexOf('MON-SAY') < 0 &&
                                               ag1.indexOf('MON-THINK') < 0, ag1);
                                            ok('…nor another tab', mon2.indexOf('MON-SAY') < 0, mon2);
                                            // Rail tabs switch the visible stream.
                                            var key1 = Object.keys(terminals).find(function (k) {
                                                return terminals[k].juliaId === ID1; });
                                            switchToTerminal(key1);
                                            selectChatStream('monitor');
                                            var log = document.getElementById('agentChatLog');
                                            var monShown = log.textContent;
                                            selectChatStream('agent');
                                            var agShown = document.getElementById('agentChatLog').textContent;
                                            ok('the Monitor rail tab shows the monitor stream',
                                               monShown.indexOf('MON-SAY') >= 0 &&
                                               monShown.indexOf('AGENT-SAYS') < 0,
                                               monShown.slice(0, 120));
                                            ok('the Agent rail tab shows the agent stream',
                                               agShown.indexOf('AGENT-SAYS') >= 0 &&
                                               agShown.indexOf('MON-SAY') < 0,
                                               agShown.slice(0, 120));
                                            done();
                                        }, 300);
                                    }, 300);
                                }, 300);
                            }, 300);
                        }, 300);
                    }, 300);
                }, 300);
            }, 800);
        });
        }
        try { body(); }
        catch (e) { ok('page error', false,
            String((e && e.message) ? e.message : e) + ' | ' +
            String((e && e.stack) ? e.stack : 'no stack')); done(); }
    })();
    """
    L.Webviews.eval!(wv, script)
    t0 = time()
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__iso__", ""), L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && time() - t0 < 30
            return Webviews.set_timeout(poll, wv, 0.25)
        end
        check("the scenario completed in the page", !isempty(txt), first(txt, 200))
        for m in eachmatch(Regex("\\{\"name\":\"((?:[^\"\\\\]|\\\\.)*)\",\"ok\":(true|false),\"detail\":\"((?:[^\"\\\\]|\\\\.)*)\"\\}"), txt)
            name = replace(m.captures[1], "\\\\\"" => "\"")
            detail = first(replace(m.captures[3], "\\\\\"" => "\""), 120)
            check(name, m.captures[2] == "true", detail)
        end
        L.closeSession!(s1); L.closeSession!(s2)
        finish()
    end
    Webviews.set_timeout(poll, wv, 0.5)
    return nothing
end

Webviews.set_timeout(run, wv, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 180.0)
L.runEventLoopAndTeardown!(wv)
