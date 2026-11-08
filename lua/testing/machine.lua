---@module 'testing.machine'
-- @cache-env NVIM_MACHINE_ROLE TESTING_ALLOW_WORKSTATION
---@brief The machine role (`NVIM_MACHINE_ROLE`) and what testing.nvim may do on it: one place for the question.
---@description
--- On the workstation (`NVIM_MACHINE_ROLE=workstation`) nothing unsigned may be built or started (EDR): a pipeline
--- (`testing ci`) builds the repositories' own programs, a run starts child editors and runs the project's code. So
--- only the commands that read are allowed there (`ALLOWED`); everything else is refused with exit code 2 and a
--- message. A role that is neither `workstation`, `default` nor empty is a typo and is refused, as `testing sheets run`
--- refuses it. `TESTING_ALLOW_WORKSTATION=1` lifts the refusal where it is allowed on purpose (the same switch as
--- `testing sheets run`).
---
--- The allowed commands (`docs/CLI.md`, section Workstation): `export`, `call`, `ci remote`, `ci overview`,
--- `ci verify --json`, `lint` without `--fix`, and the help. `sheets run` and `sheets step` pass here and refuse
--- themselves unless every sheet of the run is a manual one (`testing.sheet.run.refused`).

local M = {}

---Environment variable that lifts the refusal.
M.ALLOW_ENV = "TESTING_ALLOW_WORKSTATION"

---Read the environment through this (specs replace it).
---@type fun(name: string): string|nil
M.getenv = function(name)
  return vim.uv.os_getenv(name)
end

---The role of this machine.
---@param getenv? fun(name: string): string|nil
---@return "workstation"|"default"|nil role nil: a value that is neither (a typo)
---@return string|nil problem
function M.role(getenv)
  -- trimmed: `set NVIM_MACHINE_ROLE=workstation ` in cmd keeps the blank (the nvim config's machine.lua trims too)
  local role = vim.trim((getenv or M.getenv)("NVIM_MACHINE_ROLE") or ""):lower()
  if role == "" or role == "default" then
    return "default"
  end
  if role == "workstation" then
    return "workstation"
  end
  return nil,
    ("NVIM_MACHINE_ROLE=%q is neither workstation nor default (a typo?): refused until it is set right"):format(
      role
    )
end

---Whether this machine is the workstation. A typo counts as not decided (nil) with its problem.
---@param getenv? fun(name: string): string|nil
---@return boolean|nil workstation
---@return string|nil problem
function M.is_workstation(getenv)
  local role, problem = M.role(getenv)
  if not role then
    return nil, problem
  end
  return role == "workstation"
end

---The subcommands of `ci` that only read.
local CI_READING = { remote = true, overview = true }

---Whether the arguments of one command line are allowed on the workstation. The command is the first non-option
---argument; the help is allowed.
---@param argv string[]
---@return boolean allowed
---@return string what What was asked for, for the message (`ci`, `run`, ...).
function M.allowed(argv)
  local first = argv[1]
  if first == nil or first == "--help" or first == "-h" or first == "help" then
    return true, "help"
  end
  local has = function(flag)
    for _, a in ipairs(argv) do
      if a == "--" then
        break
      end
      if a == flag or a:sub(1, #flag + 1) == flag .. "=" then
        return true
      end
    end
    return false
  end
  if first == "export" or first == "call" then
    return true, first
  end
  if first == "lint" then
    return not has("--fix"), "lint --fix"
  end
  -- they decide themselves once the sheets are loaded as data: only manual sheets (questions, no process) run there
  -- (`testing.sheet.run.refused`)
  if first == "sheets" and (argv[2] == "run" or argv[2] == "step") then
    return true, "sheets " .. argv[2]
  end
  if first == "ci" then
    local sub = argv[2]
    if sub and CI_READING[sub] then
      return true, "ci " .. sub
    end
    if sub == "verify" then
      return has("--json"), "ci verify without --json"
    end
    if sub == nil or sub:sub(1, 1) == "-" then
      return false, "ci"
    end
    return false, "ci " .. sub
  end
  return false, tostring(first)
end

---The refusal for a command line on this machine, or nil when it may go on.
---@param argv string[] The arguments after `testing`.
---@param getenv? fun(name: string): string|nil
---@return string|nil refusal
function M.refusal(argv, getenv)
  getenv = getenv or M.getenv
  local workstation, problem = M.is_workstation(getenv)
  if workstation == nil then
    return "testing: " .. tostring(problem)
  end
  if not workstation or getenv(M.ALLOW_ENV) == "1" then
    return nil
  end
  local allowed, what = M.allowed(argv)
  if allowed then
    return nil
  end
  return (
    "testing: `%s` is refused on the workstation (NVIM_MACHINE_ROLE=workstation): it builds or starts "
    .. "programs there, and nothing unsigned may run on that machine; allowed: export, call, ci remote, "
    .. "ci overview, ci verify --json, lint (set %s=1 where that is allowed)"
  ):format(what, M.ALLOW_ENV)
end

---The refusal for a run started from the editor (`:Testing ci`), or nil.
---@param what? string
---@param getenv? fun(name: string): string|nil
---@return string|nil refusal
function M.run_refusal(what, getenv)
  return M.refusal({ "ci", what or "run" }, getenv)
end

return M
