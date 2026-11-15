-- TESTS/testing/watch_support.lua -- helpers for the specs that wait for a file watch (lib.nvim.fs.watch) to report a
-- change they made. Loaded with dofile by the specs; not a spec itself.

local S = {}

---@class Testing.Spec.UntilSeenOpts
---@field total_ms? integer How long at most (default 8000).
---@field again_ms? integer How long one change is waited for before it is made again (default 1000).
---@field wait? fun(ms: integer, cond: fun(): boolean, interval: integer): boolean `vim.wait`, or a stand-in.
---@field now? fun(): integer The clock in milliseconds, or a stand-in.

---Make `change` and wait until `seen()`; the change is made again every `again_ms` while it is not seen, until
---`total_ms`. A watch that was just started is not always armed yet (FSEvents on macOS), and FSEvents coalesces events:
---one change right after `subscribe` was missed in 5 of 8 hosted macOS runs (tree_badges_spec, tree_ci_spec,
---tree_tests_source_spec, 2026-11-15). Waiting longer for that one change does not help; a second change does.
---`change(n)` gets the round (1 first) to make each change differ where that matters.
---@param change fun(n: integer)
---@param seen fun(): boolean
---@param opts? Testing.Spec.UntilSeenOpts
---@return boolean seen
---@return integer rounds How many times the change was made.
function S.until_seen(change, seen, opts)
  opts = opts or {}
  local total = opts.total_ms or 8000
  local again = opts.again_ms or 1000
  local wait = opts.wait or vim.wait
  local now = opts.now or function()
    return math.floor(vim.uv.hrtime() / 1e6)
  end
  local deadline = now() + total
  local n = 1
  change(n)
  while true do
    if wait(math.min(again, math.max(0, deadline - now())), seen, 20) then
      return true, n
    end
    if now() >= deadline then
      return false, n
    end
    n = n + 1
    change(n)
  end
end

return S
