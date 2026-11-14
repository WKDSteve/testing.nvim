-- TESTS/testing/tree_tests_drive_spec.lua -- the view `tests` in the real own tree of filetree.nvim: the badge in
-- the file view, the view with its folders, files and cases, the keys that start a run, the jump to a case, and a
-- new result that shows without a key press. `tree_tests_source_spec.lua` checks the registered entry; this one
-- checks that a tree which reads it shows and runs it.
--
-- A script in its own Neovim (`dialect` in .testing.lua): it sits on filetree.nvim's bench `TESTS/native_drive.lua`,
-- which sets up the editor and quits it. filetree.nvim is no dependency of testing.nvim: the run needs
-- `$FILETREE_NVIM_DIR` and says so and passes without it (so the suite and the CI leave it out).
-- Run:  FILETREE_NVIM_DIR=<checkout> nvim --clean --headless -u NONE -l TESTS/testing/tree_tests_drive_spec.lua

---@diagnostic disable: need-check-nil, duplicate-set-field

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h"):gsub("\\", "/")
local plugin = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.rtp:prepend(plugin)

---The first folder of `candidates` that holds `rel`.
local function find(candidates, rel)
  -- not ipairs: a candidate that is not set (an environment variable) is a hole in the list
  for i = 1, #candidates do
    local dir = candidates[i]
    if dir and dir ~= "" and vim.uv.fs_stat(dir .. "/" .. rel) then
      return (dir:gsub("\\", "/"))
    end
  end
  return nil
end

-- Only where it is named: a sibling checkout is somebody's working tree, and its state of the hour must not
-- decide whether the suite of testing.nvim is green.
local filetree = find({ vim.env.FILETREE_NVIM_DIR or "" }, "TESTS/native_drive.lua")
if not filetree then
  io.stdout:write("  n/a  filetree.nvim not found: the run through the own tree is left out\n")
  io.stdout:write("\ntesting.nvim tree_tests_drive_spec: 0 passed, 0 failed\n")
  vim.cmd("qa!")
  return
end

-- Nothing of the person's own state reaches this run, and nothing of it stays: results go to a temp folder.
local scratch = vim.fn.tempname():gsub("\\", "/")
vim.fn.mkdir(scratch, "p")
for _, var in ipairs({ "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME" }) do
  vim.env[var] = scratch
end
local sopts = { state_dir = scratch .. "/state" }

-- the bench looks for lib.nvim and ui.nvim next to filetree.nvim, or where these name them
local repos = vim.env.REPOS_DIR
for _, dep in ipairs({ "lib.nvim", "ui.nvim" }) do
  local var = dep:upper():gsub("%.", "_") .. "_DIR"
  if not vim.env[var] or vim.env[var] == "" then
    local dir = find({
      vim.fs.dirname(plugin) .. "/" .. dep,
      plugin .. "/.deps/" .. dep,
      repos and (repos .. "/" .. dep) or "",
    }, "lua")
    if dir then
      vim.env[var] = dir
    end
  end
end

local RED, GREEN, FRESH = "TESTS/red_spec.lua", "TESTS/green_spec.lua", "TESTS/fresh_spec.lua"
local RED_CASE = RED .. "::red::two"

local state, result, tree_mod, root
local started = {}

---Record a run of the two spec files that ran; `two` of the red file has this status.
local function record(status)
  local res = result.new({ root = root, id = "2026-01-01T00:00:00Z-0001" })
  for _, c in ipairs({
    { RED, "one", "pass", 2 },
    { RED, "two", status, 3 },
    { GREEN, "one", "pass", 2 },
  }) do
    local case = result.new_case({
      file = c[1],
      describe = { c[1] == RED and "red" or "green" },
      name = c[2],
      line = c[4],
    })
    case.status = c[3]
    case.duration_ms = 4
    if c[3] == "fail" then
      case.assertions =
        { { ok = false, msg = "expected 1, got 2", expected = "1", actual = "2", line = 3 } }
    end
    result.add_case(res, case)
  end
  local ok, err = state.record(
    root,
    result.finalize(res),
    { ran_files = { [RED] = true, [GREEN] = true } },
    sopts
  )
  assert(ok, tostring(err))
end

local function spec(name)
  return {
    ('describe("%s", function()'):format(name),
    '  it("one", function() end)',
    '  it("two", function() end)',
    "end)",
  }
end

