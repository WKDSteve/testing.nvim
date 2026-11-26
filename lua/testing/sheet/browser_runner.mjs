// The browser engine of a test sheet (testing.sheet.browser), with Playwright. Two ways in, one step function:
//   node browser_runner.mjs <plan.json>   the whole plan: prints one JSON line { failures, shots, steps } and exits 0 (also on
//                                         failed steps); exit 77 = a prerequisite is missing. The suite's way.
//   node browser_runner.mjs --driver      one JSON line per command on stdin, one answer per line on stdout
//                                         (testing-sheet-driver/1): open, step, close. stdin at its end closes too.
import { mkdirSync, existsSync, readFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { resolve, isAbsolute, join } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

const SKIP = 77;
const DRIVER_SCHEMA = 'testing-sheet-driver/1';
const ACTIONS = ['open', 'press', 'click', 'hover', 'drag', 'focus', 'blur', 'frame', 'scheme', 'wait', 'expect', 'measure', 'shot'];
// The steps that do something to the page: a later `wait` is timed from the start of the last of them as well
// (`after_ms`, a click until the page shows what it did).
const ACTING = ['open', 'press', 'click', 'hover', 'drag', 'focus', 'blur', 'scheme'];

function describe(step) {
  for (const a of ACTIONS) {
    if (step[a] !== undefined) {
      // a `drag` is { from, to }: both are named (as testing.sheet.value_text does)
      const value = a === 'drag' ? `${step.drag.from} -> ${step.drag.to}` : String(step[a]);
      const what = `${a} ${value.replace(/\s+/g, ' ').slice(0, 60)}`;
      return step.note ? `${step.note} (${what})` : what;
    }
  }
  return '?';
}

// A URL keeps its scheme; anything else is a file, relative to the project root.
function target(value, root) {
  const isUrl = /^[a-z][a-z0-9+.-]*:/i.test(value) && !/^[a-z]:[\\/]/i.test(value);
  if (isUrl) return value;
  return pathToFileURL(isAbsolute(value) ? value : resolve(root, value)).href;
}

// Polls with `evaluate`, not `waitForFunction`: that one evaluates a string with `eval` inside the page, which the
// Content-Security-Policy of a good page refuses. A navigation in between is no failure, the next poll asks the new page.
async function waitFor(page, expression, timeout) {
  const deadline = Date.now() + timeout;
  for (;;) {
    try {
      if (await page.evaluate(expression)) return;
    } catch (e) {
      if (!/context was destroyed|Cannot find context|navigat/i.test(String(e.message))) throw e;
    }
    if (Date.now() >= deadline) throw new Error(`Timeout ${timeout}ms exceeded.`);
    await new Promise((done) => setTimeout(done, 50));
  }
}

// The median of numbers (the mean of the middle two of an even count), as testing.sheet.median.
function median(values) {
  const v = values.toSorted((a, b) => a - b);
  const mid = Math.floor(v.length / 2);
  return v.length % 2 === 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2;
}

// Milliseconds to a tenth: finer is noise of the clock and the event loop.
const tenth = (ms) => Math.round(ms * 10) / 10;

// Throws when the step fails; a `shot` answers { shot: file }, a `measure` { values } (testing.sheet.measure_of judges
// them). `where.frame`, once a `frame` step chose one, is the
// iframe the element and script steps act in (a Playwright Frame answers as a page does); keys and pictures stay with
// the page.
async function runStep(page, step, where) {
  const scope = where.frame ?? page;
  if (step.open !== undefined) {
    where.frame = undefined;
    await page.goto(target(step.open, where.root), step.timeout ? { timeout: step.timeout } : {});
  } else if (step.frame !== undefined) {
    if (step.frame === false) {
      where.frame = undefined;
    } else {
      // in the frame the steps act in now: a frame inside a frame is two steps
      const element = await scope.waitForSelector(step.frame, { timeout: 5000 });
      const frame = await element.contentFrame();
      if (!frame) throw new Error(`${step.frame} is no iframe`);
      where.frame = frame;
    }
  } else if (step.press !== undefined) {
    await page.keyboard.press(step.press);
  } else if (step.click !== undefined) {
    await scope.click(step.click, { timeout: 5000 });
  } else if (step.hover !== undefined) {
    // the pointer stays over the element: a later `shot` shows its :hover state (JS cannot trigger :hover)
    await scope.hover(step.hover, { timeout: 5000 });
  } else if (step.drag !== undefined) {
    // pointer down on `from`, moved onto `to`, released there: HTML5 drag and drop and pointer handlers both see it
    await scope.dragAndDrop(step.drag.from, step.drag.to, { timeout: 5000 });
  } else if (step.focus !== undefined) {
    await scope.focus(step.focus, { timeout: 5000 });
  } else if (step.blur !== undefined) {
    // the keyboard focus leaves whatever has it; a handler that gives it to another element is a failure of the step
    const holder = await scope.evaluate(() => {
      document.activeElement?.blur();
      const now = document.activeElement;
      return !now || now === document.body || now === document.documentElement ? '' : now.outerHTML.slice(0, 80);
    });
    if (holder) throw new Error(`the focus is on ${holder}`);
  } else if (step.scheme !== undefined) {
    // prefers-color-scheme for the page from now on (light or dark), without reloading it
    await page.emulateMedia({ colorScheme: step.scheme });
  } else if (step.wait !== undefined) {
    await waitFor(scope, step.wait, step.timeout ?? 2000);
  } else if (step.expect !== undefined) {
    const value = await scope.evaluate(step.expect);
    if (!value) throw new Error(`got ${JSON.stringify(value)}`);
  } else if (step.measure !== undefined) {
    // `runs` readings in the page (an async expression is awaited), the median counts
    const values = [];
    for (let i = 0; i < (step.runs ?? 1); i += 1) {
      const v = await scope.evaluate(step.measure);
      if (typeof v !== 'number' || !Number.isFinite(v)) {
        throw new Error(`${step.name}: got ${JSON.stringify(v) ?? 'undefined'}, not a number`);
      }
      values.push(v);
    }
    return { values };
  } else if (step.shot !== undefined) {
    if (!existsSync(where.out_dir)) mkdirSync(where.out_dir, { recursive: true });
    const file = resolve(where.out_dir, `${where.id}.${step.shot}.${where.tag}.png`);
    // `element`: only that element (the grid of an rpc sheet's screen, `testing.sheet.shot`), else the viewport
    if (step.element !== undefined) {
      await scope.locator(step.element).screenshot({ path: file, timeout: step.timeout ?? 5000 });
    } else {
      await page.screenshot({ path: file });
    }
    return { shot: file };
  }
  return {};
}

// A step with its duration, measured here next to the page (not in the process that asked for it): `ms` the step
// itself; a `wait` also `after_ms`, from the start of the last acting step (`after_n`) to the moment its condition held.
// A `measure` whose median broke `min` / `max` answers `broke`: the size ends there, as after any failed step.
async function timedStep(page, step, where, n) {
  const started = performance.now();
  if (ACTING.some((a) => step[a] !== undefined)) where.acted = { at: started, n };
  const out = await runStep(page, step, where);
  const ended = performance.now();
  out.ms = tenth(ended - started);
  if (step.wait !== undefined && where.acted) {
    out.after_ms = tenth(ended - where.acted.at);
    out.after_n = where.acted.n;
  }
  if (out.values) {
    const m = median(out.values);
    out.broke = (step.max !== undefined && m > step.max) || (step.min !== undefined && m < step.min);
  }
  return out;
}

// An unpacked extension needs a persistent context (a profile of its own, thrown away at the end): `launch` cannot
// load one. It answers like a browser (`newPage({ viewport })`, `close()`), so the steps do not know the difference.
// Headless works with the full Chromium (`channel: 'chromium'`, the new headless mode), not with the headless shell.
// On Windows a closing Chromium can hold files of its profile for a moment: removing it is tidying up, never a reason to
// lose the result of the run (a throw here would end the runner after the steps).
function dropProfile(profile) {
  try {
    rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  } catch {
    // left in the temp folder
  }
}

// The id Chromium gives an unpacked extension with a `key` in its manifest: the first 128 bits of the SHA-256 of the
// public key, each hex digit written as a letter a..p.
function extensionId(extension) {
  const manifest = JSON.parse(readFileSync(join(extension, 'manifest.json'), 'utf8'));
  if (typeof manifest.key !== 'string' || manifest.key === '') {
    throw new Error('native_host needs a "key" in the manifest.json of the extension (a fixed extension id)');
  }
  const hex = createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32);
  return [...hex].map((c) => String.fromCharCode(97 + Number.parseInt(c, 16))).join('');
}

