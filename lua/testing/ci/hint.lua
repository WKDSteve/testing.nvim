---@module 'testing.ci.hint'
---@brief The line that points at rule CI-10 while a run waits for the CI: take the next small task instead of waiting.
---@description
--- Shown once by the waiting modes (`testing ci remote --wait` without `--json`, `testing ci land` after its push),
--- never in a document. Off with `TESTING_CI_HINT=0` in the environment or `vim.g.testing_ci_hint = false`.

local M = {}

M.ENV = "TESTING_CI_HINT"

M.LINE = "CI-10: the CI runs, take the next XS/S task meanwhile (`tasks next --actor=cdx --effort=<=S`);"
  .. " off with TESTING_CI_HINT=0"

---Is the line wanted?
---@return boolean
function M.enabled()
  local env = vim.env.TESTING_CI_HINT
  if env ~= nil and vim.trim(env) == "0" then
    return false
  end
  return vim.g.testing_ci_hint ~= false
end

---Say the line through `say` when it is wanted.
---@param say fun(s: string)
function M.say(say)
  if M.enabled() then
    say(M.LINE)
  end
end

return M