local T = dofile(filetree .. "/TESTS/native_drive.lua")({
  name = "tree_tests_drive_spec (testing.nvim)",
  files = { "README.md", "lua/x.lua", RED, GREEN, FRESH },
  before_setup = function(T)
    T.mkfile(RED, spec("red"))
    T.mkfile(GREEN, spec("green"))
    T.mkfile(FRESH, spec("fresh"))
    state = require("testing.state")
    result = require("testing.core.result")
    tree_mod = require("testing.integrations.tree")
    root = require("testing.bindings.usrcmds").resolve_root(nil, nil)
    record("fail")
    require("testing").setup({})
    -- what setup registered, with the result folder of this run and a run that starts nothing
    tree_mod.register({
      state_opts = sopts,
      run = function(run)
        started[#started + 1] = run
      end,
    })
  end,
})

local function has(name, text, needle)
  T.ok(
    name .. "  -- " .. vim.inspect(text),
    type(text) == "string" and text:find(needle, 1, true) ~= nil
  )
end

---The line of the tree buffer that contains `needle`, 1-based.
local function line_of(needle)
  for i, line in ipairs(T.lines()) do
    if line:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

---The line of the tree buffer that ends in `needle`, 1-based.
local function line_is(needle)
  for i, line in ipairs(T.lines()) do
    if line:sub(-#needle) == needle then
      return i
    end
  end
  return nil
end

---Put the tree's cursor on the line that shows `needle`.
local function on_line(needle)
  T.tree()
  T.wait(function()
    return line_of(needle) ~= nil
  end)
  local line = assert(line_of(needle), "the tree does not show " .. needle)
  vim.api.nvim_win_set_cursor(T.adapter.get_winid(), { line, 0 })
  vim.cmd("doautocmd CursorMoved")
end

---What is drawn right of the name on the line that shows `needle` (several nodes of the view share the path of
---their spec file, so the bench's lookup by path is not what is asked here).
local function right_of(needle)
  local line = line_of(needle)
  if not line then
    return nil
  end
  local chunks = {}
  local real = vim.api.nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(_, _, _, _, o)
    for _, chunk in ipairs(o.virt_text or {}) do
      local text = vim.trim(chunk[1])
      if text ~= "" then
        chunks[#chunks + 1] = text
      end
    end
    return 0
  end
  pcall(
    require("filetree.native.view").decorate_line,
    T.adapter.get_bufnr(),
    line - 1,
    T.adapter.get_winid()
  )
  vim.api.nvim_buf_set_extmark = real
  return table.concat(chunks, " ")
end

-- ── the badge in the file view ───────────────────────────────────────────────
T.on(RED)
T.wait(function()
  local drawn = T.drawn(RED)
  return drawn and drawn.text:find("1/2", 1, true) ~= nil
end)
has("a spec file with a red case shows it in the file view", T.drawn(RED).text, "✗ 1/2")

-- ── the view ─────────────────────────────────────────────────────────────────
local mark = T.mark()
T.tree()
vim.cmd("Filetree source tests")
T.ok(
  "the view lists the spec files, the one that never ran too",
  T.wait(function()
    return line_of("red_spec.lua") ~= nil
      and line_of("green_spec.lua") ~= nil
      and line_of("fresh_spec.lua") ~= nil
  end)
)
has("a red file carries the sign of its worst case", T.lines()[line_of("red_spec.lua")], "✗")
has("a green file its own", T.lines()[line_of("green_spec.lua")], "✓")
has("a file that never ran says so", T.lines()[line_of("fresh_spec.lua")], "·")
has("a red file counts red over all", right_of("red_spec.lua"), "1/2")
T.ok(
  "... once: the badge of the file view is not drawn next to it",
  not right_of("red_spec.lua"):find("✗", 1, true)
)
T.ok(
  "what is red is open: the red case is in sight without a key press",
  T.wait(function()
    return line_of("two") ~= nil
  end)
)
has("a red case carries its sign", T.lines()[line_of("two")], "✗")
T.ok("a green file stays closed", line_is("green") == nil)

-- ── a run from a node ────────────────────────────────────────────────────────
on_line("two")
T.feed("r")
T.eq("r on a case runs that case", started[#started] and started[#started].flags, {
  file = { RED },
  filter = { RED_CASE },
})
T.eq("... in the project of the tree", started[#started] and started[#started].root, root)
on_line("red_spec.lua")
T.feed("r")
T.eq("r on a spec file runs that file", started[#started].flags, { file = { RED } })
on_line("TESTS")
T.feed("r")
T.eq("r on a folder runs what is below it", started[#started].flags, { file = { "TESTS/" } })
T.feed("R")
T.eq("R runs what failed last time", started[#started].flags, { raw = { "--lf" } })
T.eq("four runs, one per key press", #started, 4)

-- ── a file that never ran ────────────────────────────────────────────────────
T.adapter.expand_node({ path = T.dir .. "/" .. FRESH })
T.ok(
  "opening a file that never ran reads its describe from the file",
  T.wait(function()
    return line_is("· fresh") ~= nil
  end)
)
T.ok("a describe is drawn as a group: no slash after its name", line_is("✗ red") ~= nil)

-- ── the jump ─────────────────────────────────────────────────────────────────
on_line("two")
T.feed("<CR>")
T.ok(
  "<CR> on a case opens its spec file",
  T.wait(function()
    return vim.api.nvim_buf_get_name(0):gsub("\\", "/"):find(RED, 1, true) ~= nil
  end)
)
T.eq("... at the line of the case", vim.api.nvim_win_get_cursor(0)[1], 3)

-- ── a new result ─────────────────────────────────────────────────────────────
record("pass")
T.ok(
  "a new result shows without a key press: the file is green",
  T.wait(function()
    local line = line_of("red_spec.lua")
    return line ~= nil and T.lines()[line]:find("✓", 1, true) ~= nil
  end, 6000)
)
T.ok(
  "... and counts no red case any more",
  not (right_of("red_spec.lua") or "/"):find("/", 1, true)
)
T.ok("... the node kept its place: the case below it is still in sight", line_of("two") ~= nil)

T.eq("nothing was said at warning level", T.loud(mark), {})
T.eq("no dialog nobody expected", T.unanswered, 0)

-- ── setup({ tree = ... }) ────────────────────────────────────────────────────
local registry = require("lib.nvim.tree.registry")
require("testing").setup({ tree = { keys = { run = "gr", failed = false } } })
local keys = {}
for _, action in ipairs(registry.get("source", "tests").actions) do
  keys[action.name] = action.key or false
end
T.eq(
  "setup({ tree = { keys } }) moves the keys of the view",
  keys,
  { ["tests.run"] = "gr", ["tests.run_failed"] = false }
)
require("testing").setup({ tree = false })
T.eq(
  "setup({ tree = false }) takes the view and the badge out",
  { registry.get("source", "tests"), registry.get("decorator", "tests") },
  {}
)
vim.fn.delete(scratch, "rf")
T.finish()
