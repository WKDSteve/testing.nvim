-- TESTS/testing/sheet_panel_spec.lua -- `:Testing sheet step`: the panel over a real `testing sheets step` child with a
-- real child editor: what the buffer shows before and after a step, next, until, breakpoints, a failure with its
-- screen, the end, and that closing the buffer ends the run and leaves no editor behind.
-- @cache-allow time processes
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok = H.ok
  local function has(lines, needle, msg)
    local text = type(lines) == "table" and table.concat(lines, "\n") or tostring(lines)
    return ok(text:find(needle, 1, true) ~= nil, msg .. " (got " .. text:sub(1, 900) .. ")")
  end
  local panel = require("testing.sheet.panel")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-panel"
  local function write(rel, text)
    local p = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
  end
  write("TESTS/minimal_init.lua", "vim.o.swapfile = false\n")
  write(
    "TESTS/sheets/walk.sheet.lua",
    ([[return {
  id = "panel.walk",
  title = "A walk",
  steps = {
    { lua = [=[vim.fn.writefile({ tostring(vim.fn.getpid()) }, %q)]=] },
    { lua = "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello panel' })", note = "write the line" },
    { settle = 5000 },
    { expect = "vim.fn.getline(1) == 'hello panel'", note = "it is there" },
    { expect = "false", note = "this one fails" },
    { lua = "vim.g.never = 1", note = "never reached" },
  },
}
]]):format(root .. "/pid")
  )
  local env = { TESTING_AGENT = "0", TESTING_TRUST = "1" }

  local function lines_of(p)
    return vim.api.nvim_buf_get_lines(p.buf, 0, -1, false)
  end
  local function wait(what, cond)
    ok(vim.wait(60000, cond, 20), "in time: " .. what)
  end
  local function paused_at(p, n)
    wait("paused before step " .. n, function()
      return p.paused ~= nil and p.at == n
    end)
  end

  local p = panel.open(root, "walk", { env = env })
  ok(vim.bo[p.buf].filetype == "testing-sheet", "its filetype")
  ok(not vim.bo[p.buf].modifiable, "the buffer is for reading")
  paused_at(p, 1)
  local first = lines_of(p)
  has(first[1], "A walk  [rpc]", "the title and the engine")
  has(first[2], "paused before step 1 (80x24)", "where it stands")
  has(first[6], "write the line", "a step shows its note")
  ok(first[5]:find("▷", 1, true) ~= nil, "the next step is marked: " .. first[5])
  ok(not panel.until_step(p, 1), "until needs a later step")

  ok(panel.next(p), "next goes")
  ok(not panel.next(p), "... and a second one waits for the first")
  paused_at(p, 2)
  local pid = tonumber(vim.fn.readfile(root .. "/pid")[1])
  ok(vim.uv.kill(pid, 0) == 0, "the child editor runs while it is paused")
  has(lines_of(p)[5], "✓", "a finished step is ticked")

  panel.toggle_break(p, 4)
  has(lines_of(p)[8], "●", "a breakpoint shows")
  panel.toggle_break(p, 3)
  panel.toggle_break(p, 3)
  ok(lines_of(p)[7]:find("●", 1, true) == nil, "a second press takes it away")
  ok(panel.continue(p), "continue goes to the breakpoint")
  paused_at(p, 4)
  has(lines_of(p), "hello panel", "the child's screen as text in the tile")
  has(lines_of(p), "--- step 3, settle: 5000", "the tile of the last step")

  -- the cursor picks the tile
  vim.api.nvim_set_current_buf(p.buf) -- no UI here, so the panel opened no window of its own
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = p.buf })
  has(lines_of(p), "--- step 2, lua:", "the tile of the step under the cursor")

  ok(panel.until_step(p, 5), "until the failing step")
  paused_at(p, 5)
  panel.next(p)
  wait("the failure pauses", function()
    return p.paused == "failed"
  end)
  has(lines_of(p)[2], "step 5 failed", "says which")
  has(lines_of(p)[9], "✗", "a failed step is crossed")
  vim.api.nvim_win_set_cursor(0, { 9, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = p.buf })
  has(lines_of(p), "reason: got false", "the tile says why")
  panel.continue(p)
  wait("the end", function()
    return p.finished ~= nil
  end)
  has(lines_of(p)[2], "finished: fail", "the end")
  has(
    lines_of(p),
    "failed: 80x24 step 5, this one fails (expect false): got false",
    "the failure line"
  )
  ok(vim.uv.kill(pid, 0) ~= 0, "after the end no child editor is left")
  wait("the process ends", function()
    return p.proc == nil
  end)
  ok(not panel.next(p), "after the end nothing goes")
  vim.api.nvim_buf_delete(p.buf, { force = true })

  -- closing the buffer aborts
  local q = panel.open(root, "walk", { env = env })
  paused_at(q, 1)
  panel.next(q)
  paused_at(q, 2)
  local qpid = tonumber(vim.fn.readfile(root .. "/pid")[1])
  local proc = q.proc
  vim.api.nvim_buf_delete(q.buf, { force = true })
  local done = proc:wait(30000)
  ok(done.code == 3, "closing the buffer is an abort: exit " .. tostring(done.code))
  ok(vim.uv.kill(qpid, 0) ~= 0, "... and leaves no child editor")

  -- a command that cannot run: the reason in the buffer
  local bad = panel.open(root, "no.such.sheet", { env = env })
  wait("the end of the process", function()
    return bad.proc == nil and bad.problem ~= nil
  end)
  has(lines_of(bad), "ended without a result: exit 2", "the exit code")
  has(lines_of(bad), "no sheet no.such.sheet", "and what it said")
  vim.api.nvim_buf_delete(bad.buf, { force = true })

  -- a newer schema is refused, an unknown event is not
  local f = { target = "x", marks = {}, breaks = {}, stderr = {}, running = false }
  panel.on_event(f, { schema = panel.SCHEMA, event = "ask", text = "later" })
  ok(f.problem == nil, "an unknown event is for a newer reader")
  panel.on_event(f, { schema = "testing-sheet-session/2", event = "start" })
  has(tostring(f.problem), "another schema", "a higher schema is refused")

  vim.fn.delete(root, "rf")
end
