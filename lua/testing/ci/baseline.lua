---@module 'testing.ci.baseline'
---@brief The comparison of two `testing-ci/1` runs: which findings are new, known or fixed (pure, no I/O).
---@description
--- `classify(head, base)` compares the run at a commit (`head`) with the run at its base (`base`, nil when there is
--- none) step by step. Only the steps that are red at `head` are compared, and `fixed` covers only those steps (the
--- other steps are not run at the base).
---
--- A finding's key is its step, its file and its text, without line and column (they move between two states), and
--- with every `:<digits>` in the text made `:#` (a message that quotes a position) and the path of a snapshot
--- (`<state>/snap/<sha8>-<random>/tree`, and any path into `testing/snap/<sha8>-<random>`, also cut right after it or
--- written as a Windows or WSL UNC path) made `<snapshot>`. Equal keys count as a multiset: two
--- equal findings at `head` and one at `base` are one known and one new. A red step without findings (an exit code, a
--- crash) is compared as a whole: it is known when the step is red at the base too.
---
--- A spec file of the suite step that is red at `head` and at `base` with another failing check (a flaky suite: the
--- timing hits another case each run) is one known item, not one new and one fixed: what is left unmatched of a spec
--- file at `head` is paired with what is left of the same file at `base`, one with one, and such a known item carries
--- the base's text in `other`. That is weaker evidence than the same text twice and stronger than a regression; the
--- verdict stays `known-red`, the report says "with another failure". A head item of that file without a partner is
--- new: a second failure in a file that was red already is still found.
---
--- When a list of findings was cut (`findings_total` above the number kept), the comparison is not exact: what is
--- left over counts as new (a false alarm rather than a false green) and `exact` is false.

local M = {}

---@class Testing.Ci.Baseline.Item
---@field step string
---@field file? string
---@field spec? string The spec file that reruns a suite finding (`file` can be a helper the assertion sits in).
---@field line? integer
---@field col? integer
---@field text string
---@field whole? boolean The step is red without findings: the item is the step itself.
---@field other? string Known with another failure: the text of the base's finding in the same spec file.

---@class Testing.Ci.Baseline.Result
---@field new Testing.Ci.Baseline.Item[]
---@field known Testing.Ci.Baseline.Item[]
---@field fixed Testing.Ci.Baseline.Item[]
---@field exact boolean False when a cut list made the comparison incomplete.
---@field red_steps string[] The steps red at `head`, in run order.

---@param s any
---@return any
local function nonnil(s)
  if s == vim.NIL then
    return nil
  end
  return s
end

---@param step table A step of `testing-ci/1`.
---@return boolean
function M.is_red(step)
  return step.state ~= "green" and step.state ~= "skipped"
end

