---@module 'testing.ci.wsl'
---@brief `testing ci commit --wsl`: the same check in WSL2, about ten times faster than on Windows.
---@description
--- Measured on 2026-11-09 (testing.nvim, the whole suite without a cache, the same PC): 64 s in WSL2 against about
--- 650 s on Windows. Starting processes, the file system and the virus scanner make Windows slow for a suite whose
--- every spec file starts editors; the Linux kernel in the same machine has none of that.
---
--- From Windows, `ci commit <rev>... --wsl` keeps a mirror below `~/.cache/testing-wsl/` in WSL (the Linux file
--- system: a checkout below `/mnt/c` would be as slow as Windows): the repository and its dependencies are cloned once
--- and fetched from the Windows checkouts each time; the dependencies are checked out at their committed HEAD (their
--- uncommitted changes are not seen). In there the ordinary `testing ci commit` runs with the mirror's testing.nvim,
--- and its document `testing-ci-commit/1` comes back to Windows, where the report is printed as without `--wsl`.
---
--- The Windows process writes the metrics line (`os = "wsl"`); it takes no turn in the queue (a check in WSL takes about
--- a minute and must not wait behind a Windows run of ten); inside WSL queue and metrics are off. What is
--- Windows-specific is checked by the windows leg of the hosted CI, not here.

local M = {}

---The mirror folder inside WSL (`$HOME` there).
M.MIRROR = ".cache/testing-wsl"

---Replaced by a spec: run a bash script in WSL and wait.
---@param script string
---@param timeout_ms integer
---@return integer code
---@return string stdout
---@return string stderr
M.run_bash = function(script, timeout_ms)
  local ok, res = pcall(function()
    -- the script on stdin, not as an argument: the Windows command line rewrites quotes and `$(...)` of one long
    -- argument, and the run in WSL then failed to load its own modules
    return vim
      .system({ "wsl.exe", "-e", "bash", "-s" }, { text = true, stdin = script })
      :wait(timeout_ms)
  end)
  if not ok or not res then
    return 127, "", tostring(res)
  end
  return res.code or 1, res.stdout or "", res.stderr or ""
end

---A Windows path as WSL sees it (`E:/repos/x` -> `/mnt/e/repos/x`).
---@param path string
---@return string
function M.wsl_path(path)
  -- the backslashes by hand: vim.fs.normalize turns them into slashes only on Windows
  local p = vim.fs.normalize((path:gsub("\\", "/")))
  local drive, rest = p:match("^(%a):/(.*)$")
  if drive then
    return ("/mnt/%s/%s"):format(drive:lower(), rest)
  end
  return p
end

---Single-quoted for bash.
---@param s string
---@return string
local function q(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---The bash script that syncs the mirror and runs `ci commit` there.
---@param o { repo: string, root: string, deps: table<string, string>, argv: string[], json: string }
---`repo` the directory name, `root` its Windows path, `deps` name -> Windows path, `argv` the arguments of the inner
---`ci commit`, `json` where the document goes (a Windows path).
---@return string
function M.script(o)
  local lines = {
    "set -u",
    -- tools installed for the user without sudo (stylua, luacheck): a shell started by wsl.exe reads no profile
    'export PATH="$HOME/.local/bin:$PATH"',
    'M="$HOME/' .. M.MIRROR .. '"',
    'mkdir -p "$M"',
    "sync() {",
    '  if [ ! -d "$M/$1/.git" ]; then git -c core.autocrlf=false clone -q "$2" "$M/$1" || return 1; fi',
    -- HEAD too: a detached HEAD of the Windows checkout is on no branch
    '  git -C "$M/$1" -c core.autocrlf=false fetch -q --force "$2" "+refs/heads/*:refs/remotes/win/*" '
      .. '"+HEAD:refs/remotes/win/HEAD" || return 1',
    "}",
    -- HEAD is read BEFORE the fetch: another session committing in between would else name a commit not fetched
    "head_of() {",
    '  h="$(git -C "$2" rev-parse HEAD)" || return 1',
    '  sync "$1" "$2" || return 1',
    '  git -C "$M/$1" -c core.autocrlf=false checkout -q --force --detach "$h" || return 1',
    "}",
  }
  local names = vim.tbl_keys(o.deps)
  table.sort(names)
  for _, name in ipairs(names) do
    local src = M.wsl_path(o.deps[name])
    lines[#lines + 1] = ("head_of %s %s || { echo 'testing: wsl: cannot mirror %s' >&2; exit 3; }"):format(
      q(name),
      q(src),
      name
    )
  end
  -- the repository at the Windows HEAD as well: `--since` and the worktrees start from the mirror's HEAD
  local src = M.wsl_path(o.root)
  lines[#lines + 1] = ("head_of %s %s || { echo 'testing: wsl: cannot mirror %s' >&2; exit 3; }"):format(
    q(o.repo),
    q(src),
    o.repo
  )
  local args = {}
  for _, a in ipairs(o.argv) do
    args[#args + 1] = q(a)
  end
  lines[#lines + 1] = ('cd "$M/%s" || exit 3'):format(o.repo)
  -- the queue and the metrics are the Windows process's; the mirror is the user's own code (trusted)
  -- the options of `ci commit` before the given arguments: after a `--` they would be the suite's
  lines[#lines + 1] = (
    'env -u REPOS_DIR TESTING_QUEUE=off TESTING_METRICS=off TESTING_TRUST=1 REPOS_DIR="$M" '
    .. 'nvim -n -i NONE --headless -u NONE -l "$M/testing.nvim/scripts/testing.lua" ci commit '
    .. '--root=. --no-agent --json="$(wslpath -u %s)" %s'
  ):format(q(o.json), table.concat(args, " "))
  return table.concat(lines, "\n") .. "\n"
end

---Run `ci commit` in WSL and hand back its document.
---@param root string The repository (Windows path).
---@param argv string[] The arguments of the inner `ci commit` (revisions, `--quick`, `-- <suite options>`, ...).
---@param deps table<string, string> name -> Windows path of every dependency, testing.nvim and lib.nvim included.
---@return table|nil doc `testing-ci-commit/1`
---@return string|nil problem
function M.run(root, argv, deps)
  local json = vim.fs.normalize(vim.fn.tempname()) .. "-wsl-commit.json"
  local script = M.script({
    repo = vim.fs.basename(root),
    root = root,
    deps = deps,
    argv = argv,
    json = json,
  })
  local code, _, err = M.run_bash(script, 2 * 60 * 60 * 1000)
  local f = io.open(json, "rb")
  local text = f and f:read("*a")
  if f then
    f:close()
    os.remove(json)
  end
  local ok, doc = pcall(vim.json.decode, text or "")
  if not ok or type(doc) ~= "table" then
    return nil,
      ("the run in WSL left no document (exit %d)%s"):format(
        code,
        err ~= "" and (": " .. vim.trim(err):sub(-600)) or ""
      )
  end
  return doc
end

return M
