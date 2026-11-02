---@module 'testing.migrate.branches'
---@brief Does a dependency repository have a `ci-verified` branch? One `git ls-remote`, never fatal.
---@description
--- The CI checkout the migration writes names `ref: ci-verified` for every dependency. A repository
--- that has only `main` (color_my_ascii.nvim) would fail its first CI run on that ref, so the plan asks
--- first. The question is a seam (`Testing.Migrate.PlanOpts.branch_exists`): specs never touch the
--- network, the command line uses `M.exists`.
---
---   git ls-remote --exit-code --heads https://github.com/<owner>/<repo> refs/heads/ci-verified
---
--- The ref is spelled out: git matches a short pattern against the end of every ref name, so `ci-verified` alone
--- would also find `release/ci-verified`.
---
--- Exit 0: the branch exists. Exit 2 (`--exit-code`: no matching ref): it does not. Anything else
--- (no network, no git, a private repository, a timeout) is "unknown": the caller keeps `ci-verified`
--- and says so in a note. An answer is cached per repository for the process. `M.exists` waits for its answer (the
--- command line); the editor asks all dependencies at once in the background first (`M.prefetch`, parallel, one
--- timeout at most) and builds the plan from the cache. After a TIMEOUT the rest is not asked at all: a network that
--- drops packets would otherwise cost the full timeout per dependency. That holds for one run of the migration: `:Testing migrate` lives in the editor for hours,
--- so `begin_run` (called by `migrate.run`) forgets the timeout and every answer that was none, and the next
--- run asks again once the network is back.

local M = {}

---Milliseconds one `git ls-remote` may take.
---@type integer
M.TIMEOUT_MS = 15000

---@type table<string, { [1]: boolean|nil, [2]: string|nil }>
local cache = {}

---Set by the first question that ran into the timeout: why nothing is asked any more.
---@type string|nil
local gave_up

---The command line of the question.
---@param owner string
---@param repo string
---@param branch string
---@return string[]
local function ls_remote_argv(owner, repo, branch)
  -- a short pattern is matched against the END of a ref name: `ci-verified` finds `release/ci-verified`, too
  local ref = branch:find("^refs/") and branch or ("refs/heads/" .. branch)
  return {
    "git",
    "ls-remote",
    "--exit-code",
    "--heads",
    ("https://github.com/%s/%s"):format(owner, repo),
    ref,
  }
end

---What the answer of `git ls-remote` means.
---@param ok boolean Whether the call itself ran (a `pcall`).
---@param res any The result of `vim.system(...):wait()`, or the error.
---@return boolean|nil exists
---@return string|nil err
---@return boolean timed_out No answer in time: the caller stops asking.
local function classify(ok, res)
  if not ok then
    return nil, tostring(res):match("^[^\n]*"), false
  end
  if type(res) ~= "table" or res.code == 124 then
    -- no answer in time (nil: the process was killed and a child of it held its pipes open; 124: the code
    -- Neovim gives a command it had to kill)
    return nil, ("git ls-remote did not answer within %d ms"):format(M.TIMEOUT_MS), true
  end
  if res.code == 0 then
    return true, nil, false
  elseif res.code == 2 then
    return false, nil, false
  end
  return nil,
    ("git ls-remote exited with %s: %s"):format(
      tostring(res.code),
      (res.stderr or ""):match("^[^\n]*") or ""
    ),
    false
end

---Ask GitHub. Needs `git` on PATH and network access.
---@param owner string
---@param repo string
---@param branch? string Default `ci-verified`.
---@return boolean|nil exists nil when the answer could not be obtained.
---@return string|nil err Why it could not.
function M.exists(owner, repo, branch)
  branch = branch or "ci-verified"
  local key = ("%s/%s#%s"):format(owner, repo, branch)
  local hit = cache[key]
  if hit then
    return hit[1], hit[2]
  end
  if gave_up then
    return nil, gave_up
  end
  local argv = ls_remote_argv(owner, repo, branch)
  local ok, res = pcall(function()
    return vim
      .system(argv, { text = true, timeout = M.TIMEOUT_MS, env = { GIT_TERMINAL_PROMPT = "0" } })
      :wait(M.TIMEOUT_MS + 1000)
  end)
  local exists, err, timed_out = classify(ok, res)
  if timed_out then
    gave_up = ("%s; not asking again in this run"):format(err)
  end
  cache[key] = { exists, err }
  return exists, err
end

---Ask for several repositories at once, in parallel and without waiting, so the editor stays usable and the whole
---costs one timeout at most. Fills the same cache `M.exists` reads; `done` runs (scheduled) when every answer is in.
---Repositories that are cached are not asked again, and after a run that gave up nothing is asked.
---@param wanted { [1]: string, [2]: string }[] `{ owner, repo }` pairs (the branch is `ci-verified`).
---@param done fun()
function M.prefetch(wanted, done)
  local todo, seen = {}, {}
  for _, w in ipairs(wanted) do
    local key = ("%s/%s#%s"):format(w[1], w[2], "ci-verified")
    if not seen[key] and not cache[key] then
      seen[key] = true
      todo[#todo + 1] = { key = key, owner = w[1], repo = w[2] }
    end
  end
  if gave_up or #todo == 0 then
    return done()
  end
  local pending = #todo
  local function answered()
    pending = pending - 1
    if pending == 0 then
      done()
    end
  end
  for _, q in ipairs(todo) do
    local started, handle_err = pcall(
      vim.system,
      ls_remote_argv(q.owner, q.repo, "ci-verified"),
      { text = true, timeout = M.TIMEOUT_MS, env = { GIT_TERMINAL_PROMPT = "0" } },
      function(res)
        vim.schedule(function()
          local exists, err, timed_out = classify(true, res)
          if timed_out then
            gave_up = ("%s; not asking again in this run"):format(err)
          end
          cache[q.key] = { exists, err }
          answered()
        end)
      end
    )
    if not started then
      cache[q.key] = { nil, tostring(handle_err):match("^[^\n]*") }
      answered()
    end
  end
end

---A new run of the migration starts: the timeout that ended the asking and the answers that were none ("unknown")
---are forgotten, the ones that say that the branch is there or not stay (the process may know them for good).
function M.begin_run()
  gave_up = nil
  for key, hit in pairs(cache) do
    if hit[1] == nil then
      cache[key] = nil
    end
  end
end

---Forget every cached answer (specs).
function M.reset()
  cache = {}
  gave_up = nil
end

return M
