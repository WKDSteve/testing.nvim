// Runs the plan of a browser test sheet (testing.sheet.browser) with Playwright.
//   node browser_runner.mjs <plan.json>
// Prints one JSON line { failures, shots } and exits 0 (also on failed steps); exit 77 = a prerequisite is missing.
import { readFileSync, mkdirSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

const SKIP = 77;
const plan = JSON.parse(readFileSync(process.argv[2], 'utf8'));

let chromium;
try {
  ({ chromium } = createRequire(resolve(plan.playwright_dir, 'package.json'))('playwright-core'));
} catch {
  console.log('SKIP: playwright-core cannot be loaded');
  process.exit(SKIP);
}
let browser;
try {
  browser = await chromium.launch({ headless: true });
} catch (e) {
  console.log(`SKIP: chromium cannot be started (${String(e.message).split('\n')[0]}); npx playwright install chromium`);
  process.exit(SKIP);
}

const failures = [];
const shots = [];
const ACTIONS = ['open', 'press', 'click', 'wait', 'expect', 'shot'];

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
function target(value) {
  const isUrl = /^[a-z][a-z0-9+.-]*:/i.test(value) && !/^[a-z]:[\\/]/i.test(value);
  if (isUrl) return value;
  return pathToFileURL(isAbsolute(value) ? value : resolve(plan.root, value)).href;
}

for (const size of plan.sizes) {
  const tag = `${size.cols}x${size.rows}`;
  const page = await browser.newPage({ viewport: { width: size.cols, height: size.rows } });
  let n = 0;
  for (const step of plan.steps) {
    n += 1;
    try {
      if (step.open !== undefined) {
        await page.goto(target(step.open));
      } else if (step.press !== undefined) {
        await page.keyboard.press(step.press);
      } else if (step.click !== undefined) {
        await page.click(step.click, { timeout: 5000 });
      } else if (step.wait !== undefined) {
        await page.waitForFunction(step.wait, null, { timeout: step.timeout ?? 2000 });
      } else if (step.expect !== undefined) {
        const value = await page.evaluate(step.expect);
        if (!value) throw new Error(`got ${JSON.stringify(value)}`);
      } else if (step.shot !== undefined) {
        if (!existsSync(plan.out_dir)) mkdirSync(plan.out_dir, { recursive: true });
        const file = resolve(plan.out_dir, `${plan.id}.${step.shot}.${tag}.png`);
        await page.screenshot({ path: file });
        shots.push(`screenshot ${file}`);
      }
    } catch (e) {
      failures.push(`${tag} step ${n}, ${describe(step)}: ${String(e.message).split('\n')[0]}`);
      break;
    }
  }
  await page.close();
}
await browser.close();
console.log(JSON.stringify({ failures, shots }));
