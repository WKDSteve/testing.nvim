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
-- the child of the real run below is told to trust the fixture project, and finds lib.nvim where this run does
vim.env.TESTING_TRUST = "1"

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
local started, pipelines = {}, {}

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
  local ok, err =
    state.record(root, result.finalize(res), { ran_files = { [RED] = true, [GREEN] = true } })
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
  features = { preview = { enabled = true, mode = "float", cursor_debounce_ms = 10 } },
  before_setup = function(T)
    T.mkfile(RED, spec("red"))
    T.mkfile(GREEN, spec("green"))
    T.mkfile(FRESH, spec("fresh"))
    state = require("testing.state")
    result = require("testing.core.result")
    tree_mod = require("testing.integrations.tree")
    root = require("testing.bindings.usrcmds").resolve_root(nil, nil)
    record("fail")
    -- the last pipeline run of the project, as `testing ci` leaves it in the state folder
    local ci_path = require("testing.explorer.ci").path(root)
    vim.fn.mkdir(vim.fs.dirname(ci_path), "p")
    vim.fn.writefile({
      vim.json.encode({
        schema = "testing-ci/1",
        profile = "fast",
        verdict = "red",
        steps = {
          { name = "stylua", state = "green", ms = 700, findings = {} },
          {
            name = "luacheck",
            state = "red",
            ms = 1500,
            findings = { { file = "lua/x.lua", line = 1, col = 7, text = "unused variable x" } },
          },
        },
      }),
    }, ci_path)
    require("testing").setup({})
    -- what setup registered, with the result folder of this run and a run that starts nothing
    tree_mod.register({
      run = function(run)
        started[#started + 1] = run
      end,
      ci_run = function(run)
        pipelines[#pipelines + 1] = run
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

-- ── the last pipeline run ────────────────────────────────────────────────────
T.ok("the last pipeline run stands first in the view", line_of("Pipeline fast") == 2)
has("... red, with the count of its red steps", right_of("Pipeline fast"), "1/2")
T.ok(
  "a red step is open: its finding is in sight",
  T.wait(function()
    return line_of("unused variable x") ~= nil
  end)
)
has("... with the place it points to", right_of("unused variable x"), "lua/x.lua:1")
on_line("luacheck")
T.feed("r")
T.eq(
  "r on a step runs that step of the pipeline again",
  pipelines[#pipelines],
  { root = root, profile = "fast", steps = { "luacheck" } }
)
on_line("Pipeline fast")
T.feed("r")
T.eq("r on the pipeline runs its profile", pipelines[#pipelines], { root = root, profile = "fast" })
T.eq("... and neither started a test run", #started, 4)
on_line("unused variable x")
T.feed("<CR>")
T.ok(
  "<CR> on a finding opens the file it names",
  T.wait(function()
    return vim.api.nvim_buf_get_name(0):gsub("\\", "/"):find("lua/x.lua", 1, true) ~= nil
  end)
)
T.eq("... at its line and column", vim.api.nvim_win_get_cursor(0), { 1, 6 })

-- ── a pipeline that is going ─────────────────────────────────────────────────
-- the events of a run as the editor hands them on (`testing.ci.editor.listen`): the step lines move in the tree
---Whether the line of the step `name` shows `sign`.
local function shows(name, sign)
  local line = line_is(name)
  return line ~= nil and T.lines()[line]:find(sign, 1, true) ~= nil
end
T.tree()
tree_mod.on_ci_event(
  root,
  { event = "run_start", profile = "fast", steps = { "stylua", "luacheck" } }
)
T.ok(
  "a pipeline run that starts shows its planned steps as queued",
  T.wait(function()
    return shows("stylua", "◌") and shows("luacheck", "◌")
  end)
)
T.ok("... the finding of the last run is gone with it", line_of("unused variable x") == nil)
tree_mod.on_ci_event(root, { event = "step_start", step = "stylua", index = 1, total = 2 })
T.ok(
  "the step that is going shows as running, without a new root",
  T.wait(function()
    return shows("stylua", "●")
  end)
)
tree_mod.on_ci_event(root, { event = "step_end", step = "stylua", state = "green", ms = 700 })
T.ok(
  "... and its state when it has ended",
  T.wait(function()
    return shows("stylua", "✓")
  end)
)
has("... with its time", right_of("stylua"), "700ms")
tree_mod.on_ci_event(root, { event = "run_done", synthetic = true })
-- (the red step is closed now: `open` works once per node id in the tree, and this one was open before the run)
T.ok(
  "a run that was killed leaves the last document: the step is red again, nothing stays queued",
  T.wait(function()
    return shows("luacheck", "✗") and shows("stylua", "✓")
  end)
)

-- ── a file that never ran ────────────────────────────────────────────────────
T.adapter.expand_node({ path = T.dir .. "/" .. FRESH })
T.ok(
  "opening a file that never ran reads its describe from the file",
  T.wait(function()
    return line_is("· fresh") ~= nil
  end)
)
T.ok("a describe is drawn as a group: no slash after its name", line_is("✗ red") ~= nil)

-- ── the preview of a red case ────────────────────────────────────────────────
-- the tree asks the source of the node first; a filetree.nvim that does not yet is left out
if pcall(require, "filetree.features.ui.preview.custom") then
  ---The lines of the float that shows `needle`, joined.
  local function float_with(needle)
    for _, float in ipairs(T.floats()) do
      local text = table.concat(float.lines, "\n")
      if text:find(needle, 1, true) then
        return text
      end
    end
    return nil
  end
  on_line("two")
  T.feed("<Tab>")
  T.ok(
    "<Tab> on a red case shows what it said",
    T.wait(function()
      return float_with("expected 1, got 2") ~= nil
    end)
  )
  local said = float_with("expected 1, got 2") or ""
  has("... its status", said, "status: fail")
  has("... expected against actual", said, "## expected")
  has("... and the failing assertion with its line", said, "- line 3: expected 1, got 2")
  T.feed("<Tab>")
  T.ok(
    "<Tab> again takes it away",
    T.wait(function()
      return float_with("expected 1, got 2") == nil
    end)
  )
else
  T.na("this filetree.nvim does not ask a source for a preview yet")
end

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

-- ── a real run, followed while it goes ───────────────────────────────────────
-- `r` on the file that never ran, with the real child this time: the run writes its events to a file, the
-- editor reads it as it grows, and the tree is told case by case.
tree_mod.register({})
T.tree()
vim.cmd("Filetree source tests")
-- the entry was replaced: the tree shows the view from its top again. Nothing is red now, and the one spec folder
-- is open all the same: its files are in sight without a key press
T.ok(
  "after the source registered again the one spec folder is open, with nothing red below it",
  T.wait(function()
    return line_of("fresh_spec.lua") ~= nil
  end)
)
local follow = require("testing.bindings.live")
local kinds, synthetic = {}, false
local unlisten = follow.listen(function(_, batch)
  for _, ev in ipairs(batch) do
    kinds[ev.event] = (kinds[ev.event] or 0) + 1
    synthetic = synthetic or ev.synthetic == true
  end
end)
local verdict
local real_show = require("testing.bindings.child").show
require("testing.bindings.child").show = function(v)
  verdict = v
end
on_line("fresh_spec.lua")
T.feed("r")
T.eq("a run is followed as soon as it starts", follow.active(), 1)
T.ok(
  "the run ends",
  T.wait(function()
    return verdict ~= nil
  end, 120000)
)
require("testing.bindings.child").show = real_show
unlisten()
T.ok(
  "its events reached the editor: the plan, the file, its two cases, the end  -- "
    .. vim.inspect(kinds),
  kinds.run_start == 1 and kinds.file_start == 1 and kinds.case == 2 and kinds.run_done == 1
)
T.ok("... the end the run wrote itself, not one made up for a killed run", not synthetic)
T.eq("... and nothing is followed after it", follow.active(), 0)
T.ok(
  "the file that never ran shows the result of the run",
  T.wait(function()
    local line = line_of("fresh_spec.lua")
    return line ~= nil and T.lines()[line]:find("·", 1, true) == nil
  end, 6000)
)
local after = state.load(root)
local fresh_cases = 0
for _, case in ipairs(after.cases) do
  fresh_cases = fresh_cases + (case.file == FRESH and 1 or 0)
end
T.eq("... which stored its two cases", fresh_cases, 2)
T.ok("... and left the cases of the other files alone", state.case(after, RED_CASE) ~= nil)
T.eq(
  "... and the list of the spec files it discovered, which the view reads instead of discovering itself",
  after.specs,
  { FRESH, GREEN, RED }
)
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
  { ["tests.run"] = "gr", ["tests.ci"] = "gr", ["tests.run_failed"] = false }
)
require("testing").setup({ tree = false })
T.eq(
  "setup({ tree = false }) takes the view and the badge out",
  { registry.get("source", "tests"), registry.get("decorator", "tests") },
  {}
)
vim.fn.delete(scratch, "rf")
T.finish()
