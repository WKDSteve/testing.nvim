-- TESTS/testing/ci_wsl_lock_spec.lua -- the mirror lock of `ci commit --wsl` (testing.ci.wsl.lock_lines/run_line),
-- run for real in bash: a child of the run does not inherit the lock's fd, a stopped orphan the run left behind is
-- ended when the run ends and does not keep the lock, an orphan of an earlier run is ended before the next run starts,
-- and a run that waits too long names the holder. On 2026-11-22 one stopped, orphaned sheet child (a detached
-- `nvim --embed`) held the lock for an hour while every `--wsl` check of every session waited.
-- Each case has a mirror of its own below a temporary HOME: never the real ~/.cache/testing-wsl/.lock.

---@diagnostic disable: need-check-nil

return function(H)
  local ok = H.ok
  if require("testing.platform").is_windows() then
    print("n/a  the mirror lock runs in bash in WSL (flock, /proc); checked on Linux")
    return
  end
  for _, tool in ipairs({ "bash", "flock", "setsid", "ps", "awk" }) do
    if vim.fn.executable(tool) ~= 1 then
      print("n/a  no " .. tool .. " on this machine")
      return
    end
  end
  if not vim.uv.fs_stat("/proc/self/fd") then
    print("n/a  no /proc on this machine")
    return
  end

  local wsl = require("testing.ci.wsl")

  local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local t = f:read("*a")
    f:close()
    return t
  end
  ---A process that is gone (or a zombie): nothing it held is held any more.
  local function gone(pid)
    local stat = read("/proc/" .. pid .. "/stat")
    return stat == nil or stat:match("^%d+ %b() (%a)") == "Z"
  end
  local leftovers = {}
  ---The pid a helper wrote to `path` (waits for it); remembered to be ended at the end of the file whatever happens.
  local function pid_in(path)
    local pid
    vim.wait(5000, function()
      pid = tonumber(vim.trim(read(path) or ""))
      return pid ~= nil
    end, 20)
    if pid then
      leftovers[#leftovers + 1] = pid
    end
    return pid
  end
  ---A fresh HOME with its own mirror folder (`$HOME/m`).
  local function home()
    local dir = vim.fs.normalize(vim.fn.tempname()) .. "-wsl-lock"
    vim.fn.mkdir(dir .. "/m", "p")
    return dir
  end
  ---The lock part of the WSL script around `cmd`, as `wsl.script` puts it together.
  local function fragment(cmd)
    local lines = { "set -u", 'M="$HOME/m"', 'mkdir -p "$M"' }
    vim.list_extend(lines, wsl.lock_lines())
    lines[#lines + 1] = wsl.run_line(cmd)
    return table.concat(lines, "\n") .. "\n"
  end
  local function start(dir, cmd, on_stderr)
    return vim.system({ "bash", "-s" }, {
      text = true,
      stdin = fragment(cmd),
      env = { HOME = dir },
      stderr = on_stderr,
    })
  end
  local function run(dir, cmd)
    return start(dir, cmd):wait(20000)
  end
  local function lock_free(dir)
    return vim.system({ "flock", "-n", dir .. "/m/.lock", "true" }):wait(5000).code == 0
  end

  -- a command of the run does not inherit the lock's fd (the shell alone holds it)
  do
    local dir = home()
    write(dir .. "/a.sh", ('ls -l /proc/$$/fd > "%s/fds" 2>&1\n'):format(dir))
    local res = run(dir, ('sh "%s/a.sh"'):format(dir))
    ok(res.code == 0, "fd: the run ends well (" .. tostring(res.stderr) .. ")")
    local fds = read(dir .. "/fds")
    ok(fds ~= nil and fds ~= "", "fd: the command listed its descriptors")
    ok(
      fds ~= nil and fds ~= "" and not fds:find("/m/.lock", 1, true),
      "fd: the command of the run has no fd on the lock: " .. tostring(fds)
    )
  end

  -- a detached grandchild that stops itself and outlives the run (the orphaned sheet child): ended with the run,
  -- and the lock is free
  do
    local dir = home()
    write(
      dir .. "/gc.sh",
      ('echo $$ > "%s/gc.tmp"; mv "%s/gc.tmp" "%s/gc.pid"\nkill -STOP $$\nsleep 30\n'):format(
        dir,
        dir,
        dir
      )
    )
    write(
      dir .. "/b.sh",
      ('setsid sh "%s/gc.sh" </dev/null >/dev/null 2>&1 &\nwhile [ ! -s "%s/gc.pid" ]; do sleep 0.05; done\n'):format(
        dir,
        dir
      )
    )
    local res = run(dir, ('sh "%s/b.sh"'):format(dir))
    ok(res.code == 0, "orphan: the run ends well (" .. tostring(res.stderr) .. ")")
    local pid = pid_in(dir .. "/gc.pid")
    ok(pid ~= nil, "orphan: the grandchild started")
    if pid then
      ok(
        vim.wait(3000, function()
          return gone(pid)
        end, 20),
        "orphan: the stopped grandchild is ended with the run"
      )
    end
    ok(lock_free(dir), "orphan: the lock is free after the run")
  end

  -- an orphan of an earlier run (its shell was killed before the exit trap) is ended before the next run checks out
  do
    local dir = home()
    write(
      dir .. "/o.sh",
      ('echo $$ > "%s/o.tmp"; mv "%s/o.tmp" "%s/o.pid"\nkill -STOP $$\nsleep 30\n'):format(
        dir,
        dir,
        dir
      )
    )
    vim
      .system({ "bash", "-c", ('setsid sh "%s/o.sh" </dev/null >/dev/null 2>&1 &'):format(dir) }, {
        env = { TESTING_WSL_RUN = dir .. "/m" },
      })
      :wait(5000)
    local pid = pid_in(dir .. "/o.pid")
    ok(pid ~= nil and not gone(pid), "earlier orphan: it is there and stopped")
    write(
      dir .. "/c.sh",
      ('p=$(cat "%s/o.pid"); i=0\n'):format(dir)
        .. "while [ $i -lt 40 ]; do s=$(awk '{print $3}' /proc/$p/stat 2>/dev/null)\n"
        .. '  case "$s" in ""|Z) break;; esac; sleep 0.05; i=$((i+1)); done\n'
        .. ('case "$s" in ""|Z) echo gone;; *) echo "alive $s";; esac > "%s/seen"\n'):format(dir)
    )
    local res = run(dir, ('sh "%s/c.sh"'):format(dir))
    ok(res.code == 0, "earlier orphan: the run ends well (" .. tostring(res.stderr) .. ")")
    H.eq(
      vim.trim(read(dir .. "/seen") or ""),
      "gone",
      "earlier orphan: ended before the run's command started"
    )
  end

  -- a process that carries the marker of ANOTHER mirror is left alone (a nested run, a second user of the machine)
  do
    local dir, other = home(), home()
    write(
      dir .. "/x.sh",
      ('echo $$ > "%s/x.tmp"; mv "%s/x.tmp" "%s/x.pid"\nsleep 30\n'):format(dir, dir, dir)
    )
    vim
      .system({ "bash", "-c", ('setsid sh "%s/x.sh" </dev/null >/dev/null 2>&1 &'):format(dir) }, {
        env = { TESTING_WSL_RUN = other .. "/m" },
      })
      :wait(5000)
    local pid = pid_in(dir .. "/x.pid")
    local res = run(dir, "true")
    ok(res.code == 0, "other mirror: the run ends well")
    ok(pid ~= nil and not gone(pid), "other mirror: its process is not ended")
  end

  -- the exit code of the run's command is the script's
  do
    local res = run(home(), "sh -c 'exit 7'")
    H.eq(res.code, 7, "exit code: the command's, through the exit trap")
  end

  -- waiting longer than LOCK_WAIT_S names the holder, then the run goes on once the lock is free
  do
    local dir = home()
    local holder = vim.system({ "flock", "-o", dir .. "/m/.lock", "sleep", "31.7" })
    vim.wait(2000, function()
      return not lock_free(dir)
    end, 20)
    local saved = wsl.LOCK_WAIT_S
    wsl.LOCK_WAIT_S = 1
    local err = {}
    local ok_start, job = pcall(start, dir, "true", function(_, data)
      err[#err + 1] = data
    end)
    wsl.LOCK_WAIT_S = saved
    ok(ok_start, "holder: the run starts")
    local said = vim.wait(10000, function()
      return table.concat(err):find("waiting for the mirror lock", 1, true) ~= nil
    end, 50)
    local text = table.concat(err)
    ok(said, "holder: a run that waits says so: " .. text)
    H.has(text, ("locked by pid %d"):format(holder.pid), "holder: the pid from /proc/locks")
    H.has(text, "sleep 31.7", "holder: the command line of what has the lock open")
    holder:kill(9)
    local res = ok_start and job:wait(10000) or {}
    ok(res.code == 0, "holder: the run goes on once the lock is free")
  end

  for _, pid in ipairs(leftovers) do
    pcall(vim.uv.kill, pid, "sigcont")
    pcall(vim.uv.kill, pid, "sigkill")
  end
end
