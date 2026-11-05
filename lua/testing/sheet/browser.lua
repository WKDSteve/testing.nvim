-- @cache-env TESTING_* PLAYWRIGHT_BROWSERS_PATH LOCALAPPDATA HOME
---@module 'testing.sheet.browser'
---@brief Engine "browser" of a test sheet: a page in a real browser (Playwright), steps as data.
---@description
--- The steps (`open`, `press`, `click`, `wait`, `expect`, `shot`) are written to a plan file and run by
--- `browser_runner.mjs` with node and `playwright-core`; `wait` and `expect` are JavaScript expressions in the
--- page (`document.activeElement.id === 'a'`). The runner prints one JSON line `{ failures, shots }`; exit 77
--- is a prerequisite that is missing (node, `playwright-core`, chromium): the sheet is a reported skip
--- (`status = "skip"`), never a green run. `playwright-core` is looked up in `$TESTING_PLAYWRIGHT_DIR`, then
--- `<root>`, then `<root>/../mdview.nvim` (the folder whose `node_modules` holds `playwright-core`).
---
--- `driver` is the same runner one step at a time, for `testing.sheet.session`: a process that takes one JSON line per
--- command on stdin and answers one line on stdout (`testing-sheet-driver/1`, schema under `schemas/`).

local M = {}

---The directory whose `node_modules` holds playwright-core.
---@param root string
---@return string|nil
function M.playwright_dir(root)
  local uv = vim.uv or vim.loop
  -- a list built with table.insert: a nil first entry (no variable) would end `ipairs` at once
  local candidates = { root, vim.fs.dirname(root) .. "/mdview.nvim" }
  local env = uv.os_getenv("TESTING_PLAYWRIGHT_DIR")
  if env and env ~= "" then
    table.insert(candidates, 1, env)
  end
  for _, dir in ipairs(candidates) do
    if dir and dir ~= "" and uv.fs_stat(dir .. "/node_modules/playwright-core/package.json") then
      return dir
    end
  end
  return nil
end

---@return string
local function runner_path()
  local here = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.normalize(here)) .. "/browser_runner.mjs"
end

---What the engine needs: node and the folder of playwright-core; nil and the reason of the skip without them.
---@param root string
---@param opts Testing.Sheet.BrowserOpts
---@return string|nil node, string pw_dir_or_reason
local function prerequisites(root, opts)
  local node = opts.node
  if not node then
    for _, row in ipairs(require("testing.tier3").tools()) do
      if row.name == "node" then
        node = row.path
      end
    end
  end
  if not node then
    return nil, "node is not installed (a browser sheet runs with Playwright)"
  end
  local pw = opts.playwright_dir or M.playwright_dir(root)
  if not pw then
    return nil,
      "playwright-core is not installed (npm install in the project, or $TESTING_PLAYWRIGHT_DIR)"
  end
  return node, pw
end

---@class Testing.Sheet.BrowserOpts
---@field root? string
---@field out_dir? string Where `shot` steps write (default `<root>/TESTS/sheets/out`).
---@field node? string
---@field playwright_dir? string
---@field run? fun(argv: string[]): { code: integer, stdout: string, stderr: string } Injectable runner for specs.
---@field channel? string An installed browser instead of Playwright's Chromium (`chrome`, `msedge`).
---@field headed? boolean A visible window (a stepped run only; the suite stays headless).
---@field driver_argv? string[] Another driver process that speaks `testing-sheet-driver/1` (specs).
---@field driver_margin_ms? integer How long a driver may take beyond a step's own timeout (default 60 s).
---@field driver_stop_ms? integer How long a driver may take to end after its stdin closed (default 6 s).

---`sheets.browser` of the project's `.testing.lua` under what the caller gave: which playwright-core, which browser.
---@param root string
---@param opts Testing.Sheet.BrowserOpts
---@return Testing.Sheet.BrowserOpts
local function with_config(root, opts)
  -- without the file nothing has to be loaded; a file that does not load says so where an app needs it
  if not vim.uv.fs_stat(root .. "/.testing.lua") then
    return opts
  end
  local sheets = require("testing.sheet.app").config(root)
  local cfg = type(sheets.browser) == "table" and sheets.browser or {}
  local out = vim.tbl_extend("force", {}, opts)
  if out.playwright_dir == nil and type(cfg.playwright_dir) == "string" then
    out.playwright_dir = root .. "/" .. cfg.playwright_dir
  end
  if out.channel == nil and type(cfg.channel) == "string" then
    out.channel = cfg.channel
  end
  return out
