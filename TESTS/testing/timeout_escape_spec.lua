-- TESTS/testing/timeout_escape_spec.lua -- the file deadline stays armed after a spec has run past it, so the count
-- hook can raise in the runner's few instructions between the end of the spec and `guard:stop()`. Such a raise must end
-- in the verdict of that file, never leave `inproc.run` and take the whole run with it (seen once on Windows: `file
-- exceeded 300 ms` out of `inproc.run`). With the real hook interval the window is hit about once in a thousand runs,
-- so a line hook raises the same error at each line of the runner in turn, as long as the file's guard is active.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local ok, eq = H.ok, H.eq

  local discover = require("testing.discover")
  local inproc = require("testing.run.inproc")
  local timeout = require("testing.run.timeout")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-escape"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local fh = assert(io.open(root .. "/TESTS/a_spec.lua", "wb"))
  fh:write("return function(H)\n  H.eq(1, 1, 'fine')\nend\n")
  fh:close()
  local files = discover.order(discover.discover(root, { scan_lua_dir = false }))

  -- A guard of our own: without it the guard of the file installs its hook over ours.
  local outer = timeout.start({ label = "outer" })
  local depth = timeout.depth()
  local saved_hook, saved_mask, saved_count = debug.gethook()

  local escaped = {}
  local fired_at, runs = 0, 0
  local LIMIT = 400
  for nth = 1, LIMIT do
    runs = nth
    local armed, seen, fired = false, 0, false
    debug.sethook(function()
      -- only after the first case (before it, no deadline can have passed yet) and only while the guard is active
      if not armed or fired or timeout.depth() <= depth then
        return
      end
      local source = debug.getinfo(2, "S").source
      if source:find("testing/run/inproc.lua", 1, true) then
        seen = seen + 1
        if seen == nth then
          fired = true
          error(timeout.MARKER .. " file exceeded 1 ms (from the spec's hook)", 0)
        end
      end
    end, "l")
    local fine, report = pcall(inproc.run, {
      root = root,
      files = files,
      on_case_early = function()
        armed = true
      end,
    })
    debug.sethook(saved_hook, saved_mask or "", saved_count or 0)
    timeout.release_above(depth)
    if not fine then
      escaped[#escaped + 1] = ("line %d after the case: %s"):format(nth, tostring(report))
    end
    if not fired then
      break
    end
    fired_at = nth
  end
  outer:stop()

  eq(escaped, {}, "a raise after the spec stays inside the run, at every line before guard:stop()")
  ok(fired_at >= 3, "the hook reached the runner's lines after the case: " .. fired_at)
  ok(runs < LIMIT, "and the walk ended, every line was tried")

  vim.fn.delete(root, "rf")
end
