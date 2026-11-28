-- TESTS/testing/heartbeat_spec.lua -- a run that says nothing for a while says what it waits for: under full load a
-- `--file` run stayed silent for 110 s (markdown.nvim, 2026-11-22). The heartbeat with a clock of its own, and a real
-- isolated run whose child sleeps past a short threshold.

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
      msg .. " (got " .. tostring(haystack) .. ")"
    )
  end
  local hb_mod = require("testing.run.heartbeat")

  -- the rules, with a clock of its own
  local t = 100
  local hb = hb_mod.new({
    after_s = 30,
    every_s = 30,
    now = function()
      return t
    end,
  })
  hb:phase("running 2 spec file(s)")
  hb:file_start("TESTS/a_spec.lua")
  t = 120
  eq(hb:check(), nil, "20 s quiet: nothing yet")
  t = 131
  local line = hb:check()
  has(line, "nothing new for 31 s", "31 s quiet: one line")
  has(line, "running 2 spec file(s)", "... with the phase")
  has(line, "TESTS/a_spec.lua (31 s)", "... and the file still running, for how long")
  t = 140
  eq(hb:check(), nil, "not again within every_s")
  t = 162
  ok(hb:check() ~= nil, "again after every_s while it stays quiet")
  hb:file_done("TESTS/a_spec.lua")
  t = 170
  eq(hb:check(), nil, "an event: quiet again from zero")

  -- a real isolated run whose child sleeps past a threshold of one second: the run says so on the way
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local root = S.new_root()
  local entries = S.project(root, {
    ["TESTS/slow_spec.lua"] = "return function(H) vim.uv.sleep(2500) H.ok(true, 'slept') end\n",
  }, { "TESTS/slow_spec.lua" })
  local said = {}
  local saved_after, saved_tick = hb_mod.AFTER_S, hb_mod.TICK_MS
  hb_mod.AFTER_S, hb_mod.TICK_MS = 1, 100
  local live = hb_mod.new({
    write = function(s)
      said[#said + 1] = s
    end,
  })
  live:phase("running 1 spec file(s)")
  local opts = {
    on_file_start = function(rel)
      live:file_start(rel)
    end,
  }
  live:start()
  local report = S.run(root, entries, opts)
  live:stop()
  hb_mod.AFTER_S, hb_mod.TICK_MS = saved_after, saved_tick
  eq(report.result.cases[1] and report.result.cases[1].status, "pass", "the slow file passes")
  has(
    table.concat(said, "\n"),
    "TESTS/slow_spec.lua",
    "a quiet run of 2.5 s said which file it waits for"
  )
  S.cleanup()
end
