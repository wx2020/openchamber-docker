// Smoke test for the image's built-in terminal.
//
// The terminal runtime picks bun-pty on Bun >= 1.4 and falls back to node-pty
// below it. Under Bun that fallback spawns the shell and then SIGHUPs it within
// a few milliseconds, so an image pinned to an older Bun ships a terminal that
// opens and instantly closes (OpenChamber 2.5.x-2.7.0 did). `command -v` style
// checks cannot see this: the modules load and the spawn succeeds.
//
// Run inside the image:  bun /tmp/smoke-terminal.mjs
import process from 'node:process';

const serverDir = process.env.OPENCHAMBER_SERVER_DIR || '/home/openchamber/packages/web/server';
const BANNER = 'TERMINAL_SMOKE_OK';
const SURVIVAL_MS = 1500;
const OUTPUT_TIMEOUT_MS = 5000;

const fail = (message) => {
  console.error(`terminal smoke test failed: ${message}`);
  process.exit(1);
};

const { loadTerminalPtyProvider } = await import(`${serverDir}/lib/terminal/runtime.js`);
const { spawn, backend } = await loadTerminalPtyProvider();
console.log(`terminal backend: ${backend}`);
if (backend !== 'bun-pty') {
  fail(`expected the bun-pty backend, got ${backend} (Bun ${process.versions.bun} is below the 1.4 floor)`);
}

const pty = await spawn('/bin/bash', [], {
  name: 'xterm-256color',
  cwd: '/tmp',
  cols: 80,
  rows: 24,
  env: { ...process.env, TERM: 'xterm-256color', LANG: process.env.LANG || 'C.UTF-8' },
});

let output = '';
let exited = null;
pty.onData((data) => { output += data; });
pty.onExit((event) => { exited = event; });

// An interactive shell must stay alive: the node-pty fallback dies here.
const survived = await new Promise((resolve) => {
  const timer = setTimeout(() => resolve(true), SURVIVAL_MS);
  pty.onExit(() => { clearTimeout(timer); resolve(false); });
});
if (!survived) {
  fail(`the interactive shell exited immediately (${JSON.stringify(exited)})`);
}

// Prove the pty carries input and output in both directions.
pty.write(`echo ${BANNER}\n`);
const echoed = await new Promise((resolve) => {
  const started = Date.now();
  const timer = setInterval(() => {
    if (output.includes(BANNER)) { clearInterval(timer); resolve(true); }
    else if (Date.now() - started > OUTPUT_TIMEOUT_MS) { clearInterval(timer); resolve(false); }
  }, 100);
});
try { pty.kill(); } catch { /* already gone */ }
if (!echoed) fail('the shell never echoed a command typed into the pty');

console.log(`terminal ok: ${backend} keeps an interactive shell alive and round-trips input`);
