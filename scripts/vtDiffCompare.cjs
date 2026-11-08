/* Companion to vtDiffProbe.jl — dumps xterm.js screens for the same corpus. */
const { Terminal } = require('@xterm/headless');
const fs = require('fs');
const path = require('path');
const here = __dirname;
const corpus = fs.readFileSync(path.join(here, 'vtDiffCorpus.txt'), 'utf8').split('\n').map(l => l.trim()).filter(Boolean);

function screen(hex) {
  return new Promise((resolve) => {
    const buf = Buffer.from(hex, 'hex');
    const term = new Terminal({ cols: 40, rows: 8, scrollback: 0, allowProposedApi: true });
    term.write(buf, () => {
      const b = term.buffer.active, rows = [];
      for (let y = 0; y < 8; y++) {
        const line = b.getLine(y);
        rows.push(line ? line.translateToString(true).replace(/\s+$/, '') : '');
      }
      term.dispose();
      resolve(rows.join('\n'));
    });
  });
}

(async () => {
  const out = [];
  for (const hex of corpus) {
    out.push('=== ' + hex);
    out.push(await screen(hex));
  }
  fs.writeFileSync(path.join(here, 'xterm.txt'), out.join('\n') + '\n');
  console.log('wrote xterm.txt');
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
