-- TESTS/testing/sheet_webview_spec.lua -- the "webview" engine of test sheets (testing.sheet.webview): the shape of its
-- steps, the skip without node, tauri-driver or msedgedriver, and the whole way down where node exists: the sheet,
-- webview_runner.mjs and the WebDriver requests it sends, against a stand-in for tauri-driver that records them. The
-- app is built and filled in here but started by the driver (tauri-driver starts it), never by the sheet. A real
-- WebView2 app is docmap-desktop's sheet, by hand: not on every machine.
-- @cache-allow time processes
-- @cache-env TESTING_NODE TESTING_TAURI_DRIVER TESTING_MSEDGEDRIVER
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local webview = require("testing.sheet.webview")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-webview"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")
  local function write(rel, text)
    local p = root .. "/" .. rel
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end

  -- 1. the shape -------------------------------------------------------------------------------------------------------
  do
    local s = assert(sheet.validate({
      id = "w.x",
      title = "T",
      engine = "webview",
      app = "window",
      steps = {
        { wait = "document.title !== ''", timeout = 100 },
        { press = "Control+k" },
        { click = "#a" },
        { hover = "#a" },
        { focus = "#a" },
        { blur = true },
        { expect = "true" },
        { shot = "panel" },
        { ask = "Does it look right?" },
      },
    }))
    eq(s.sizes, { { rows = 700, cols = 1000 } }, "its default size is a window in pixels")
    for _, c in ipairs({
      { { open = "x" }, "open is not a step of a webview sheet" },
      { { scheme = "dark" }, "scheme is not a step of a webview sheet" },
      { { drag = { from = "#a", to = "#b" } }, "drag is not a step of a webview sheet" },
      { { keys = "x" }, "keys is not a step of a webview sheet" },
      { { toggle = "x" }, "toggle is not a step of a webview sheet" },
    }) do
      local none, why = sheet.validate({
        id = "x",
        title = "T",
        engine = "webview",
        app = "a",
        steps = { c[1] },
      })
      ok(none == nil, "refused: " .. vim.inspect(c[1]))
      has(why, c[2], "... says so")
    end
    local _, no_app =
      sheet.validate({ id = "x", title = "T", engine = "webview", steps = { { expect = "1" } } })
    has(no_app, "a webview sheet names its app", "a webview sheet needs an app")
    local _, unknown = sheet.validate({ id = "x", title = "T", engine = "web", steps = {} })
    has(unknown, "rpc, browser, desktop, webview or manual", "the engines are named")
  end

  -- 2. what is missing is a skip ----------------------------------------------------------------------------------------
  do
    local function rows(names)
      local out = {}
      for _, n in ipairs({ "node", "tauri-driver", "msedgedriver" }) do
        out[#out + 1] = { name = n, path = names[n] }
      end
      return out
    end
    local none, why = webview.prerequisites(rows({ node = "n", ["tauri-driver"] = "t" }))
    if require("testing.platform").is_macos() then
      has(why, "macOS", "macOS has no WebDriver of Tauri")
    else
      ok(none == nil, "without msedgedriver nothing runs")
      has(why, "msedgedriver is not installed", "... and the skip says what is missing")
      local found =
        webview.prerequisites(rows({ node = "n", ["tauri-driver"] = "t", msedgedriver = "m" }))
      eq(found, { node = "n", tauri_driver = "t", msedgedriver = "m" }, "all three: found")
    end
    local s = assert(sheet.validate({
      id = "w.skip",
      title = "T",
      engine = "webview",
      app = "window",
      steps = { { expect = "true" } },
    }))
    local res = sheet.run(s, { root = root, tools = rows({}) })
    eq(res.status, "skip", "a sheet without its tools is a reported skip, never green")
  end

  -- 3. the whole way down, against a stand-in for tauri-driver ---------------------------------------------------------
  local node
  for _, row in ipairs(require("testing.tier3").tools()) do
    if row.name == "node" then
      node = row.path
    end
  end
  if not node or require("testing.platform").is_macos() then
    print("n/a  node is not installed (or macOS): the runner is not run")
    return
  end

  local log = root .. "/wd.log"
  local fake = write(
    "fake_tauri_driver.mjs",
    [[
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';
const port = Number(process.argv[process.argv.indexOf('--port') + 1]);
const native = process.argv[process.argv.indexOf('--native-driver') + 1];
const log = (o) => appendFileSync(process.env.FAKE_WD_LOG, JSON.stringify(o) + '\n');
const nativePort = Number(process.argv[process.argv.indexOf('--native-port') + 1]);
// the trees started before this one that still run now: an earlier try must be gone before the next one starts
const alive = [];
try {
  for (const line of readFileSync(process.env.FAKE_WD_LOG, 'utf8').split('\n').filter(Boolean)) {
    const doc = JSON.parse(line);
    if (doc.started) {
      try {
        process.kill(doc.pid, 0);
        alive.push(doc.pid);
      } catch {
        // gone
      }
    }
  }
} catch {
  // no log yet
}
log({
  started: true,
  pid: process.pid,
  port,
  native,
  nativePort,
  alive,
  cwd: process.cwd().replace(/\\/g, '/'),
  probe: process.env.SHEET_PROBE ?? null,
});
if (process.env.FAKE_EXIT) process.exit(3);
const E = 'element-6066-11e4-a52e-4f735466cecf';
createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const json = body ? JSON.parse(body) : undefined;
    const path = req.url;
    if (path !== '/status') log({ method: req.method, path, body: json ?? null });
    const send = (code, value) => {
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ value }));
    };
    if (path === '/status') return send(200, { ready: true });
    if (path === '/session') {
      // the session cannot be made (msedgedriver conflict, the app crashed): the process stays up, as tauri-driver does
      if (process.env.FAKE_SESSION_FAIL) return send(500, { error: 'session not created', message: 'conflict' });
      return send(200, { sessionId: 's1', capabilities: {} });
    }
    if (path.endsWith('/element')) {
      if (json.value === '#missing') return send(404, { error: 'no such element', message: 'none' });
      return send(200, { [E]: 'e1' });
    }
    if (path.endsWith('/execute/sync')) {
      if (json.script.includes('THROWS')) return send(500, { error: 'javascript error', message: 'boom' });
      return send(200, json.script.includes('activeElement') ? '' : !json.script.includes('FALSY'));
    }
    if (path.endsWith('/screenshot')) return send(200, Buffer.from('png').toString('base64'));
    send(200, null);
    if (req.method === 'DELETE' && path === '/session/s1') setTimeout(() => process.exit(0), 50);
  });
}).listen(port, '127.0.0.1');
]]
  )
  write(
    ".testing.lua",
    "return { sheets = { apps = { window = { run = { 'app.exe', '--demo', '${temp}' }, "
      .. "env = { SHEET_PROBE = 'probe-${temp}', FAKE_WD_LOG = '"
      .. log
      .. "' } }, failing = { run = { 'app.exe' }, env = { FAKE_SESSION_FAIL = '1', FAKE_WD_LOG = '"
      .. log
      .. "' } }, exits = { run = { 'app.exe' }, env = { FAKE_EXIT = '1', FAKE_WD_LOG = '"
      .. log
      .. "' } } } } }\n"
  )
  local s = assert(sheet.validate({
    id = "w.run",
    title = "T",
    engine = "webview",
    app = "window",
    sizes = { { cols = 900, rows = 600 } },
    steps = {
      { wait = "document.title !== ''", timeout = 2000 },
      { press = "Control+k" },
      { click = "#a" },
      { hover = "#a" },
      { focus = "#a" },
      { blur = true },
      { shot = "panel" },
      { expect = "FALSY", note = "fails" },
      { click = "#never" },
    },
  }))
  local res = sheet.run(s, {
    root = root,
    out_dir = root .. "/out",
    tools = {
      { name = "node", path = node },
      { name = "tauri-driver", path = "unused" },
      { name = "msedgedriver", path = "msedge-fake" },
    },
    tauri_driver_argv = { node, fake },
    driver_margin_ms = 20000,
    driver_stop_ms = 4000,
  })
  eq(res.status, "fail", "sheet.run of a webview sheet goes through the runner")
  eq(
    res.failures,
    { "900x600 step 8, fails (expect FALSY): got false" },
    "the line of the failed step"
  )
  eq(
    vim.tbl_map(vim.fs.normalize, res.snapshots),
    { "screenshot " .. root .. "/out/w.run.panel.900x600.png" },
    "the picture"
  )
  local f = io.open(root .. "/out/w.run.panel.900x600.png", "rb")
  eq(f and f:read("*a"), "png", "... decoded from the driver's base64")
  if f then
    f:close()
  end

  local calls = {}
  for _, line in ipairs(vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}) do
    calls[#calls + 1] = vim.json.decode(line)
  end
  local start = calls[1] or {}
  ok(start.started, "the stand-in for tauri-driver was started")
  eq(start.native, "msedge-fake", "... with msedgedriver as its native driver")
  eq(start.cwd, root, "... in the project root")
  ok(
    type(start.probe) == "string"
      and start.probe:find("^probe%-") ~= nil
      and not start.probe:find("${", 1, true),
    "... with the app's env, filled in (" .. tostring(start.probe) .. ")"
  )
  local session = calls[2] or {}
  eq(session.path, "/session", "then a session")
  local tauri = session.body and session.body.capabilities.alwaysMatch["tauri:options"] or {}
  eq(
    vim.fs.basename(tostring(tauri.application)),
    "app.exe",
    "... for the app, resolved in the root"
  )
  eq(tauri.args and tauri.args[1], "--demo", "... with its arguments")
  ok(
    tauri.args and tauri.args[2] and not tauri.args[2]:find("${", 1, true),
    "... filled in (${temp} is a folder of the run)"
  )
  eq(calls[3] and calls[3].path, "/session/s1/window/rect", "the window gets the size")
  eq(calls[3] and calls[3].body, { width = 900, height = 600 }, "... in pixels")

  local paths = {}
  for i = 4, #calls do
    paths[#paths + 1] = calls[i].method .. " " .. calls[i].path:gsub("^/session/s1", "")
  end
  eq(paths, {
    "POST /execute/sync", -- wait
    "POST /actions", -- press
    "DELETE /actions",
    "POST /element", -- click
    "POST /element/e1/click",
    "POST /element", -- hover
    "POST /actions",
    "POST /element", -- focus
    "POST /execute/sync",
    "POST /execute/sync", -- blur
    "GET /screenshot",
    "POST /execute/sync", -- expect, red: the steps after it do not run
    "DELETE ",
  }, "every step is the WebDriver call it should be, and the session ends")
  local press = calls[5] and calls[5].body.actions[1].actions or {}
  eq(#press, 4, "Control+k: two keys down, two up")
  eq(press[1] and press[1].value, string.char(0xEE, 0x80, 0x89), "... Control as its key point")
  eq(press[2] and press[2].value, "k", "... and the letter")
  eq(press[4] and press[4].type, "keyUp", "... released in reverse")
  has(
    calls[4] and calls[4].body.script,
    "document.title !== ''",
    "a wait is the sheet's expression"
  )

  -- an element that is not there, and an expression that throws, are a failed step
  local function one(step)
    vim.fn.delete(log)
    local r = sheet.run(
      assert(sheet.validate({
        id = "w.one",
        title = "T",
        engine = "webview",
        app = "window",
        steps = { step },
      })),
      {
        root = root,
        out_dir = root .. "/out",
        tools = {
          { name = "node", path = node },
          { name = "tauri-driver", path = "unused" },
          { name = "msedgedriver", path = "m" },
        },
        tauri_driver_argv = { node, fake },
        driver_margin_ms = 20000,
        driver_stop_ms = 4000,
      }
    )
    return r.failures[1] or ""
  end
  has(
    one({ click = "#missing" }),
    "no element #missing in 5000 ms",
    "a missing element fails the step"
  )
  has(one({ expect = "THROWS" }), "javascript error: boom", "a throwing expression fails the step")
  has(one({ press = "Hyper" }), 'unknown key "Hyper"', "an unknown key is refused")

  -- 4. what goes wrong while opening leaves nothing behind ----------------------------------------------------------------
  local function starts()
    local out = {}
    for _, line in ipairs(vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}) do
      local doc = vim.json.decode(line)
      if doc.started then
        out[#out + 1] = doc
      end
    end
    return out
  end
  local function opts_for()
    return {
      root = root,
      out_dir = root .. "/out",
      tools = {
        { name = "node", path = node },
        { name = "tauri-driver", path = "unused" },
        { name = "msedgedriver", path = "m" },
      },
      tauri_driver_argv = { node, fake },
      driver_margin_ms = 20000,
      driver_stop_ms = 4000,
    }
  end
  -- the session cannot be made, for two sizes: each size starts a tree, and neither may outlive the run
  vim.fn.delete(log)
  local failing = sheet.run(
    assert(sheet.validate({
      id = "w.fail",
      title = "T",
      engine = "webview",
      app = "failing",
      sizes = { { cols = 800, rows = 600 }, { cols = 900, rows = 700 } },
      steps = { { expect = "true" } },
    })),
    opts_for()
  )
  eq(failing.status, "fail", "a session that cannot be made fails the sheet")
  has(failing.failures[1], "session not created", "... with the driver's reason")
  local trees = starts()
  eq(#trees, 2, "the second size tried again with a tree of its own")
  eq(trees[2] and trees[2].alive, {}, "... once the tree of the first try was gone")
  for i, t in ipairs(trees) do
    ok(
      vim.wait(5000, function()
        return vim.uv.kill(t.pid, 0) ~= 0
      end, 50),
      ("the tree of try %d is gone (pid %d)"):format(i, t.pid)
    )
    ok(
      type(t.nativePort) == "number" and t.nativePort > 0 and t.nativePort ~= t.port,
      ("try %d names msedgedriver's port of its own (%s)"):format(i, tostring(t.nativePort))
    )
  end

  -- a driver that ends at once is said at once, not after the polling
  vim.fn.delete(log)
  local t0 = vim.uv.hrtime()
  local exits = sheet.run(
    assert(sheet.validate({
      id = "w.exit",
      title = "T",
      engine = "webview",
      app = "exits",
      steps = { { expect = "true" } },
    })),
    opts_for()
  )
  local ms = (vim.uv.hrtime() - t0) / 1e6
  has(
    exits.failures[1],
    "tauri-driver did not start: it ended (exit 3)",
    "a driver that ends says so"
  )
  ok(ms < 8000, ("... without waiting out the polling (%d ms)"):format(ms))
end
