---@module 'testing.priority'
-- testing.priority -- heavy runs of the command line start with a low CPU priority, so the self-hosted CI runners on
-- the same machine get the CPU first.
--
-- `from_env` and `decide` take the arguments and the environment as values and are tested with fake ones; only the
-- entry (`scripts/testing.lua`) calls `apply`, a spec or a library call of `cli.main` never changes its priority.

---@brief Lower the priority of a heavy local run (`run`, `ci` with `ci commit`, `sheets run`).
---
--- Under Windows a child process inherits the priority class of its parent only when that is `Idle` or
--- `BelowNormal`; a run whose entry process is `BelowNormal` therefore pulls cargo, rustc, node, Chrome and every
--- Neovim it starts down with it, and the jobs of the runners (`Normal`) get the CPU first. Under Linux and WSL the
--- same value is a nice of 10, which children inherit as well. libuv maps the one value to both
--- (`uv.os_setpriority`, `UV_PRIORITY_BELOW_NORMAL`).
---
--- On by default, never under `CI` (a runner job keeps the priority its runner gave it), off with
--- `TESTING_PRIORITY=normal`. A process that already runs lower (`Idle`, a higher nice) is left as it is.

local M = {}

---The environment variable that switches it: `normal` (or `off`) keeps the priority, anything else lowers it.
M.ENV = "TESTING_PRIORITY"
---libuv's `UV_PRIORITY_BELOW_NORMAL`: `BelowNormal` on Windows, nice 10 on POSIX.
M.BELOW_NORMAL = 10

-- the first words `cli.main` dispatches before it parses the options (testing.cli); every other first word is a
-- subcommand of `testing.args` or, when it is none, the root of a `run`
local DISPATCHED = {
  "act",
  "call",
  "callers",
  "ci",
  "explain",
  "export",
  "history",
  "lint",
  "perf",
  "sheets",
  "stamp",
  "state",
  "stats",
  "status",
  "trust",
  "verify",
}

---The command of a command line as `cli.main` sees it: the first word when it names one, `run` otherwise.
---@param args string[]
---@return string command
---@return string|nil sub the word after it
function M.command(args)
  local first = args[1]
  if
    first
    and (
      vim.tbl_contains(DISPATCHED, first)
      or vim.tbl_contains(require("testing.args").SUBCOMMANDS, first)
    )
  then
    local sub = args[2]
    return first, (sub and sub:sub(1, 1) ~= "-") and sub or nil
  end
  return "run", nil
end

---Whether `args` is a heavy run: a suite (`run`), `ci` (with `ci commit`), `sheets run` or `perf` (not `perf scan`).
---@param args string[]
---@return boolean
function M.heavy(args)
  local cmd, sub = M.command(args)
  if cmd == "ci" then
    return true
  end
  if cmd == "sheets" then
    return sub == "run"
  end
  if cmd == "perf" then
    return sub ~= "scan" and sub ~= "--help" and sub ~= "-h"
  end
  if cmd ~= "run" then
    return false
  end
  -- `--help`, `--list` and `--version` print, they do not run the suite
  for _, a in ipairs(args) do
    if a == "--help" or a == "-h" or a == "--list" or a == "--version" then
      return false
    end
  end
  return true
end

---The priority to set, or nil and why not.
---@param args string[]
---@param lookup fun(name: string): string|nil
---@return integer|nil priority
---@return string|nil why_not
function M.decide(args, lookup)
  local ci = lookup("CI")
  if ci and ci ~= "" and ci ~= "false" and ci ~= "0" then
    return nil, "CI"
  end
  local want = (lookup("TESTING_PRIORITY") or ""):lower()
  if want == "normal" or want == "off" then
    return nil, M.ENV
  end
  if not M.heavy(args) then
    return nil, "light"
  end
  return M.BELOW_NORMAL, nil
end

---Lower this process when `decide` says so; never raises, never raises the priority.
---@param args string[]
---@param lookup fun(name: string): string|nil the entry hands in `os.getenv`; this module never reads the
--- environment itself, so a spec whose closure reaches it keeps its cache key (testing.cache: `env_dynamic`)
---@param uv? table `vim.uv` (a fake in the specs)
---@return boolean lowered
function M.apply(args, lookup, uv)
  uv = uv or vim.uv
  local prio = M.decide(args, lookup)
  if not prio then
    return false
  end
  local ok_get, current = pcall(uv.os_getpriority, 0)
  if ok_get and type(current) == "number" and current >= prio then
    return false
  end
  local ok_set, res = pcall(uv.os_setpriority, 0, prio)
  return ok_set and res == true
end

return M
