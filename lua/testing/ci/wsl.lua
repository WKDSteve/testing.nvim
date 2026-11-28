-- @cache-allow outside
-- (the absolute paths here, below `/proc` among them, are read by the bash in WSL; this process never reads them)
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
  local err, pending = {}, ""
  local ok, res = pcall(function()
    -- the script on stdin, not as an argument: the Windows command line rewrites quotes and `$(...)` of one long
    -- argument, and the run in WSL then failed to load its own modules
    return vim
      .system({ "wsl.exe", "-e", "bash", "-s" }, {
        text = true,
        stdin = script,
        stderr = function(_, data)
          if not data then
            return
          end
          err[#err + 1] = data
          pending = M.forward_waiting(pending .. data, io.stderr)
        end,
      })
      :wait(timeout_ms)
  end)
  if not ok or not res then
    return 127, "", tostring(res)
  end
  return res.code or 1, res.stdout or "", table.concat(err)
end

---Hand the lines of the run's stderr that say it waits for the mirror lock (`M.lock_lines`) to `out` now, not when the
---run is over: a wait of an hour must be visible while it lasts. The unfinished last line is returned (to be continued
---by the next chunk).
---@param text string
---@param out { write: fun(self: any, s: string) }
---@return string rest
function M.forward_waiting(text, out)
  local rest = text
  for line, after in text:gmatch("([^\n]*)\n()") do
    if line:find("testing: wsl: waiting for the mirror lock", 1, true) then
      out:write(line .. "\n")
    end
    rest = text:sub(after)
  end
  return rest
end

---Replaced by a spec: git in a Windows checkout; its trimmed stdout, nil when it failed.
---@param dir string
---@param args string[]
---@return string|nil
M.git = function(dir, args)
  local ok, res = pcall(function()
    return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait(30000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or "")
end

---A linked worktree (`git worktree add`): its `.git` is a file naming the Windows path of the shared repository,
---which git in WSL cannot follow. The mirror then fetches from the shared repository itself, at the worktree's HEAD
---(read here, before the fetch). nil for an ordinary checkout or when git cannot tell.
---@param path string Windows path of the checkout.
---@return { src: string, head: string }|nil
function M.worktree_of(path)
  local out =
    M.git(path, { "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "HEAD" })
  local l = vim.split(out or "", "\n", { plain = true })
  local gitdir, common, head = l[1], l[2], l[3]
  if not (gitdir and common and head and head:match("^%x+$")) then
    return nil
  end
  local function key(p)
    return vim.fs.normalize((p:gsub("\\", "/"))):lower()
  end
  if key(gitdir) == key(common) then
    return nil
  end
  return { src = vim.fs.normalize((common:gsub("\\", "/"))), head = head }
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

---Seconds a run waits for the mirror lock before it names the holder (and waits on); a spec sets it lower.
M.LOCK_WAIT_S = 60

---The lines that take the mirror lock (`$M/.lock`, fd 9) and clean up behind the run: `$M` is set before them.
---
---The lock is held by this shell alone. Every command started under it gets `9>&-` (`M.run_line`, the mirror calls):
---a child that inherited fd 9 would hold the lock as long as it lives, and on 2026-11-22 one orphaned, stopped sheet
---child (a detached `nvim --embed`, out of reach of any process-group kill) held it for an hour while every `--wsl`
---check of every session waited in `flock 9`.
---
---Every process of a run carries `TESTING_WSL_RUN=$M` in its environment (detached children inherit it too). With the
---lock taken, no other run of this mirror is alive, so a process that still carries the marker is an orphan of an
---earlier run (one whose shell was killed before its exit trap ran): it is ended (`SIGCONT`, `SIGKILL`) before
---anything is checked out, and the run's own leftovers are ended the same way when the shell exits.
---
---Waiting longer than `M.LOCK_WAIT_S` names the holder on stderr (every process with the lock file open that is not
---a waiting check, with pid, state and command line; the waiting checks are counted) and waits on.
---@return string[]
function M.lock_lines()
  return {
    -- only while this shell holds the lock: without flock another check of the mirror may be running, and what carries
    -- the marker may be its
    "testing_wsl_locked=0",
    "testing_wsl_sweep() {",
    '  [ "$testing_wsl_locked" = 1 ] || return 0',
    -- one grep over every environment (NUL-separated entries), not a process per process
    '  for e in $(grep -lzxF "TESTING_WSL_RUN=$M" /proc/[0-9]*/environ 2>/dev/null); do',
    '    p="${e#/proc/}"; p="${p%/environ}"',
    '    [ "$p" = "$$" ] && continue',
    '    kill -CONT "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null',
    "  done",
    "}",
    -- the holder from the fd tables, not /proc/locks: the lock is taken by the flock program, which has ended since,
    -- and a lock of a pid that is gone is not listed there. A check that waits has fd 9 too (and so has its flock
    -- child): it says so with `$M/.wait.<pid>` while it waits, and is counted, not named.
    "testing_wsl_holder() {",
    '  h=""; w=0; seen=" "',
    -- one find over every fd table, not a readlink per descriptor
    '  for f in $(find /proc/[0-9]*/fd -maxdepth 1 -lname "$M/.lock" 2>/dev/null); do',
    '    p="${f#/proc/}"; p="${p%%/*}"',
    '    case "$seen" in *" $p "*) continue;; esac',
    '    seen="$seen$p "',
    '    [ "$p" = "$$" ] && continue',
    '    [ "$(ps -o comm= -p "$p" 2>/dev/null)" = flock ] && continue',
    '    if [ -e "$M/.wait.$p" ]; then w=$((w + 1)); continue; fi',
    '    s="$(ps -o pid=,stat=,args= -p "$p" 2>/dev/null | cut -c1-200)"',
    '    [ -n "$s" ] && h="$h${h:+; }$s"',
    "  done",
    '  echo "testing: wsl: waiting for the mirror lock $M/.lock ('
      .. M.LOCK_WAIT_S
      .. ' s), held by: ${h:-?} ($w other check(s) waiting)" >&2',
    "}",
    "if command -v flock >/dev/null 2>&1; then",
    '  exec 9>"$M/.lock"',
    "  trap 'rm -f \"$M/.wait.$$\"' EXIT",
    '  : > "$M/.wait.$$"',
    "  until flock -w " .. M.LOCK_WAIT_S .. " 9; do testing_wsl_holder; done",
    '  rm -f "$M/.wait.$$"',
    -- the note of a check killed while it waited: its pid may be the holder's one day, which would then be counted
    -- instead of named
    '  for f in "$M"/.wait.*; do [ -e "$f" ] && [ ! -d "/proc/${f##*.}" ] && rm -f "$f"; done',
    "  testing_wsl_locked=1",
    "fi",
    "testing_wsl_sweep",
    "trap testing_wsl_sweep EXIT",
    "trap 'exit 129' HUP",
    "trap 'exit 130' INT",
    "trap 'exit 143' TERM",
  }
end

---A command run under the lock: marked as the run's (`TESTING_WSL_RUN`) and without fd 9 (see `M.lock_lines`).
---@param cmd string
---@return string
function M.run_line(cmd)
  return ('env TESTING_WSL_RUN="$M" %s 9>&-'):format(cmd)
end

---The bash script that syncs the mirror and runs `ci commit` there.
---@param o { repo: string, root: string, deps: table<string, string>, argv: string[], json: string, worktrees?: table<string, { src: string, head: string }> }
---`repo` the directory name, `root` its Windows path, `deps` name -> Windows path, `argv` the arguments of the inner
---`ci commit`, `json` where the document goes (a Windows path), `worktrees` name -> `M.worktree_of` of the checkouts
---that are linked worktrees.
---@return string
function M.script(o)
  local worktrees = o.worktrees or {}
  local lines = {
    "set -u",
    -- tools installed for the user without sudo (stylua, luacheck): a shell started by wsl.exe reads no profile
    'export PATH="$HOME/.local/bin:$PATH"',
    'M="$HOME/' .. M.MIRROR .. '"',
    'mkdir -p "$M"',
  }
  -- one check at a time per mirror: a second one would check the dependencies out under the running suite
  vim.list_extend(lines, M.lock_lines())
  vim.list_extend(lines, {
    "fetch_win() {",
    -- HEAD too: a detached HEAD of the Windows checkout is on no branch
    '  git -C "$M/$1" -c core.autocrlf=false fetch -q --force "$2" "+refs/heads/*:refs/remotes/win/*" '
      .. '"+HEAD:refs/remotes/win/HEAD"',
    "}",
    "sync() {",
    '  if [ ! -d "$M/$1/.git" ]; then git -c core.autocrlf=false clone -q "$2" "$M/$1" || return 1; fi',
    -- a mirror that cannot fetch (seen: "possible repository corruption" of fzf-lua, 2026-11-25) is cloned again,
    -- not left to end every check with "cannot mirror"; it is a cache of the Windows checkout, nothing is lost
    '  fetch_win "$1" "$2" && return 0',
    '  echo "testing: wsl: the mirror of $1 could not fetch: cloned again" >&2',
    '  rm -rf "$M/$1" && git -c core.autocrlf=false clone -q "$2" "$M/$1" && fetch_win "$1" "$2" || return 1',
    "}",
    -- HEAD is read BEFORE the fetch: another session committing in between would else name a commit not fetched
    "head_of() {",
    '  h="$(git -C "$2" rev-parse HEAD)" || return 1',
    '  sync "$1" "$2" || return 1',
    '  git -C "$M/$1" -c core.autocrlf=false checkout -q --force --detach "$h" || return 1',
    "}",
    -- a linked worktree: the shared repository as the source, the HEAD the Windows side read (a commit on no
    -- branch is fetched by its id)
    "head_at() {",
    '  sync "$1" "$2" || return 1',
    '  git -C "$M/$1" cat-file -e "$3^{commit}" 2>/dev/null '
      .. '|| git -C "$M/$1" -c core.autocrlf=false fetch -q "$2" "$3" || return 1',
    '  git -C "$M/$1" -c core.autocrlf=false checkout -q --force --detach "$3" || return 1',
    "}",
  })
  ---@param name string
  ---@param path string Windows path of the checkout.
  local function mirror(name, path)
    local wt = worktrees[name]
    local fail = ("{ echo 'testing: wsl: cannot mirror %s' >&2; exit 3; }"):format(name)
    -- `9>&-`: git may leave a background `gc --auto` behind, which must not hold the lock
    if not wt then
      lines[#lines + 1] = ("head_of %s %s 9>&- || %s"):format(q(name), q(M.wsl_path(path)), fail)
      return
    end
    local src = M.wsl_path(wt.src)
    lines[#lines + 1] = ("[ -d %s ] || { echo %s >&2; exit 3; }"):format(
      q(src),
      q(("testing: wsl: %s is a worktree of %s, which WSL cannot reach"):format(name, wt.src))
    )
    lines[#lines + 1] = ("head_at %s %s %s 9>&- || %s"):format(q(name), q(src), q(wt.head), fail)
  end
  local names = vim.tbl_keys(o.deps)
  table.sort(names)
  for _, name in ipairs(names) do
    mirror(name, o.deps[name])
  end
  -- the repository at the Windows HEAD as well: `--since` and the worktrees start from the mirror's HEAD
  mirror(o.repo, o.root)
  local args = {}
  for _, a in ipairs(o.argv) do
    args[#args + 1] = q(a)
  end
  lines[#lines + 1] = ('cd "$M/%s" || exit 3'):format(o.repo)
  -- the queue and the metrics are the Windows process's, and so is the export the hubs read: written from in here it
  -- would see only the WSL state (a handful of runs, no cases) and replace the full export of Windows (WSLENV can
  -- hand the variables down); the Windows process exports after the check, from its own state
  -- the mirror is the user's own code (trusted)
  -- the options of `ci commit` before the given arguments: after a `--` they would be the suite's
  -- a configuration of its own: the runner (`-u NONE` keeps stdpath("config") on the runtimepath) must not see the
  -- user's nvim configuration of the distribution, whose `lua/lib` shadowed lib.nvim's `lib` in specs that run in it
  lines[#lines + 1] = 'mkdir -p "$M/.xdg-config"'
  -- no `exec`: the shell holds the lock and ends what the run left behind (`M.lock_lines`)
  lines[#lines + 1] = M.run_line(
    (
      'env -u REPOS_DIR -u TESTING_EXPORT_DIR -u TESTING_EXPORT_REPOS_ROOT TESTING_QUEUE=off TESTING_METRICS=off TESTING_TRUST=1 REPOS_DIR="$M" XDG_CONFIG_HOME="$M/.xdg-config" '
      .. 'nvim -n -i NONE --headless -u NONE -l "$M/testing.nvim/scripts/testing.lua" ci commit '
      .. '--root=. --no-agent --json="$(wslpath -u %s)" %s'
    ):format(q(o.json), table.concat(args, " "))
  )
  return table.concat(lines, "\n") .. "\n"
end

---The refs a dependency is compared with, the first that exists: what the hosted CI takes (`ci-verified`), else main.
M.UPSTREAM_REFS = { "origin/ci-verified", "origin/main" }

---Which dependency checkouts stand behind what the hosted CI takes? The mirror follows the HEAD of the Windows checkout,
---so a checkout nobody pulled runs the check with an old dependency, and a finding fixed there looks like a regression.
---Only local refs (as last fetched), no network.
---@param deps table<string, string> name -> Windows path of the checkout.
---@return string[] lines One per checkout that lies behind, sorted by name.
function M.behind(deps)
  local function git(dir, ...)
    local argv = { "git", "-C", dir, ... }
    local ok, res = pcall(function()
      return vim.system(argv, { text = true }):wait(10000)
    end)
    if not ok or not res or res.code ~= 0 then
      return nil
    end
    return vim.trim(res.stdout or "")
  end
  local names = vim.tbl_keys(deps)
  table.sort(names)
  local lines = {}
  for _, name in ipairs(names) do
    local dir = deps[name]
    local head = git(dir, "rev-parse", "HEAD")
    for _, ref in ipairs(head and M.UPSTREAM_REFS or {}) do
      local tip = git(dir, "rev-parse", "--verify", "--quiet", ref .. "^{commit}")
      if tip and tip ~= "" then
        -- behind: HEAD is an ancestor of the tip; a checkout with commits of its own ahead is not ours to judge
        if tip ~= head and git(dir, "merge-base", "--is-ancestor", head, tip) then
          local n = git(dir, "rev-list", "--count", head .. ".." .. tip) or "?"
          lines[#lines + 1] = (
            "testing: wsl: %s is %s commit(s) behind %s (%s at %s, the checkout at %s): the run uses the old one; "
            .. "git -C %s pull brings it up"
          ):format(name, n, ref, ref, tip:sub(1, 7), head:sub(1, 7), dir)
        end
        break
      end
    end
  end
  return lines
end

---Run `ci commit` in WSL and hand back its document.
---@param root string The repository (Windows path).
---@param argv string[] The arguments of the inner `ci commit` (revisions, `--quick`, `-- <suite options>`, ...).
---@param deps table<string, string> name -> Windows path of every dependency, testing.nvim and lib.nvim included.
---@return table|nil doc `testing-ci-commit/1`
---@return string|nil problem
function M.run(root, argv, deps)
  local json = vim.fs.normalize(vim.fn.tempname()) .. "-wsl-commit.json"
  local repo = vim.fs.basename(root)
  local worktrees = {}
  for name, path in pairs(vim.tbl_extend("force", deps, { [repo] = root })) do
    worktrees[name] = M.worktree_of(path)
  end
  local script = M.script({
    repo = repo,
    root = root,
    deps = deps,
    argv = argv,
    json = json,
    worktrees = worktrees,
  })
  -- before the run: a stale dependency is named first, not found later behind a REGRESSION
  for _, line in ipairs(M.behind(deps)) do
    io.stderr:write(line .. "\n")
  end
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
