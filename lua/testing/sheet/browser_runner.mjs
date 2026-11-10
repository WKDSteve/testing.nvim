// The browser engine of a test sheet (testing.sheet.browser), with Playwright. Two ways in, one step function:
//   node browser_runner.mjs <plan.json>   the whole plan: prints one JSON line { failures, shots } and exits 0 (also on
//                                         failed steps); exit 77 = a prerequisite is missing. The suite's way.
//   node browser_runner.mjs --driver      one JSON line per command on stdin, one answer per line on stdout
//                                         (testing-sheet-driver/1): open, step, close. stdin at its end closes too.
import { mkdirSync, existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, isAbsolute } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

const SKIP = 77;
const DRIVER_SCHEMA = 'testing-sheet-driver/1';
const ACTIONS = ['open', 'press', 'click', 'hover', 'focus', 'blur', 'scheme', 'wait', 'expect', 'shot'];

function describe(step) {
  for (const a of ACTIONS) {
    if (step[a] !== undefined) {
      const what = `${a} ${String(step[a]).replace(/\s+/g, ' ').slice(0, 60)}`;
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

// Throws when the step fails; a `shot` answers with its file.
async function runStep(page, step, where) {
  if (step.open !== undefined) {
    await page.goto(target(step.open, where.root));
  } else if (step.press !== undefined) {
    await page.keyboard.press(step.press);
  } else if (step.click !== undefined) {
    await page.click(step.click, { timeout: 5000 });
  } else if (step.hover !== undefined) {
    // the pointer stays over the element: a later `shot` shows its :hover state (JS cannot trigger :hover)
    await page.hover(step.hover, { timeout: 5000 });
  } else if (step.focus !== undefined) {
    await page.focus(step.focus, { timeout: 5000 });
  } else if (step.blur !== undefined) {
    // the keyboard focus leaves whatever has it; a handler that gives it to another element is a failure of the step
    const holder = await page.evaluate(() => {
      document.activeElement?.blur();
      const now = document.activeElement;
      return !now || now === document.body || now === document.documentElement ? '' : now.outerHTML.slice(0, 80);
    });
    if (holder) throw new Error(`the focus is on ${holder}`);
  } else if (step.scheme !== undefined) {
    // prefers-color-scheme for the page from now on (light or dark), without reloading it
    await page.emulateMedia({ colorScheme: step.scheme });
  } else if (step.wait !== undefined) {
    await waitFor(page, step.wait, step.timeout ?? 2000);
  } else if (step.expect !== undefined) {
    const value = await page.evaluate(step.expect);
    if (!value) throw new Error(`got ${JSON.stringify(value)}`);
  } else if (step.shot !== undefined) {
    if (!existsSync(where.out_dir)) mkdirSync(where.out_dir, { recursive: true });
    const file = resolve(where.out_dir, `${where.id}.${step.shot}.${where.tag}.png`);
    // `element`: only that element (the grid of an rpc sheet's screen, `testing.sheet.shot`), else the viewport
    if (step.element !== undefined) {
      await page.locator(step.element).screenshot({ path: file, timeout: 5000 });
    } else {
      await page.screenshot({ path: file });
    }
    return file;
  }
  return undefined;
}

// Answers with the browser, or throws an Error whose message is the reason for the skip.
async function launch(playwrightDir, headless, channel) {
  let chromium;
  try {
    ({ chromium } = createRequire(resolve(playwrightDir, 'package.json'))('playwright-core'));
  } catch {
    throw new Error('playwright-core cannot be loaded');
  }
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
    browser = await launch(plan.playwright_dir, true, plan.channel);
  } catch (e) {
    console.log(`SKIP: ${e.message}`);
    process.exit(SKIP);
  }
  const failures = [];
  const shots = [];
  for (const size of plan.sizes) {
    const tag = `${size.cols}x${size.rows}`;
    const page = await browser.newPage({ viewport: { width: size.cols, height: size.rows } });
    const where = { root: plan.root, out_dir: plan.out_dir, id: plan.id, tag };
    let n = 0;
    for (const step of plan.steps) {
      n += 1;
      try {
        const shot = await runStep(page, step, where);
        if (shot) shots.push(`screenshot ${shot}`);
      } catch (e) {
        failures.push(`${tag} step ${n}, ${describe(step)}: ${String(e.message).split('\n')[0]}`);
        break;
      }
    }
    await page.close();
  }
  await browser.close();
  console.log(JSON.stringify({ failures, shots }));
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
          browser = await launch(cmd.options.playwright_dir, !cmd.options.headed, cmd.options.channel);
        } catch (e) {
          answer({ ok: false, skip: e.message });
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
        const shot = await runStep(page, cmd.step, where);
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
