// The webview engine of a test sheet (testing.sheet.webview): the page inside the WebView2 of an app, through
// tauri-driver and msedgedriver. Plain W3C WebDriver over HTTP, no client library.
//   node webview_runner.mjs   one JSON line per command on stdin, one answer per line on stdout
//                             (testing-sheet-driver/1): open, step, close. stdin at its end closes too.
// `open` starts tauri-driver (options.tauri_driver, --native-driver options.msedgedriver) with the app's environment
// and a WebDriver session for options.application; tauri-driver starts the app. A second `open` (the next size) only
// sizes the window. `close` ends the session, then the whole tree of tauri-driver.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

const DRIVER_SCHEMA = 'testing-sheet-driver/1';
const ELEMENT = 'element-6066-11e4-a52e-4f735466cecf';
const FIND_MS = 5000;

// The names of `press` (as Playwright writes them) as WebDriver key points; anything else is one character.
const KEY_POINTS = {
  Backspace: 0xe003,
  Tab: 0xe004,
  Enter: 0xe007,
  Shift: 0xe008,
  Control: 0xe009,
  Alt: 0xe00a,
  Escape: 0xe00c,
  PageUp: 0xe00e,
  PageDown: 0xe00f,
  End: 0xe010,
  Home: 0xe011,
  ArrowLeft: 0xe012,
  ArrowUp: 0xe013,
  ArrowRight: 0xe014,
  ArrowDown: 0xe015,
  Delete: 0xe017,
  Meta: 0xe03d,
};

// `Control+Shift+k`: the keys down in order, up in reverse. A name that is neither known nor one character is refused.
export function keyActions(press) {
  const parts = press === '+' ? ['+'] : press.split('+');
  const keys = parts.map((part) => {
    if (KEY_POINTS[part] !== undefined) return String.fromCharCode(KEY_POINTS[part]);
    if (part === 'Space') return ' ';
    if ([...part].length === 1) return part;
    throw new Error(`press: unknown key ${JSON.stringify(part)}`);
  });
  return [
    ...keys.map((value) => ({ type: 'keyDown', value })),
    ...keys.reverse().map((value) => ({ type: 'keyUp', value })),
  ];
}

// The whole tree: tauri-driver starts msedgedriver, which starts the app; killing only the first leaves the others.
function killTree(proc) {
  if (!proc || proc.exitCode !== null) return;
  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/PID', String(proc.pid), '/T', '/F'], { stdio: 'ignore' });
  } else {
    try {
      process.kill(-proc.pid, 'SIGKILL');
    } catch {
      proc.kill('SIGKILL');
    }
  }
}

