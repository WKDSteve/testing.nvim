-- TESTS/testing/timeout_escape_list_spec.lua -- the list path (busted, `dry = true`) has the same window the run path
-- closed in c919b32: the file deadline stays armed once it has passed, so the count hook can raise in the few
-- instructions between the end of `dialect.run_file` and `guard:stop()`. Such a raise must end in the file's `note`,
-- never leave `inproc.list` and take every item collected so far with it.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local ok, eq = H.ok, H.eq

  local inproc = require("testing.run.inproc")
  local timeout = require("testing.run.timeout")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-escape-list"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local fh = assert(io.open(root .. "/TESTS/a_spec.lua", "wb"))
  fh:write('describe("d", function()\n  it("one", function() end)\nend)\n')
  fh:close()

  -- Locate the window around the `else` (busted) branch of `M.list`: from the first line inside the
  -- closure that now wraps `dialect.run_file` through the `guard:stop()` call, both still protected
  -- by the outer pcall. Found by source instead of a hardcoded line number, so a refactor moves the
  -- window with the code instead of silently narrowing it to nothing.
  local mod_source = debug.getinfo(inproc.list).source:gsub("^@", "")
  local lines = {}
  for line in io.lines(mod_source) do
    lines[#lines + 1] = line
  end
  local anchor, pcall_line, lower, upper
  for i, line in ipairs(lines) do
    if line:find("dry = true, select = accept", 1, true) then
      anchor = i
    end
  end
  assert(anchor, "could not find the list path's dialect.run_file call in " .. mod_source)
  for i = anchor, 1, -1 do
    if lines[i]:find("pcall(function()", 1, true) then
      pcall_line = i
      break
    end
  end
  assert(
    pcall_line,
    "could not find the outer pcall(function() ... guard:stop() end) around the list path"
  )
  lower = pcall_line + 1
  for i = anchor, #lines do
    if lines[i]:find("guard:stop()", 1, true) then
      upper = i
      break
    end
  end
  assert(upper and upper >= lower, "could not find guard:stop() after the outer pcall")

  local saved_hook, saved_mask, saved_count = debug.gethook()
  local escaped = {}
  local fired_at, runs = 0, 0
  local LIMIT = 200
  for nth = 1, LIMIT do
    runs = nth
    local seen, fired = 0, false
    debug.sethook(function()
      if fired then
        return
      end
      local info = debug.getinfo(2, "Sl")
      if
        info.source:sub(2) == mod_source
        and info.currentline >= lower
        and info.currentline <= upper
      then
        seen = seen + 1
        if seen == nth then
          fired = true
          error(timeout.MARKER .. " file exceeded 1 ms (from the spec's hook)", 0)
        end
      end
    end, "l")
    local fine, items = pcall(inproc.list, {
      root = root,
      files = { root .. "/TESTS/a_spec.lua" },
      dialect = "busted",
    })
    debug.sethook(saved_hook, saved_mask or "", saved_count or 0)
    if not fine then
      escaped[#escaped + 1] = ("line %d: %s"):format(nth, tostring(items))
    end
    if not fired then
      break
    end
    fired_at = nth
  end

  eq(escaped, {}, "a raise between dialect.run_file and guard:stop() stays inside inproc.list")
  ok(fired_at >= 1, "the hook reached the window at least once: " .. fired_at)
  ok(runs < LIMIT, "and the walk ended, every line in the window was tried")

  vim.fn.delete(root, "rf")
end
