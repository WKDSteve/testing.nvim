-- TESTS/testing/launcher_spec.lua -- the `testing` command itself (bin/testing, bin/testing.cmd on Windows): the
-- messages and docs tell people to type `testing ci trust ...`, so the command has to exist, print what the
-- engine prints, hand its exit code through and never fail silently (no nvim on the PATH: a message and exit 3).

return function(H)
  local ok, eq = H.ok, H.eq
  local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this))))
  local win = vim.fn.has("win32") == 1

  ---@param path_env string the PATH the launcher sees
  ---@param ... string arguments of `testing`
  ---@return vim.SystemCompleted
  local function launch(path_env, ...)
    local argv = win and { "cmd.exe", "/d", "/c", repo .. "/bin/testing.cmd", ... }
      or { "/bin/sh", repo .. "/bin/testing", ... }
    return vim.system(argv, { text = true, env = { PATH = path_env } }):wait(60000)
  end

  ok(vim.uv.fs_stat(repo .. "/bin/testing") ~= nil, "bin/testing exists")
  ok(vim.uv.fs_stat(repo .. "/bin/testing.cmd") ~= nil, "bin/testing.cmd exists")

  -- with nvim on the PATH: the engine runs, its output and exit code come through (`ci trust` without
  -- arguments is the usage, exit 2, and writes nothing)
  local nvim_dir = vim.fs.dirname(vim.fn.exepath("nvim"))
  local sys_path = os.getenv("PATH") or ""
  local r = launch(nvim_dir .. (win and ";" or ":") .. sys_path, "ci", "trust")
  eq(r.code, 2, "the exit code of the engine is handed through")
  ok(
    (r.stderr or ""):find("testing ci trust: no arguments", 1, true) ~= nil,
    "the engine's message is printed"
  )
  ok((r.stderr or ""):find("usage:", 1, true) ~= nil, "and the usage")

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
  local r2 = launch(bare, "ci", "trust")
  eq(r2.code, 3, "no nvim: exit 3")
  ok((r2.stderr or ""):find("nvim is not on the PATH", 1, true) ~= nil, "no nvim: it says so")
end