// Where Playwright's Chromium looks for a host of the user on Windows, before Software\Google\Chrome (measured).
const CHROMIUM_HOSTS = 'HKCU\\Software\\Chromium\\NativeMessagingHosts';

// Registers the sheet's native messaging host for this run (testing.sheet.native_host prepared it and removes what is
// left afterwards). Answers the function that takes it away again.
function registerHost(host, extension, profile) {
  if (host.env_error) throw new Error(host.env_error);
  const manifest = JSON.stringify({
    name: host.name,
    description: 'native messaging host of a testing.nvim sheet run',
    path: host.path,
    type: 'stdio',
    allowed_origins: [`chrome-extension://${extensionId(extension)}/`],
  });
  if (process.platform !== 'win32') {
    // Linux and macOS read the hosts of a profile from its folder: nothing outside the run's profile changes
    const dir = join(profile, 'NativeMessagingHosts');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${host.name}.json`), manifest);
    return () => {};
  }
  const file = join(host.dir, `${host.name}.json`);
  writeFileSync(file, manifest);
  const key = `${CHROMIUM_HOSTS}\\${host.name}`;
  // the Lua side checked this before the run; a key that came since is somebody else's
  if (spawnSync('reg', ['query', key]).status === 0) {
    throw new Error(`a native messaging host ${host.name} is registered for Chromium already (${key})`);
  }
  const add = spawnSync('reg', ['add', key, '/ve', '/t', 'REG_SZ', '/d', file, '/f'], { encoding: 'utf8' });
  if (add.status !== 0) {
    throw new Error(`the native messaging host cannot be registered: ${String(add.stderr).trim()}`);
  }
  return () => {
    spawnSync('reg', ['delete', key, '/f']);
  };
}

async function launchWithExtension(chromium, headless, channel, extension, nativeHost) {
  if (!existsSync(join(extension, 'manifest.json'))) {
    throw new Error(`the extension ${extension} has no manifest.json`);
  }
  const profile = mkdtempSync(join(tmpdir(), 'testing-sheet-profile-'));
  let context;
  let unregister = () => {};
  if (nativeHost) {
    // what goes wrong with the sheet's host (no key in the extension, a foreign key, an env that cannot be filled in)
    // is the sheet's fault: a red run, never a skip that hides it
    try {
      unregister = registerHost(nativeHost, extension, profile);
    } catch (e) {
      dropProfile(profile);
      e.sheetFailure = true;
      throw e;
    }
  }
  try {
    context = await chromium.launchPersistentContext(profile, {
      headless,
      channel: channel || 'chromium',
      args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
      // Chromium hands its environment to the host it starts: the sheet's `native_host.env` reaches the host this way
      ...(nativeHost && nativeHost.env ? { env: { ...process.env, ...nativeHost.env } } : {}),
    });
  } catch (e) {
    unregister();
    dropProfile(profile);
    throw new Error(`chromium with the extension cannot be started (${String(e.message).split('\n')[0]})`);
  }
  return {
    newPage: async (opts = {}) => {
      const page = await context.newPage();
      if (opts.viewport) await page.setViewportSize(opts.viewport);
      return page;
    },
    close: async () => {
      await context.close().catch(() => {});
      unregister();
      dropProfile(profile);
    },
  };
}

// Answers with the browser, or throws an Error whose message is the reason for the skip.
async function launch(playwrightDir, headless, channel, extension, nativeHost) {
  let chromium;
  try {
    ({ chromium } = createRequire(resolve(playwrightDir, 'package.json'))('playwright-core'));
  } catch {
    throw new Error('playwright-core cannot be loaded');
  }
  if (extension) return launchWithExtension(chromium, headless, channel, extension, nativeHost);
  // the project asked for this browser (sheets.browser of .testing.lua): nothing else proves what it wants proved
  if (channel) {
    try {
      return await chromium.launch({ headless, channel });
    } catch (e) {
      throw new Error(`${channel} cannot be started (${String(e.message).split('\n')[0]})`);
    }
  }
  try {
    return await chromium.launch({ headless });
  } catch (e) {
    // a visible window is for looking, any Chromium will do: Playwright's own full build is a separate install from the
    // headless shell the suite uses, and it can be missing or broken while that one works
    if (!headless) {
      for (const channel of ['chrome', 'msedge']) {
        try {
          return await chromium.launch({ headless, channel });
        } catch {
          // the next one; the message below names the first failure
        }
      }
    }
    throw new Error(`chromium cannot be started (${String(e.message).split('\n')[0]}); npx playwright install chromium`);
  }
}

async function wholePlan(planPath) {
  const plan = JSON.parse(readFileSync(planPath, 'utf8'));
  let browser;
  try {
    browser = await launch(plan.playwright_dir, true, plan.channel, plan.extension, plan.native_host);
  } catch (e) {
    if (e.sheetFailure) {
      console.log(JSON.stringify({ failures: [String(e.message).split('\n')[0]], shots: [] }));
      return;
    }
    console.log(`SKIP: ${e.message}`);
    process.exit(SKIP);
  }
  const failures = [];
  const shots = [];
  // per step that ran: { size, n, ms, after_ms?, after_n?, values? }; a failed step has none
  const steps = [];
  for (const size of plan.sizes) {
    const tag = `${size.cols}x${size.rows}`;
    const page = await browser.newPage({ viewport: { width: size.cols, height: size.rows } });
    const where = { root: plan.root, out_dir: plan.out_dir, id: plan.id, tag };
    let n = 0;
    for (const step of plan.steps) {
      n += 1;
      let out;
      try {
        out = await timedStep(page, step, where, n);
      } catch (e) {
        failures.push(`${tag} step ${n}, ${describe(step)}: ${String(e.message).split('\n')[0]}`);
        break;
      }
      const { shot, broke, ...timing } = out;
      if (shot) shots.push(`screenshot ${shot}`);
      steps.push({ size: tag, n, ...timing });
      // the failure line of a broken bound is written by testing.sheet.browser (testing.sheet.measure_of)
      if (broke) break;
    }
    await page.close();
  }
  await browser.close();
  console.log(JSON.stringify({ failures, shots, steps }));
}

function driver() {
  let browser;
  let page;
  let where;
  let stopping = false;
  const answer = (o) => process.stdout.write(`${JSON.stringify({ schema: DRIVER_SCHEMA, ...o })}\n`);
  const closePage = async () => {
    if (page) await page.close().catch(() => {});
    page = undefined;
  };
  // A browser that does not close in time must not keep this process: whoever started it kills it then.
  const shutdown = async () => {
    stopping = true;
    await closePage();
    const closing = browser;
    browser = undefined;
    if (closing) {
      await Promise.race([closing.close().catch(() => {}), new Promise((done) => setTimeout(done, 4000))]);
    }
  };
  // a pipe's write is asynchronous on Windows: the last answer has to be out before the exit
  const leave = () => process.stdout.write('', () => process.exit(0));

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
      await closePage();
      if (!browser) {
        try {
          browser = await launch(
            cmd.options.playwright_dir,
            !cmd.options.headed,
            cmd.options.channel,
            cmd.options.extension,
            cmd.options.native_host,
          );
        } catch (e) {
          answer(e.sheetFailure ? { ok: false, error: e.message } : { ok: false, skip: e.message });
          return;
        }
        // stdin ended while the browser was starting
        if (stopping) {
          await shutdown();
          return;
        }
      }
      const { cols, rows } = cmd.size;
      page = await browser.newPage({ viewport: { width: cols, height: rows } });
      where = { root: cmd.sheet.root, out_dir: cmd.sheet.out_dir, id: cmd.sheet.id, tag: `${cols}x${rows}` };
      answer({ ok: true });
    } else if (cmd.cmd === 'step') {
      if (!page) {
        answer({ ok: false, error: 'step before open' });
        return;
      }
      try {
        // a broken bound is judged by testing.sheet.measure_of on the other side, from `values`
        const { broke, ...out } = await timedStep(page, cmd.step, where, cmd.n);
        answer({ ok: true, ...out });
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

  // Commands in order, each finished before the next. The end of stdin does not wait for its turn: it is how a run is
  // aborted (or its owner died), also in the middle of a step, and a browser must not outlive it.
  const lines = createInterface({ input: process.stdin });
  let queue = Promise.resolve();
  lines.on('line', (line) => {
    queue = queue.then(() => handle(line)).catch((e) => answer({ ok: false, error: String(e.message).split('\n')[0] }));
  });
  lines.on('close', () => {
    shutdown().finally(leave);
  });
}

if (process.argv[2] === '--driver') {
  driver();
} else {
  await wholePlan(process.argv[2]);
}
