---@module 'testing.bindings.trust_prompt'
-- @cache-env CI TESTING_TRUST TESTING_TRUST_ROOTS
---@brief Asks once whether to trust a project root a run from the editor was refused for.
---@description
--- The workspace trust gate (`testing.trust`) ends a run in an untrusted root with exit 2 and a message that
--- contains `trust.REFUSED`. From the command line that is the answer; from the editor (`:Testing <cmd>`,
--- `:Testing ci`) the user is asked once instead: yes stores the root (`trust.add`, the same store
--- `testing trust add <root>` writes) and the caller starts the run again, no leaves the refusal as it is.
--- Without a UI (a headless nvim) nobody can answer: no question, the refusal stands.

local M = {}

M.YES = "Trust it and run again"
M.NO = "Do not trust it"

---Seam for specs: is there a UI that can answer?
---@return boolean
function M.interactive()
  return #vim.api.nvim_list_uis() > 0
end

---Seam for specs: the trust context `trust.add` stores with (nil: the default store).
---@type Testing.Trust.Ctx|nil
M.ctx = nil

---Did the child end with the trust gate's refusal?
---@param code integer|nil
---@param stderr string|nil
---@return boolean
function M.refused(code, stderr)
  return code == 2
    and type(stderr) == "string"
    and stderr:find(require("testing.trust").REFUSED, 1, true) ~= nil
end

---Ask whether to trust `root`. `on_answer(true)` after the root was stored, `on_answer(false)` when there is no UI,
---the user said no or cancelled, or storing failed (then with the reason, which is also notified).
---@param root string
---@param on_answer fun(trusted: boolean, err?: string)
function M.ask(root, on_answer)
  if not M.interactive() then
    on_answer(false)
    return
  end
  vim.ui.select({ M.YES, M.NO }, {
    prompt = ("testing: %s is not trusted; running it executes its .testing.lua, TESTS/minimal_init.lua and specs. Trust it?"):format(
      root
    ),
  }, function(choice)
    if choice ~= M.YES then
      on_answer(false)
      return
    end
    local ok, err = require("testing.trust").add(root, M.ctx)
    if not ok then
      require("testing.notify")
        .get()
        .error("testing: cannot trust " .. root .. ": " .. tostring(err))
      on_answer(false, err)
      return
    end
    on_answer(true)
  end)
end

M.YES_ALL = "Trust them and run"

---The environment that decides the trust gate in a child (`scripts/testing.lua` reads the same three names).
---@return table<string, string|nil>
local function trust_env()
  local env = {}
  for _, name in ipairs({ "CI", "TESTING_TRUST", "TESTING_TRUST_ROOTS" }) do
    env[name] = vim.uv.os_getenv(name)
  end
  return env
end

---The roots of `dirs` the gate would refuse a run in. Never raises: a root that cannot be decided is left out (the
---child says what it says).
---@param dirs string[]
---@return string[]
function M.untrusted(dirs)
  local trust = require("testing.trust")
  local ctx = vim.tbl_extend("force", { env = trust_env() }, M.ctx or {})
  local out = {}
  for _, dir in ipairs(dirs) do
    local ok, d = pcall(trust.decide, dir, ctx)
    if ok and type(d) == "table" and not d.trusted then
      out[#out + 1] = dir
    end
  end
  return out
end

---Ask once for all the roots of a multi-repository run that are not trusted, then `on_done()`. Yes stores them all
---(`trust.add`), no (or no UI, or an escape) leaves them as they are: the run starts anyway, and the child reports an
---untrusted repository as an `error` row, as it does from the command line.
---@param dirs string[] The repositories of the run.
---@param on_done fun(trusted?: string[]) Called once, after the answer.
function M.ask_many(dirs, on_done)
  local pending = M.interactive() and M.untrusted(dirs) or {}
  if #pending == 0 then
    on_done()
    return
  end
  local names = vim.tbl_map(function(d)
    return vim.fs.basename(d)
  end, pending)
  vim.ui.select({ M.YES_ALL, M.NO }, {
    prompt = ("testing: %d of the repositories are not trusted (%s); running them executes their .testing.lua, TESTS/minimal_init.lua and specs. Trust them?"):format(
      #pending,
      #names > 5 and (table.concat(vim.list_slice(names, 1, 5), ", ") .. ", ...")
        or table.concat(names, ", ")
    ),
  }, function(choice)
    if choice ~= M.YES_ALL then
      on_done()
      return
    end
    local stored = {}
    for _, dir in ipairs(pending) do
      local ok, err = require("testing.trust").add(dir, M.ctx)
      if ok then
        stored[#stored + 1] = dir
      else
        require("testing.notify")
          .get()
          .error("testing: cannot trust " .. dir .. ": " .. tostring(err))
      end
    end
    on_done(stored)
  end)
end

return M