end

---@param s Testing.Sheet
---@param opts? Testing.Sheet.BrowserOpts
---@return Testing.Sheet.Result
function M.run(s, opts)
  opts = opts or {}
  local result = { ok = true, status = "pass", failures = {}, snapshots = {} }
  local root =
    vim.fs.normalize(vim.fn.fnamemodify(opts.root or vim.fn.getcwd(), ":p")):gsub("/+$", "")

  local function skip(why)
    result.status, result.skipped = "skip", why
    return result
  end

  opts = with_config(root, opts)
  local node, pw = prerequisites(root, opts)
  if not node then
    return skip(pw)
  end

  local steps, app = s.steps, nil
  if s.app then
    local started, aerr, app_skip = require("testing.sheet.app").start(s.app, root)
    if app_skip then
      return skip(app_skip)
    end
    if not started then
      result.ok, result.status = false, "fail"
      result.failures[1] = ("the app %s did not start: %s"):format(s.app, tostring(aerr))
      return result
    end
    app = started
    steps = {}
    for n, step in ipairs(s.steps) do
      local expanded, eerr = require("testing.sheet.app").expand_step(step, app.vars)
      if not expanded then
        app.stop()
        result.ok, result.status = false, "fail"
        result.failures[1] = ("step %d: %s"):format(n, tostring(eerr))
        return result
      end
      steps[n] = expanded
    end
  end

  local plan_path = vim.fn.tempname() .. ".plan.json"
  local f = assert(io.open(plan_path, "wb"))
  f:write(vim.json.encode({
    id = s.id,
    root = root,
    out_dir = opts.out_dir or (root .. "/TESTS/sheets/out"),
    playwright_dir = pw,
    channel = opts.channel,
    sizes = s.sizes,
    steps = steps,
  }))
  f:close()

  local argv = { node, runner_path(), plan_path }
  local res
  if opts.run then
    res = opts.run(argv)
  else
    local done = vim.system(argv, { text = true }):wait(120000)
    res = { code = done.code, stdout = done.stdout or "", stderr = done.stderr or "" }
  end
  os.remove(plan_path)
  if app then
    app.stop()
  end

  if res.code == 77 then
    return skip(res.stdout:match("SKIP: ([^\n]*)") or "a browser prerequisite is missing")
  end
  local ok, decoded = pcall(vim.json.decode, res.stdout:match("({[^\n]*})%s*$") or "")
  if not ok or type(decoded) ~= "table" then
    local why = vim.trim(res.stderr ~= "" and res.stderr or res.stdout):sub(1, 300)
    result.ok, result.status = false, "fail"
    result.failures[1] = ("the browser runner failed (exit %s): %s"):format(tostring(res.code), why)
    return result
  end
  vim.list_extend(result.failures, decoded.failures or {})
  vim.list_extend(result.snapshots, decoded.shots or {})
  if #result.failures > 0 then
    result.ok, result.status = false, "fail"
  end
  return result
end

---@param s Testing.Sheet
---@param opts Testing.Sheet.BrowserOpts
---@param ctx Testing.Sheet.DriverContext
---@return table driver See `testing.sheet.driver_rpc`.
function M.driver(s, opts, ctx)
  opts = with_config(ctx.root, opts)
  local pw
  return require("testing.sheet.driver_proc").new(s, opts, ctx, {
    label = "browser driver",
    prepare = function()
      local node, dir = prerequisites(ctx.root, opts)
      if not node then
        return nil, dir
      end
      pw = dir
      return { node, runner_path(), "--driver" }, nil
    end,
    options = function()
      return { headed = opts.headed == true, playwright_dir = pw, channel = opts.channel }
    end,
  })
end

return M
