-- TESTS/testing/launcher_spec.lua -- the `testing` command itself (bin/testing, bin/testing.cmd on Windows): the
-- messages and docs tell people to type `testing ci trust ...`, so the command has to exist, print what the
-- engine prints, hand its exit code through and never fail silently (no nvim on the PATH, or a copy of the
-- launcher away from its checkout: a message and exit 3). Starts `sh` / `cmd`: both are in
-- `guards.process_net.allow_exec` of .testing.lua (a spec of this form passes no tags to the guard).

return function(H)
  local ok, eq = H.ok, H.eq
  local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this))))
  local win = vim.fn.has("win32") == 1
  -- resolved here: vim.system looks the program up in the PATH handed to the child, and the bare one has no sh
  local sh = win and "sh" or vim.fn.exepath("sh")

  ---@param path_env string the PATH the launcher sees
  ---@param bin string the folder holding the launcher
  ---@param ... string arguments of `testing`
  ---@return vim.SystemCompleted
  local function launch(path_env, bin, ...)
    local argv = win and { "cmd.exe", "/d", "/c", bin .. "/testing.cmd", ... }
      or { sh, bin .. "/testing", ... }
    return vim.system(argv, { text = true, env = { PATH = path_env } }):wait(60000)
  end

  ---@param r vim.SystemCompleted
  ---@param needle string
  ---@param msg string
  local function says(r, needle, msg)
    ok(
      (r.stderr or ""):find(needle, 1, true) ~= nil,
      msg .. " (stderr: " .. (r.stderr or ""):sub(1, 300) .. ")"
    )
  end

  local bin = repo .. "/bin"
  ok(vim.uv.fs_stat(bin .. "/testing") ~= nil, "bin/testing exists")
  ok(vim.uv.fs_stat(bin .. "/testing.cmd") ~= nil, "bin/testing.cmd exists")

  -- with nvim on the PATH (the editor running this spec, whatever the PATH of the spec says): the engine runs,
  -- its output and exit code come through (`ci trust` without arguments is the usage, exit 2, and writes nothing)
  local sep = win and ";" or ":"
  local nvim_dir = vim.fs.dirname(vim.v.progpath)
  local r = launch(nvim_dir .. sep .. (os.getenv("PATH") or ""), bin, "ci", "trust")
  eq(r.code, 2, "the exit code of the engine is handed through")
  says(r, "testing ci trust: no arguments", "the engine's message is printed")
  says(r, "usage:", "and the usage")

  -- without nvim on the PATH: never silent, exit 3
  local bare
  if win then
    bare = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32"
  else
    -- a PATH with only the one external tool the script needs (`dirname`), so no nvim of the system is found
    bare = vim.fn.tempname()
    vim.fn.mkdir(bare, "p")
    assert(vim.uv.fs_symlink(vim.fn.exepath("dirname"), bare .. "/dirname"))
  end
  local r2 = launch(bare, bin, "ci", "trust")
  eq(r2.code, 3, "no nvim: exit 3")
  says(r2, "nvim is not on the PATH", "no nvim: it says so")

  -- a copy of the launcher away from its checkout: it cannot find scripts/testing.lua and says so, exit 3
  local away = vim.fn.tempname() .. "/bin"
  vim.fn.mkdir(away, "p")
  for _, name in ipairs({ "testing", "testing.cmd" }) do
    assert(vim.uv.fs_copyfile(bin .. "/" .. name, away .. "/" .. name))
  end
  local r3 = launch(nvim_dir .. sep .. (os.getenv("PATH") or ""), away, "ci", "trust")
  eq(r3.code, 3, "a launcher without its checkout: exit 3")
  says(r3, "cannot find", "a launcher without its checkout: it says so")
end
