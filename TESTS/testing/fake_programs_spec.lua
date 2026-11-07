-- TESTS/testing/fake_programs_spec.lua -- testing.fake_programs: stand-ins for `open`, `osascript`, `trash`, `xdg-open` that
-- record argv, cwd and (POSIX, opt-in) stdin, and the platform switch that lets a spec run "as macOS".

return function(H)
  local eq = H.eq
  local fp = require("testing.fake_programs")
  local platform = require("testing.platform")

  ---Run a stand-in through the editor's own search: a `.cmd` is not found by a bare name on Windows, so the path
  ---comes from `exepath` (which honours PATHEXT).
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
end
