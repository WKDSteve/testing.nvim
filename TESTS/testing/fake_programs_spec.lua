-- TESTS/testing/fake_programs_spec.lua -- testing.fake_programs: stand-ins for `open`, `osascript`, `trash`, `xdg-open` that
-- record argv, cwd and (POSIX, opt-in) stdin, and the platform switch that lets a spec run "as macOS".

return function(H)
  local eq = H.eq
  local fp = require("testing.fake_programs")
  local platform = require("testing.platform")

  ---Run a stand-in by the path the editor's search gives (`exepath`, PATHEXT on Windows); the bare name is checked
  ---below as well.
  local function run(fake, name, args, opts)
    return fake:with_path(function()
      local exe = vim.fn.exepath(name)
      eq(exe ~= "", true, name .. ": found on the PATH while with_path runs")
      local argv = { exe }
      vim.list_extend(argv, args)
      return vim.system(argv, opts or { text = true }):wait(10000)
    end)
  end

  local fake = fp.new({ "open", osascript = { stdout = "picked", exit_code = 3 } })
  eq(vim.fn.isdirectory(fake.dir), 1, "new: the folder exists")
  eq(fake.names, { "open", "osascript" }, "new: both programs, sorted")
  eq(
    fake:path("X"):sub(-2),
    (platform.is_windows() and ";X" or ":X"),
    "path: the stand-ins come first"
  )

  local before = vim.env.PATH
  local r = run(fake, "open", { "-R", "/tmp/a b.txt" })
  eq(r.code, 0, "open: exit 0 by default")
  eq(vim.env.PATH, before, "with_path: the PATH is back")

  local o = run(fake, "osascript", { "-e", "tell app" })
  eq(o.code, 3, "osascript: the given exit code")
  eq((o.stdout or ""):match("picked") ~= nil, true, "osascript: the given stdout")

  local calls = fake:calls()
  eq(#calls, 2, "calls: both recorded, in order")
  eq(calls[1].program, "open", "calls: the first is open")
  eq(calls[1].argv, { "-R", "/tmp/a b.txt" }, "calls: argv without the program, a blank kept")
  eq(calls[2].argv, { "-e", "tell app" }, "calls: the second argv")
  eq(#fake:calls("osascript"), 1, "calls: filter by program")
  eq(fake:calls("open")[1].cwd ~= "", true, "calls: the working directory is recorded")

  -- the bare name, as a feature calls it (`vim.system({ "open", ... })`): found on every system, the `.cmd` on
  -- Windows too
  fake:reset()
  local bare = fake:with_path(function()
    return vim.system({ "open", "bare" }, { text = true }):wait(10000)
  end)
  eq(bare.code, 0, "bare name: the stand-in runs")
  eq(#fake:calls("open") == 1 and fake:calls("open")[1].argv, { "bare" }, "bare name: recorded")
  fake:reset()

  -- every argument as the program got it: cmd splits `%1` at `=`, `,` and `;`, and an empty one ended the list
  local hard = {
    "--start=1",
    "--window-size=1280,900",
    "a;b",
    "",
    "x y",
    'q"uote',
    "C:\\dir\\",
    "back\\slash",
    "after",
  }
  r = run(fake, "open", hard)
  eq(r.code, 0, "hard arguments: the stand-in runs")
  eq(
    #fake:calls("open") == 1 and fake:calls("open")[1].argv,
    hard,
    "hard arguments: recorded one by one, an empty one included"
  )
  run(fake, "open", { "" })
  eq(fake:calls("open")[2] and fake:calls("open")[2].argv, { "" }, "an empty argument alone")
  run(fake, "open", {})
  eq(fake:calls("open")[3] and fake:calls("open")[3].argv, {}, "no argument at all")

  -- calls at the same time: each record arrives whole (the `.cmd` stand-in wrote line by line, and a second call
  -- lost its lines to the lock or mixed them into the other's record)
  for round = 1, 3 do
    fake:reset()
    local jobs = {}
    fake:with_path(function()
      local exe = vim.fn.exepath("open")
      for i = 1, 8 do
        jobs[i] = vim.system({ exe, "n" .. i, "--k=" .. round }, { text = true })
      end
    end)
    for _, j in ipairs(jobs) do
      j:wait(20000)
    end
    local seen = {}
    for _, c in ipairs(fake:calls("open")) do
      seen[#seen + 1] = table.concat(c.argv, " ")
    end
    table.sort(seen)
    local want = {}
    for i = 1, 8 do
      want[i] = ("n%d --k=%d"):format(i, round)
    end
    table.sort(want)
    eq(seen, want, "8 calls at once, round " .. round .. ": 8 whole records")
  end
  fake:reset()

  -- the Windows command line rules, on every system
  for _, case in ipairs({
    { "", {} },
    { "  a  b\t c ", { "a", "b", "c" } },
    { '--start=1 "" "x y"', { "--start=1", "", "x y" } },
    { '"q\\"uote"', { 'q"uote' } },
    { '"a""b"', { 'a"b' } },
    { 'C:\\dir\\ "C:\\dir\\\\"', { "C:\\dir\\", "C:\\dir\\" } },
    { 'a\\\\\\"b', { 'a\\"b' } },
    { 'x"y z"w', { "xy zw" } },
  }) do
    eq(fp.split_cmdline(case[1]), case[2], "split_cmdline: " .. case[1])
  end

  fake:reset()
  eq(#fake:calls(), 0, "reset: forgotten")

  if not platform.is_windows() then
    local f2 = fp.new({ trash = { stdin = true } })
    local t = run(f2, "trash", {}, { text = true, stdin = "one\ntwo\n" })
    eq(t.code, 0, "trash: stdin recorded run exits 0")
    eq(f2:calls()[1].stdin, "one\ntwo", "stdin: recorded when asked for")
    f2:close()
  end

  -- the system switch
  fake:as("macos", function()
    eq(platform.is_macos(), true, "as macos: macOS")
    eq(platform.is_windows(), false, "as macos: not Windows")
    -- the stand-ins follow the host, not the faked system: on Windows a `:` PATH or an `sh` stand-in finds nothing
    fake:reset()
    eq(run(fake, "open", { "-R", "x" }).code, 0, "as macos: a stand-in still runs")
    eq(fake:calls("open")[1].argv, { "-R", "x" }, "as macos: ... and is recorded")
  end)
  fake:as("linux", function()
    eq(platform.is_macos(), false, "as linux: not macOS")
    eq(platform.is_windows(), false, "as linux: not Windows")
    local inner = fp.new({ "xdg-open" })
    eq(run(inner, "xdg-open", { "a.txt" }).code, 0, "as linux: a fake made inside runs on the host")
    eq(inner:calls()[1].argv, { "a.txt" }, "as linux: ... and is recorded")
    inner:close()
  end)
  local ok = pcall(fake.as, fake, "macos", function()
    error("boom")
  end)
  eq(ok, false, "as: an error of the body goes on")
  eq(platform.is_windows(), vim.fn.has("win32") == 1, "as: the real answer is back after an error")
  eq(
    select(2, pcall(fake.as, fake, "beos", function() end)):match("windows, macos or linux") ~= nil,
    true,
    "as: a wrong system is refused"
  )

  local dir = fake.dir
  fake:close()
  eq(vim.fn.isdirectory(dir), 0, "close: the folder is gone")

  -- testing.fake_redirect: a start of a stand-in goes straight to it, so no part of an argument is run (on Windows
  -- cmd.exe ran `marker=1` of `x&marker=1` as a command) and a call of `<name>.exe` or a bare `uv.spawn` reaches it
  local redirect = require("testing.fake_redirect")
  local rf = fp.new({ "tfopener", "tfmarker", tfanswer = { stdout = "picked", exit_code = 3 } })
  local tricky =
    { "x&tfmarker=1", "a|b", "<c>", "^d", "%PATH%", "2", "e=f,g;h", 'q"uote', "", "two words" }
  if platform.is_windows() then
    -- (a POSIX stand-in writes one argument per line, a line break does not survive there)
    tricky[#tricky + 1] = "line\nbreak"
  end
  local orig_system = vim.system
  eq(redirect.install({ dir = rf.dir }), true, "redirect: installs for a folder of stand-ins")
  local res = vim.system(vim.list_extend({ "tfopener" }, tricky), { text = true }):wait(20000)
  eq(res.code, 0, "redirect: vim.system ran the stand-in")
  eq(
    rf:calls("tfopener")[1] and rf:calls("tfopener")[1].argv,
    tricky,
    "redirect: every argument as given"
  )
  eq(#rf:calls("tfmarker"), 0, "redirect: no part of an argument ran as a command")

  -- calls at the same time through the redirect: each record whole (the recorder takes the lock folder too)
  rf:reset()
  local par = {}
  for i = 1, 8 do
    par[i] = vim.system({ "tfopener", "p" .. i, "--q" }, { text = true })
  end
  for _, j in ipairs(par) do
    j:wait(30000)
  end
  local pseen = vim.tbl_map(function(c)
    return table.concat(c.argv, " ")
  end, rf:calls("tfopener"))
  table.sort(pseen)
  eq(
    pseen,
    { "p1 --q", "p2 --q", "p3 --q", "p4 --q", "p5 --q", "p6 --q", "p7 --q", "p8 --q" },
    "redirect: 8 calls at once, 8 whole records"
  )
  eq(
    vim.uv.fs_stat(rf.dir .. "/calls.log.lock"),
    nil,
    "redirect: the lock folder is gone afterwards"
  )

  rf:reset()
  eq(vim.system({ "tfopener.exe", "u" }):wait(20000).code, 0, "redirect: <name>.exe")
  eq(
    rf:calls("tfopener")[1] and rf:calls("tfopener")[1].argv,
    { "u" },
    "redirect: <name>.exe reaches the stand-in"
  )

  rf:reset()
  local done = false
  local handle = vim.uv.spawn("tfopener", { args = { "s&t" } }, function()
    done = true
  end)
  eq(handle ~= nil, true, "redirect: a bare uv.spawn finds the stand-in")
  vim.wait(20000, function()
    return done
  end, 20)
  if handle then
    handle:close()
  end
  eq(
    rf:calls("tfopener")[1] and rf:calls("tfopener")[1].argv,
    { "s&t" },
    "redirect: uv.spawn recorded"
  )

  rf:reset()
  local out = vim.fn.system({ "tfanswer", "k" })
  eq({ vim.v.shell_error, out }, { 3, "picked" }, "redirect: the stand-in's stdout and exit code")
  -- a command string: io.popen goes to cmd.exe on Windows whatever 'shell' says
  rf:reset()
  local ph = assert(io.popen("tfopener plain words"))
  ph:read("*a")
  ph:close()
  eq(
    rf:calls("tfopener")[1] and rf:calls("tfopener")[1].argv,
    { "plain", "words" },
    "redirect: a command string to io.popen, its first word"
  )
  -- ... and a string to vim.fn.system goes to 'shell': quoted for that shell
  rf:reset()
  local saved_shell = {
    shell = vim.o.shell,
    shellcmdflag = vim.o.shellcmdflag,
    shellxquote = vim.o.shellxquote,
    shellquote = vim.o.shellquote,
  }
  if platform.is_windows() then
    vim.o.shell, vim.o.shellcmdflag, vim.o.shellxquote, vim.o.shellquote =
      "cmd.exe", "/s /c", '"', ""
  else
    vim.o.shell, vim.o.shellcmdflag, vim.o.shellxquote, vim.o.shellquote = "sh", "-c", "", ""
  end
  vim.fn.system("tfopener 'one' two")
  for k, v in pairs(saved_shell) do
    vim.o[k] = v
  end
  eq(
    rf:calls("tfopener")[1] and rf:calls("tfopener")[1].argv,
    platform.is_windows() and { "'one'", "two" } or { "one", "two" },
    "redirect: a command string to vim.fn.system"
  )
  eq(
    redirect.shell_kind("C:/Program Files/PowerShell/7/pwsh.exe"),
    "pwsh",
    "shell_kind: pwsh by path"
  )
  eq(redirect.shell_kind("powershell -NoLogo"), "pwsh", "shell_kind: with arguments")
  eq(redirect.shell_kind("CMD.EXE"), "cmd", "shell_kind: cmd")
  eq(redirect.shell_kind("/bin/bash"), "sh", "shell_kind: anything else")
  eq(
    redirect.line("tfopener a", "pwsh"):sub(1, 2),
    "& ",
    "redirect: PowerShell runs the quoted path through its call operator"
  )
  eq(
    redirect.argv({ "git", "status" }),
    { "git", "status" },
    "redirect: another program is left as it is"
  )
  eq(
    redirect.argv({ vim.fn.getcwd() .. "/tfopener", "x" })[1],
    vim.fn.getcwd() .. "/tfopener",
    "redirect: a path outside the folder of the stand-ins is left as it is"
  )
  redirect.uninstall()
  eq(vim.system == orig_system, true, "redirect: uninstall puts vim.system back")
  eq(redirect.match("tfopener"), nil, "redirect: nothing matches after uninstall")
  eq(
    select(1, redirect.install({ dir = rf.dir .. "/none" })),
    false,
    "redirect: a folder without specs.json"
  )
  rf:close()
end
