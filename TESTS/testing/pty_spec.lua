-- TESTS/testing/pty_spec.lua -- testing.pty (tier 2.5): the tmux calls it makes (a fake runner records them) and,
-- where tmux is usable, one real session whose screen and raw byte stream are read back.
-- @cache-allow time processes

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local pty = require("testing.pty")
  local windows = require("testing.platform").is_windows()

  -- 1. the argument vectors, with a fake runner ---------------------------------------------------------------------
  local calls = {}
  local function fake(argv)
    calls[#calls + 1] = argv
    return { code = 0, stdout = "tmux 3.7c\n", stderr = "" }
  end
  local lead = windows and { "wsl", "-d", "arch", "--exec", "tmux" } or { "tmux" }
  local opts = { distro = "arch", run = fake, cols = 80, rows = 24 }

  local available, version = pty.available(opts)
  ok(available, "available when tmux -V answers")
  eq(version, "tmux 3.7c", "... with its version")
  eq(calls[1], vim.list_extend(vim.deepcopy(lead), { "-V" }), "the probe is `tmux -V` behind the host prefix")

  calls = {}
  local session = assert(pty.open({ "nvim", "it's" }, opts))
  eq(calls[1][#lead + 1], "new-session", "a detached session is created first")
  local joined = table.concat(calls[1], " ")
  ok(joined:find("-x 80 -y 24", 1, true) ~= nil, "... with the asked size")
  local expected = "exec 'nvim' 'it'" .. string.char(92) .. "''s'"
  ok(joined:find(expected, 1, true) ~= nil, "... and every word of the command quoted")
  eq(calls[2][#lead + 1], "pipe-pane", "the recorder is attached before the program starts")
  eq(calls[3][#lead + 1], "send-keys", "... and only then released")

  calls = {}
  session:send({ "M-n" })
  eq(calls[1], vim.list_extend(vim.deepcopy(lead), { "send-keys", "-t", session.name, "M-n" }), "keys go through send-keys")
  session:send({ "a b" }, true)
  eq(calls[2][#lead + 4], "-l", "literal text uses -l")

  -- a failing tmux is no session
  local broken = pty.open({ "x" }, { run = function()
    return { code = 1, stdout = "", stderr = "no server" }
  end })
  eq(broken, nil, "a failing new-session returns no session")
  local bad = pty.available({ run = function()
    return { code = 1, stdout = "", stderr = "" }
  end })
  eq(bad, false, "tmux that fails is not available")

  -- 2. a real session, where tmux is usable ------------------------------------------------------------------------
  local real_ok = pty.available({})
  if not real_ok then
    print("n/a  tmux is not usable here (WSL with tmux, or tmux on Linux): the real session is skipped")
    return
  end
  local bs = string.char(92)
  local program = "printf 'hello " .. bs .. "033]1337;File=inline=1:QUJD" .. bs .. "007 world'; sleep 5"
  local s, err = pty.open({ "sh", "-c", program }, { cols = 60, rows = 10 })
  ok(s ~= nil, "a real session starts: " .. tostring(err))
  if not s then
    return
  end
  local seen = s:wait_for("hello", 8000)
  ok(seen, "the program's text reaches the screen")
  ok(s:screen():find("world", 1, true) ~= nil, "... the whole line")
  ok(s:raw():find("\27]1337;File=inline=1:QUJD\7", 1, true) ~= nil, "the raw stream keeps the OSC-1337 sequence the screen drops")
  s:close()
  ok(select(2, pcall(function()
    return #s:raw()
  end)) == 0, "close removes the recording")
end