function driver() {
  let tauri; // the tauri-driver process
  let base; // http://127.0.0.1:<port>/session/<id>
  let server; // http://127.0.0.1:<port>
  let where;
  let stopping = false;
  const answer = (o) => process.stdout.write(`${JSON.stringify({ schema: DRIVER_SCHEMA, ...o })}\n`);

  const call = async (method, url, body, ms = 30000) => {
    const r = await fetch(url, {
      method,
      signal: AbortSignal.timeout(ms),
      headers: { 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      const v = j.value ?? {};
      throw new Error(`${v.error ?? r.status}: ${String(v.message ?? '').split('\n')[0]}`);
    }
    return j.value;
  };
  const session = (method, path, body, ms) => call(method, base + path, body, ms);
  const script = (code, args = []) => session('POST', '/execute/sync', { script: code, args });

  // the one element a selector names, waited for as Playwright does
  const element = async (selector) => {
    const deadline = Date.now() + FIND_MS;
    for (;;) {
      try {
        const found = await session('POST', '/element', { using: 'css selector', value: selector });
        const id = found?.[ELEMENT] ?? found?.ELEMENT;
        if (typeof id !== 'string') throw new Error(`the driver named no element: ${JSON.stringify(found)}`);
        return encodeURIComponent(id);
      } catch (e) {
        if (Date.now() >= deadline) throw new Error(`no element ${selector} in ${FIND_MS} ms (${e.message})`);
      }
      await new Promise((done) => setTimeout(done, 100));
    }
  };
  const ref = (id) => ({ [ELEMENT]: id });
  // an expression of the sheet, as the body of a function: no eval, which the page's CSP may refuse
  const evaluate = (expression) => script(`return (\n${expression}\n);`);

  const start = async (options) => {
    const port = 4500 + Math.floor(Math.random() * 1000);
    server = `http://127.0.0.1:${port}`;
    // a list is a program with its first arguments (a spec's stand-in for tauri-driver)
    const [exe, ...first] = Array.isArray(options.tauri_driver) ? options.tauri_driver : [options.tauri_driver];
    tauri = spawn(exe, [...first, '--port', String(port), '--native-driver', options.msedgedriver], {
      cwd: options.cwd,
      env: { ...process.env, ...(options.env ?? {}) },
      stdio: 'ignore',
      detached: process.platform !== 'win32',
    });
    let failed;
    tauri.on('error', (e) => {
      failed = e;
    });
    for (let i = 0; i < 100 && !failed; i++) {
      try {
        if ((await fetch(`${server}/status`, { signal: AbortSignal.timeout(1000) })).ok) break;
      } catch {
        // not up yet
      }
      await new Promise((done) => setTimeout(done, 100));
    }
    if (failed) throw new Error(`tauri-driver did not start: ${failed.message}`);
    const created = await call(
      'POST',
      `${server}/session`,
      {
        capabilities: {
          alwaysMatch: { 'tauri:options': { application: options.application, args: options.args ?? [] } },
        },
      },
      60000,
    );
    base = `${server}/session/${created.sessionId}`;
  };

  const shutdown = async () => {
    stopping = true;
    if (base) await call('DELETE', base, undefined, 5000).catch(() => {});
    base = undefined;
    killTree(tauri);
    tauri = undefined;
  };
  const leave = () => process.stdout.write('', () => process.exit(0));

  // Throws when the step fails; a `shot` answers with its file.
  const runStep = async (step) => {
    if (step.press !== undefined) {
      await session('POST', '/actions', { actions: [{ type: 'key', id: 'keyboard', actions: keyActions(step.press) }] });
      await session('DELETE', '/actions');
    } else if (step.click !== undefined) {
      await session('POST', `/element/${await element(step.click)}/click`, {});
    } else if (step.hover !== undefined) {
      // the pointer stays over the element: a later `shot` shows its :hover state
      const id = await element(step.hover);
      await session('POST', '/actions', {
        actions: [
          {
            type: 'pointer',
            id: 'mouse',
            parameters: { pointerType: 'mouse' },
            actions: [{ type: 'pointerMove', duration: 0, origin: ref(id), x: 0, y: 0 }],
          },
        ],
      });
    } else if (step.focus !== undefined) {
      const id = await element(step.focus);
      await script('arguments[0].focus();', [ref(id)]);
    } else if (step.blur !== undefined) {
      const holder = await script(`
        document.activeElement && document.activeElement.blur();
        const now = document.activeElement;
        return !now || now === document.body || now === document.documentElement ? '' : now.outerHTML.slice(0, 80);`);
      if (holder) throw new Error(`the focus is on ${holder}`);
    } else if (step.wait !== undefined) {
      const timeout = step.timeout ?? 2000;
      const deadline = Date.now() + timeout;
      let last;
      for (;;) {
        // the app's page may still be loading (an element is not there yet), or reload in between: an error is no
        // failure of a wait, the next poll asks again; the last one is named at the deadline
        const value = await evaluate(step.wait).catch((e) => {
          last = e.message;
          return false;
        });
        if (value) break;
        if (Date.now() >= deadline) throw new Error(`Timeout ${timeout}ms exceeded.${last ? ` Last error: ${last}` : ''}`);
        await new Promise((done) => setTimeout(done, 50));
      }
    } else if (step.expect !== undefined) {
      const value = await evaluate(step.expect);
      if (!value) throw new Error(`got ${JSON.stringify(value)}`);
    } else if (step.shot !== undefined) {
      if (!existsSync(where.out_dir)) mkdirSync(where.out_dir, { recursive: true });
      const file = resolve(where.out_dir, `${where.id}.${step.shot}.${where.tag}.png`);
      writeFileSync(file, Buffer.from(await session('GET', '/screenshot'), 'base64'));
      return file;
    } else {
      throw new Error('this driver does not know the step');
    }
    return undefined;
  };

  const handle = async (line) => {
    if (line.trim() === '' || stopping) return;
    let cmd;
    try {
      cmd = JSON.parse(line);
    } catch (e) {
      answer({ ok: false, error: `not JSON: ${e.message}` });
      return;
    }
    if (cmd.cmd === 'open') {
      const options = cmd.options ?? {};
      if (!options.application) {
        answer({ ok: false, error: 'open names no app (options.application)' });
        return;
      }
      try {
        if (!base) await start(options);
        if (stopping) {
          await shutdown();
          return;
        }
        const { cols, rows } = cmd.size;
        await session('POST', '/window/rect', { width: cols, height: rows });
        where = { out_dir: cmd.sheet.out_dir, id: cmd.sheet.id, tag: `${cols}x${rows}` };
        answer({ ok: true });
      } catch (e) {
        answer({ ok: false, error: String(e.message).split('\n')[0] });
      }
    } else if (cmd.cmd === 'step') {
      if (!base || !where) {
        answer({ ok: false, error: 'step before open' });
        return;
      }
      try {
        const shot = await runStep(cmd.step);
        answer(shot ? { ok: true, shot } : { ok: true });
      } catch (e) {
        answer({ ok: false, reason: String(e.message).split('\n')[0] });
      }
    } else if (cmd.cmd === 'close') {
      await shutdown();
      answer({ ok: true });
      leave();
    } else {
      answer({ ok: false, error: `unknown command ${cmd.cmd}` });
    }
  };

  // Commands in order, each finished before the next. The end of stdin aborts at once: the app must not outlive it.
  const lines = createInterface({ input: process.stdin });
  let queue = Promise.resolve();
  lines.on('line', (line) => {
    queue = queue.then(() => handle(line)).catch((e) => answer({ ok: false, error: String(e.message).split('\n')[0] }));
  });
  lines.on('close', () => {
    shutdown().finally(leave);
  });
}

// imported by a spec for `keyActions`: no driver then
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) driver();