---The key of a finding.
---@param step string
---@param f table
---@return string
function M.key(step, f)
  local file = tostring(nonnil(f.file) or ""):gsub("\\", "/")
  local text = vim.trim(tostring(nonnil(f.text) or ""))
  -- the snapshot of each state sits in a directory of its own (`.../snap/<sha8>-<random>/tree`, maybe cut to
  -- `...nap/`), so a path in the text would tell the same finding apart between head and base
  text = text:gsub("[%w%.:_/\\%-]*[/\\]%x%x%x%x%x%x%x%x%-%w+[/\\]tree", "<snapshot>")
  -- a path into the snapshot directory that does not go through `tree` (its `state`, or a message cut right after
  -- `snap/<sha8>-<rand>`), in `/` or `\` form, a Windows or WSL UNC path (`\\wsl.localhost\...`) alike
  text = text
    :gsub("[%w%.:_/\\%-]*[/\\]testing[/\\]snap[/\\]%x%x%x%x%x%x%x%x%-%x*", "<snapshot>")
    :gsub(":%d+", ":#")
  -- so does Neovim's own temp folder (`tempname()`: `.../nvim.<user>/<random>/<n>`), new for every editor
  text = text:gsub("(nvim%.[^/\\%s]*)[/\\]%w+[/\\]%d+", "%1/<tempname>")
  return table.concat({ step, file, text }, "\0")
end

---The items of one step: its findings, or the step itself when it has none.
---@param step table
---@return Testing.Ci.Baseline.Item[] items
---@return boolean cut The list of findings was cut.
local function items_of(step)
  local items = {}
  local findings = type(step.findings) == "table" and step.findings or {}
  for _, f in ipairs(findings) do
    items[#items + 1] = {
      step = step.name,
      file = nonnil(f.file),
      spec = nonnil(f.spec),
      line = nonnil(f.line),
      col = nonnil(f.col),
      text = tostring(nonnil(f.text) or ""),
    }
  end
  if #items == 0 then
    local reason = nonnil(step.reason)
    items[1] = {
      step = step.name,
      text = ("%s%s"):format(step.state or "red", reason and (": " .. tostring(reason)) or ""),
      whole = true,
    }
  end
  local total = tonumber(nonnil(step.findings_total)) or #findings
  return items, total > #findings
end

---@param item Testing.Ci.Baseline.Item
---@return string
local function key_of(item)
  if item.whole then
    return item.step .. "\0<step>"
  end
  return M.key(item.step, item)
end

---The spec file of a suite item (`spec`, else `file`), nil for a whole step.
---@param item Testing.Ci.Baseline.Item
---@return string|nil
local function file_of(item)
  if item.whole then
    return nil
  end
  local f = item.spec or item.file
  return f and tostring(f):gsub("\\", "/") or nil
end

---@param doc table|nil
---@return table<string, table>
local function steps_by_name(doc)
  local by = {}
  for _, s in ipairs(doc and type(doc.steps) == "table" and doc.steps or {}) do
    by[s.name] = s
  end
  return by
end

---Compare the run at a commit with the run at its base.
---@param head table The `testing-ci/1` document at the commit.
---@param base table|nil The `testing-ci/1` document at the base (nil: everything red is new).
---@return Testing.Ci.Baseline.Result
function M.classify(head, base)
  ---@type Testing.Ci.Baseline.Result
  local res = { new = {}, known = {}, fixed = {}, exact = true, red_steps = {} }
  local base_steps = steps_by_name(base)
  for _, hs in ipairs(type(head.steps) == "table" and head.steps or {}) do
    if M.is_red(hs) then
      res.red_steps[#res.red_steps + 1] = hs.name
      local h_items, h_cut = items_of(hs)
      local bs = base_steps[hs.name]
      -- the base's items of this step, counted by key
      local pool, b_items = {}, {}
      if bs and M.is_red(bs) then
        local cut
        b_items, cut = items_of(bs)
        if cut then
          res.exact = false
        end
        for _, it in ipairs(b_items) do
          local k = key_of(it)
          pool[k] = (pool[k] or 0) + 1
        end
      end
      if h_cut then
        res.exact = false
      end
      local unmatched = {}
      for _, it in ipairs(h_items) do
        local k = key_of(it)
        if (pool[k] or 0) > 0 then
          pool[k] = pool[k] - 1
          res.known[#res.known + 1] = it
        else
          unmatched[#unmatched + 1] = it
        end
      end
      -- the suite: a spec file red at both ends with other checks is the same red file (see the description)
      local partners = {}
      if hs.name == "suite" then
        for _, it in ipairs(b_items) do
          local k, f = key_of(it), file_of(it)
          if f and (pool[k] or 0) > 0 then
            pool[k] = pool[k] - 1
            partners[f] = partners[f] or {}
            table.insert(partners[f], it)
          end
        end
      end
      for _, it in ipairs(unmatched) do
        local f = file_of(it)
        local p = f and partners[f] and table.remove(partners[f], 1)
        if p then
          it.other = p.text
          res.known[#res.known + 1] = it
        else
          res.new[#res.new + 1] = it
        end
      end
      -- a base item that found no partner goes back to the pool: it is fixed
      for _, list in pairs(partners) do
        for _, it in ipairs(list) do
          local k = key_of(it)
          pool[k] = (pool[k] or 0) + 1
        end
      end
      -- what is left of the base is fixed (not when the head's list was cut: the rest may be in its tail)
      if not h_cut then
        for _, it in ipairs(b_items) do
          local k = key_of(it)
          if (pool[k] or 0) > 0 then
            pool[k] = pool[k] - 1
            res.fixed[#res.fixed + 1] = it
          end
        end
      end
    end
  end
  return res
end

---Count items per step, in the order the steps first appear: `{ { step = "luacheck", n = 2 }, ... }`.
---@param items Testing.Ci.Baseline.Item[]
---@return { step: string, n: integer }[]
function M.by_step(items)
  local out, at = {}, {}
  for _, it in ipairs(items) do
    if not at[it.step] then
      out[#out + 1] = { step = it.step, n = 0 }
      at[it.step] = #out
    end
    out[at[it.step]].n = out[at[it.step]].n + 1
  end
  return out
end

return M
