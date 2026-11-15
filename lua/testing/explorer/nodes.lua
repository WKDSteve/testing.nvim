---@module 'testing.explorer.nodes'
---@brief The last result of a project as tree nodes: folder, spec file, describe, case.
---@description
--- A pure module: a list of cases (what `testing.state` holds), the spec files there are and which of them
--- changed since their result go in, a root node in the shape of `lib.nvim.tree` comes out. No file is read, no
--- window touched; folding, flattening and drawing are the tree's.
---
---   Tests
---     TESTS                 dir       `path`
---       parser_spec.lua     file      `path`
---         parser            describe
---           reads a list    case      `path`, `data.lnum`, `status`
---
--- **One case, one status.** Only a case carries `status`; the tree adds the statuses up (`M.SEVERITY`,
--- `M.aggregate`). A spec file that is one case (the `return function(H)` dialects) is the case itself, and when it
--- is red its failing assertions stand below it, each with its line. A case in a describe is a leaf: what it said
--- is its preview.
---
--- **What a branch shows** is written on the node, because a tree draws `icon`, `hl` and `columns` and not the
--- status it added up: the sign of the worst case below, `red/all` (or `all`) and the time. `M.restyle` writes it
--- again after a case changed.
---
--- **Stale.** A case of a file that changed since its result is shown as `stale`, unless it is red: an old red is
--- still worth a look, an old green is no green. What the run said stays in `data.testing.recorded`.
---
--- **Ids are stable**: `tests:case:<case id>`, `tests:file:<file>`, so a node that is there again after a run
--- keeps its place and its open state.

local M = {}

--- Worst first: what a folder of mixed results shows. `skip` ranks above the greens, so a folder of green and
--- skipped cases is not green.
---@type string[]
M.SEVERITY = {
  "crash",
  "error",
  "timeout",
  "fail",
  "xpass",
  "running",
  "queued",
  "stale",
  "never",
  "skip",
  "xfail",
  "pass",
}

---@type table<string, integer>  status -> rank, higher is worse
local RANK = {}
for i, status in ipairs(M.SEVERITY) do
  RANK[status] = #M.SEVERITY - i + 1
end

--- Statuses that make a run red.
---@type table<string, true>
M.RED = { crash = true, error = true, timeout = true, fail = true, xpass = true }
--- Statuses that count as green.
---@type table<string, true>
M.GREEN = { pass = true, xfail = true }

---@type table<string, { icon: string, hl: string }>
local LOOK = {
  crash = { icon = "✗", hl = "DiagnosticError" },
  error = { icon = "✗", hl = "DiagnosticError" },
  timeout = { icon = "✗", hl = "DiagnosticError" },
  fail = { icon = "✗", hl = "DiagnosticError" },
  xpass = { icon = "✗", hl = "DiagnosticError" },
  running = { icon = "●", hl = "DiagnosticInfo" },
  queued = { icon = "◌", hl = "DiagnosticInfo" },
  stale = { icon = "~", hl = "Comment" },
  never = { icon = "·", hl = "Comment" },
  skip = { icon = "○", hl = "DiagnosticWarn" },
  xfail = { icon = "✓", hl = "DiagnosticOk" },
  pass = { icon = "✓", hl = "DiagnosticOk" },
}
--- A status this module does not know: never drawn as green.
local UNKNOWN = { icon = "?", hl = "DiagnosticWarn" }

---The sign and highlight group of a status.
---@param status string|nil
---@return { icon: string, hl: string }
function M.look(status)
  return LOOK[status] or UNKNOWN
end

---The worse of two statuses (nil: no status). A status that is not in `M.SEVERITY` is worse than a green one.
---@param a string|nil
---@param b string|nil
---@return string|nil
function M.worse(a, b)
  if a == nil then
    return b
  end
  if b == nil then
    return a
  end
  local ra, rb = RANK[a] or RANK.skip, RANK[b] or RANK.skip
  return rb > ra and b or a
end

---A duration for a column: `7ms`, `1.4s`, `2m05s`.
---@param ms number
---@return string
function M.duration(ms)
  if ms < 1000 then
    return ("%dms"):format(math.floor(ms + 0.5))
  end
  if ms < 60000 then
    return ("%.1fs"):format(ms / 1000)
  end
  local s = math.floor(ms / 1000 + 0.5)
  return ("%dm%02ds"):format(math.floor(s / 60), s % 60)
end

---@class Testing.Explorer.Data  `node.data.testing`: what an action needs to know about a node.
---@field kind "root"|"dir"|"file"|"describe"|"case"|"assert"|"ci"|"ci_step"|"ci_finding"
---@field profile? string  Pipeline profile (the nodes of `testing.explorer.ci`).
---@field step? string  Pipeline step.
---@field verdict? string
---@field time? string
---@field file? string  Spec file, relative to the project root (a folder for `dir`).
---@field case? string  Case id (a case, also a spec file that is one case).
---@field sole? boolean  The one spec folder of the project: it starts open.
---@field describe? string[]  The describe titles above and including a describe node.
---@field recorded? string  The status the run recorded (the shown one may be `stale`).
---@field message? string
---@field expected? string
---@field actual? string
---@field fails? Testing.State.Fail[]
---@field fails_total? integer
---@field duration_ms? number

---@class Testing.Explorer.Input
---@field root string  Absolute project root, `/`-separated.
---@field cases Testing.State.Case[]
---@field stale? table<string, true>  Spec files (relative) whose result is older than the file.
---@field live? table<string, string>  Case id -> the status to show instead of the recorded one (`running`, `queued`) while a run is going.
---@field files? string[]  Spec files there are (relative), whether they ran or not.
---@field positions? fun(file: string): Testing.Position[]|nil  The describe/it calls of a spec file that never ran; asked when its node is opened.
---@field first? table[]  Nodes that stand before the folders (the pipeline of `testing.explorer.ci`).

---One spelling for a path, the one a tree asks with: `/`-separated, drive letter upper case.
---@param path string
---@return string
function M.norm(path)
  path = path:gsub("\\", "/")
  path = path:gsub("^(%a):", function(drive)
    return drive:upper() .. ":"
  end)
  return path
end

---@param node table
---@return Testing.Explorer.Data|nil
function M.data(node)
  local data = type(node) == "table" and type(node.data) == "table" and node.data.testing or nil
  return type(data) == "table" and data or nil
end

local restyle, leaf_sum, style

---Whether a node is one unit for the adding up: a case or a pipeline step. It counts once, whatever is below it.
---@param data Testing.Explorer.Data|nil
---@return boolean
local function is_unit(data)
  return data ~= nil and (data.case ~= nil or data.kind == "ci_step")
end

---Whether a node is a detail of a unit (a failing assertion, a finding of a step): it counts nothing and shows
---no sign of its own.
---@param data Testing.Explorer.Data|nil
---@return boolean
local function is_detail(data)
  return data ~= nil and (data.kind == "assert" or data.kind == "ci_finding")
end

---Write on `node` what it shows: its own status for a case, else the worst below it with `red/all` and the time.
---Recurses into child lists; a node whose children are not loaded yet keeps the status it carries.
---@param node table
---@return { worst: string|nil, total: integer, red: integer, ms: number }
function M.restyle(node)
  return restyle(node, nil)
end

---@class Testing.Explorer.Index  What `M.set_many` needs to change cases of a built tree without walking it.
---@field top table
---@field by_case table<string, table>  case id -> its node
---@field by_file table<string, table>  spec file -> its node
---@field parent table<table, table>
---@field depth table<table, integer>
---@field sums table<table, { worst: string|nil, total: integer, red: integer, ms: number }>

---Index a built tree (the lists only: children that are not loaded yet are not in it).
---@param top table
---@return Testing.Explorer.Index
function M.index(top)
  local index = { top = top, by_case = {}, by_file = {}, parent = {}, depth = {}, sums = {} }
  local function walk(node, parent, depth)
    index.parent[node], index.depth[node] = parent, depth
    local data = M.data(node)
    if data and data.case and data.kind ~= "assert" then
      index.by_case[data.case] = node
    end
    if data and data.kind == "file" and data.file then
      index.by_file[data.file] = node
    end
    if type(node.children) == "table" then
      for _, child in ipairs(node.children) do
        walk(child, node, depth + 1)
      end
    end
  end
  walk(top, nil, 0)
  restyle(top, index.sums)
  return index
end

---@class Testing.Explorer.Change
---@field id? string  Case id.
---@field file? string  Spec file: the change is for its node (a file that is one case, or one whose cases are not loaded).
---@field status string
---@field duration_ms? number

---Change the status of cases and write again what they and everything above them show. The cost is the depth of
---each case times the children on the way up, not the size of the tree.
---@param index Testing.Explorer.Index
---@param changes Testing.Explorer.Change[]
---@return table[] updates  One `{ id, status, icon, hl, columns }` per node that looks different now, deepest first: what `emit.push` takes.
function M.set_many(index, changes)
  local dirty, order = {}, {}
  local function mark(node)
    if not dirty[node] then
      dirty[node] = true
      order[#order + 1] = node
    end
  end
  for _, change in ipairs(changes) do
    local node = change.id and index.by_case[change.id] or nil
    if not node and change.file then
      local file = index.by_file[change.file]
      -- the node of the file stands for its cases only while it has none of its own in the tree
      if file and type(file.children) ~= "table" or (file and M.data(file).case) then
        node = file
      end
    end
    if node then
      node.status = change.status
      local data = M.data(node)
      if data and change.duration_ms then
        data.duration_ms = change.duration_ms
      end
      local up = node
      while up do
        mark(up)
        up = index.parent[up]
      end
    end
  end
  table.sort(order, function(a, b)
    return index.depth[a] > index.depth[b]
  end)
  local updates = {}
  for _, node in ipairs(order) do
    local data = M.data(node)
    local is_case = is_unit(data)
    local sum
    if is_case or type(node.children) ~= "table" then
      sum = leaf_sum(node)
    else
      sum = { worst = nil, total = 0, red = 0, ms = 0 }
      for _, child in ipairs(node.children) do
        local below = index.sums[child]
        if below then
          sum.worst = M.worse(sum.worst, below.worst)
          sum.total, sum.red, sum.ms =
            sum.total + below.total, sum.red + below.red, sum.ms + below.ms
        end
      end
    end
    index.sums[node] = sum
    if style(node, sum, is_case) then
      updates[#updates + 1] = {
        id = node.id,
        status = node.status,
        icon = node.icon,
        hl = node.hl,
        columns = node.columns,
      }
    end
  end
  return updates
end

---What a leaf adds to the nodes above it.
---@param node table
---@return { worst: string|nil, total: integer, red: integer, ms: number }
leaf_sum = function(node)
  local data = M.data(node)
  if not node.status or is_detail(data) then
    return { worst = nil, total = 0, red = 0, ms = 0 }
  end
  return {
    worst = node.status,
    total = 1,
    red = M.RED[node.status] and 1 or 0,
    ms = data and data.duration_ms or 0,
  }
end

---Write on a node what it shows for this sum.
---@param node table
---@param sum { worst: string|nil, total: integer, red: integer, ms: number }
---@param is_case boolean
---@return boolean drawn  false for a node that shows nothing of it (the root, an assertion, a note)
style = function(node, sum, is_case)
  local data = M.data(node)
  if not data or data.kind == "root" or is_detail(data) then
    return false
  end
  local look = M.look(sum.worst)
  node.icon, node.hl = look.icon, look.hl
  local columns = {}
  if not is_case and sum.total > 0 and type(node.children) == "table" then
    columns[#columns + 1] = sum.red > 0 and ("%d/%d"):format(sum.red, sum.total)
      or tostring(sum.total)
  end
  local idle = sum.worst == "never" or sum.worst == "running" or sum.worst == "queued"
  if sum.total > 0 and not idle and (sum.ms > 0 or is_case) then
    columns[#columns + 1] = M.duration(sum.ms)
  end
  node.columns = columns
  return true
end

---@param node table
---@param sums? table<table, table>  Filled with the sum of every node walked.
---@return { worst: string|nil, total: integer, red: integer, ms: number }
restyle = function(node, sums)
  local data = M.data(node)
  local sum
  local is_case = is_unit(data) or is_detail(data)
  if is_case or type(node.children) ~= "table" then
    sum = leaf_sum(node)
    if type(node.children) == "table" then
      for _, child in ipairs(node.children) do
        restyle(child, sums)
      end
    end
  else
    sum = { worst = nil, total = 0, red = 0, ms = 0 }
    for _, child in ipairs(node.children) do
      local below = restyle(child, sums)
      sum.worst = M.worse(sum.worst, below.worst)
      sum.total, sum.red, sum.ms = sum.total + below.total, sum.red + below.red, sum.ms + below.ms
    end
  end
  if sums then
    sums[node] = sum
  end
  if style(node, sum, is_case) then
    if data.kind ~= "case" and data.kind ~= "file" or type(node.children) == "table" then
      -- what is red is in sight without a key press, and so is the content of the one spec folder; closed by
      -- hand it stays closed
      node.open = (sum.red > 0 or data.sole == true) or nil
    end
  end
  return sum
end

---How the tree adds statuses up (`aggregate` of a source). A case counts once, whatever stands below it; a
---branch shows the worst below it and is never green while something below it is not; and `counts` holds the
---red cases only, so the number next to the view is "how many are red", not "how many cases there are".
---@param node table
---@param child_aggs { status?: string, counts: table<string, integer>, total: integer }[]
---@param default { status?: string, counts: table<string, integer>, total: integer }
---@return { status?: string, counts: table<string, integer>, total: integer }
function M.aggregate(node, child_aggs, default)
  local data = M.data(node)
  if #child_aggs == 0 or is_unit(data) then
    local status = node.status
    return {
      status = status,
      counts = (status and M.RED[status]) and { [status] = 1 } or {},
      total = is_detail(data) and 0 or 1,
    }
  end
  local worst, counts, total = nil, {}, 0
  for _, agg in ipairs(child_aggs) do
    worst = M.worse(worst, agg.status)
    total = total + (agg.total or 0)
    for status, n in pairs(agg.counts or {}) do
      if M.RED[status] then
        counts[status] = (counts[status] or 0) + n
      end
    end
  end
  return { status = worst, counts = counts, total = total > 0 and total or default.total }
end

---@param list table[]
local function by_label(list)
  table.sort(list, function(a, b)
    local da, db = M.data(a).kind == "dir", M.data(b).kind == "dir"
    if da ~= db then
      return da
    end
    return a.label < b.label
  end)
end

---The title a case is listed under: its name, else the last part of its id.
---@param case Testing.State.Case
---@return string
local function case_label(case)
  if case.name and case.name ~= "" then
    return case.name
  end
  local last = case.id:match(".*::(.*)$")
  return (last and last ~= "") and last or case.id
end

---Whether a case is its whole spec file (the dialects with one case per file): no describe above it and the id
---`<file>::<file name>`.
---@param case Testing.State.Case
---@return boolean
local function is_whole_file(case)
  if case.describe and #case.describe > 0 then
    return false
  end
  local name = case.file:match("([^/]+)$") or case.file
  return case.id == case.file .. "::" .. name
end

---@param root string
---@param case Testing.State.Case
---@param stale boolean
---@param live? table<string, string>
---@return table node
local function case_node(root, case, stale, live)
  ---@type string
  local shown = case.status
  if live and live[case.id] then
    shown = live[case.id]
  elseif stale and not M.RED[shown] then
    shown = "stale"
  end
  return {
    id = "tests:case:" .. case.id,
    label = case_label(case),
    kind = "case",
    status = shown,
    path = root .. "/" .. case.file,
    data = {
      lnum = case.line,
      testing = {
        kind = "case",
        file = case.file,
        case = case.id,
        recorded = case.status,
        message = case.message,
        expected = case.expected,
        actual = case.actual,
        fails = case.fails,
        fails_total = case.fails_total,
        duration_ms = case.duration_ms,
      },
    },
  }
end

---The failing assertions of a case as nodes below it, each with its line.
---@param root string
---@param case Testing.State.Case
---@return table[]|nil
local function assert_nodes(root, case)
  if not M.RED[case.status] or type(case.fails) ~= "table" or #case.fails == 0 then
    return nil
  end
  local out = {}
  for i, fail in ipairs(case.fails) do
    out[#out + 1] = {
      id = ("tests:assert:%s:%d"):format(case.id, i),
      label = fail.msg or "assertion failed",
      kind = "assert",
      hl = "DiagnosticError",
      path = root .. "/" .. case.file,
      columns = fail.line and { tostring(fail.line) } or nil,
      data = {
        lnum = fail.line,
        testing = { kind = "assert", file = case.file, case = case.id },
      },
    }
  end
  if case.fails_total and case.fails_total > #case.fails then
    out[#out + 1] = {
      id = ("tests:assert:%s:more"):format(case.id),
      label = ("... and %d more"):format(case.fails_total - #case.fails),
      kind = "note",
    }
  end
  return out
end

---The node of a describe below `parent`, made when it is not there yet.
---A describe is a group and no place in a file: it carries no `path`, so a tree neither draws it as a folder nor
---finds it when it is asked for the spec file.
---@param file string
---@param parent table
---@param index table<string, table>
---@param titles string[]
---@param depth integer
---@return table
local function describe_node(file, parent, index, titles, depth)
  local chain = {}
  for i = 1, depth do
    chain[i] = titles[i]
  end
  local key = file .. "::" .. table.concat(chain, "::")
  local node = index[key]
  if not node then
    node = {
      id = "tests:describe:" .. key,
      label = chain[depth],
      kind = "describe",
      children = {},
      data = { testing = { kind = "describe", file = file, describe = chain } },
    }
    index[key] = node
    parent.children[#parent.children + 1] = node
  end
  return node
end

---The nodes of a spec file that never ran, from its describe/it calls.
---@param root string
---@param file string
---@param positions Testing.Position[]
---@return table[]
function M.position_nodes(root, file, positions)
  local top = { children = {} }
  local index, seen = {}, {}
  for _, pos in ipairs(positions) do
    local parent = top
    local titles = pos.path or {}
    for depth = 1, #titles do
      parent = describe_node(file, parent, index, titles, depth)
    end
    if pos.kind == "describe" then
      local chain = vim.list_extend(vim.list_slice(titles), { pos.name or "<dynamic>" })
      describe_node(file, parent, index, chain, #chain)
    else
      local name = pos.name or "<dynamic>"
      local id = table.concat(
        vim.list_extend({ file }, vim.list_extend(vim.list_slice(titles), { name })),
        "::"
      )
      -- two calls with one title: the second and later ones get the counter a run gives them
      seen[id] = (seen[id] or 0) + 1
      if seen[id] > 1 then
        id = ("%s#%d"):format(id, seen[id])
      end
      parent.children[#parent.children + 1] = {
        id = "tests:case:" .. id,
        label = name,
        kind = "case",
        status = "never",
        path = root .. "/" .. file,
        data = {
          lnum = pos.line,
          testing = { kind = "case", file = file, case = id, recorded = "never" },
        },
      }
    end
  end
  for _, node in ipairs(top.children) do
    M.restyle(node)
  end
  return top.children
end

---@param root string
---@param file string
---@param cases Testing.State.Case[]
---@param stale boolean
---@param live? table<string, string>
---@return table node
local function file_node(root, file, cases, stale, live)
  local node = {
    id = "tests:file:" .. file,
    label = file:match("([^/]+)$") or file,
    kind = "file",
    path = root .. "/" .. file,
    data = { testing = { kind = "file", file = file } },
  }
  if #cases == 1 and is_whole_file(cases[1]) then
    -- the file is the case
    local case = case_node(root, cases[1], stale, live)
    node.status = case.status
    node.data.lnum = case.data.lnum
    node.data.testing = vim.tbl_extend("force", case.data.testing, { kind = "file" })
    node.children = assert_nodes(root, cases[1])
    return node
  end
  table.sort(cases, function(a, b)
    if (a.line or 0) ~= (b.line or 0) then
      return (a.line or 0) < (b.line or 0)
    end
    return a.id < b.id
  end)
  node.children = {}
  local index = {}
  for _, case in ipairs(cases) do
    local parent = node
    local titles = case.describe or {}
    for depth = 1, #titles do
      parent = describe_node(file, parent, index, titles, depth)
    end
    parent.children[#parent.children + 1] = case_node(root, case, stale, live)
  end
  return node
end

---The root node of the view.
---@param input Testing.Explorer.Input
---@return table root
function M.build(input)
  local root = M.norm(input.root)
  local stale = input.stale or {}
  local by_file, order = {}, {}
  for _, case in ipairs(input.cases) do
    if not by_file[case.file] then
      by_file[case.file] = {}
      order[#order + 1] = case.file
    end
    table.insert(by_file[case.file], case)
  end
  for _, file in ipairs(input.files or {}) do
    if not by_file[file] then
      by_file[file] = {}
      order[#order + 1] = file
    end
  end

  local top = {
    id = "tests:root",
    label = "Tests",
    kind = "root",
    children = {},
    data = { testing = { kind = "root" } },
  }
  local dirs = {}
  ---@param rel string
  ---@return table
  local function dir_node(rel)
    if rel == "" then
      return top
    end
    local node = dirs[rel]
    if not node then
      local parent_rel, name = rel:match("^(.*)/([^/]+)$")
      node = {
        id = "tests:dir:" .. rel,
        label = name or rel,
        kind = "dir",
        path = root .. "/" .. rel,
        children = {},
        data = { testing = { kind = "dir", file = rel } },
      }
      dirs[rel] = node
      local parent = dir_node(parent_rel or "")
      parent.children[#parent.children + 1] = node
    end
    return node
  end

  for _, file in ipairs(order) do
    local cases = by_file[file]
    local node
    if #cases == 0 then
      node = {
        id = "tests:file:" .. file,
        label = file:match("([^/]+)$") or file,
        kind = "file",
        status = "never",
        path = root .. "/" .. file,
        data = { testing = { kind = "file", file = file, recorded = "never" } },
      }
      local positions = input.positions
      if positions then
        node.children = function(_, cb)
          local ok, found = pcall(positions, file)
          cb(M.position_nodes(root, file, ok and type(found) == "table" and found or {}))
        end
      end
    else
      node = file_node(root, file, cases, stale[file] == true, input.live)
    end
    local parent = dir_node(file:match("^(.*)/[^/]+$") or "")
    parent.children[#parent.children + 1] = node
  end

  for _, node in pairs(dirs) do
    by_label(node.children)
  end
  by_label(top.children)
  local folders = #top.children
  if folders == 0 then
    top.children[1] =
      { id = "tests:none", label = "no spec files and no result yet", kind = "note" }
  end
  for i, node in ipairs(input.first or {}) do
    table.insert(top.children, i, node)
  end
  -- a project with one spec folder opens on its content. Written on the node and not as `open` here: every
  -- `restyle` decides `open` again (`M.index` runs one), and a green folder would be closed by it
  local only = top.children[#top.children]
  if folders == 1 and only.kind == "dir" then
    M.data(only).sole = true
  end
  M.restyle(top)
  return top
end

---The flags of the run a node stands for: its folder, its file, its describe, its case. Empty for the root.
---`--file` and `--filter` select by plain substring (`testing.run.select`), so a describe is the prefix of the ids
---below it.
---@param node table
---@return { file?: string[], filter?: string[] }|nil flags  nil: the node stands for no run
function M.run_flags(node)
  local data = M.data(node)
  if not data then
    return nil
  end
  if data.kind == "root" then
    return {}
  elseif data.kind == "dir" then
    return { file = { data.file .. "/" } }
  elseif data.kind == "describe" then
    return {
      file = { data.file },
      filter = { data.file .. "::" .. table.concat(data.describe, "::") .. "::" },
    }
  elseif data.case and data.kind ~= "file" then
    return { file = { data.file }, filter = { data.case } }
  elseif data.file then
    return { file = { data.file } }
  end
  return nil
end

---What a red case said, as lines for a preview: status, message, expected against actual, the failing
---assertions. nil for a node that has nothing to say (the preview then shows its file).
---@param node table
---@return { lines: string[], filetype: string, title: string }|nil
function M.preview(node)
  local data = M.data(node)
  if
    not data
    or not data.case
    or not (data.message or data.expected or data.actual or data.fails)
  then
    return nil
  end
  local lines = { ("# %s"):format(data.case), "" }
  local status = data.recorded or node.status or "?"
  if node.status and node.status ~= status then
    status = ("%s (%s: the file changed since)"):format(status, node.status)
  end
  lines[#lines + 1] = ("status: %s"):format(status)
  if data.duration_ms then
    lines[#lines + 1] = ("time: %s"):format(M.duration(data.duration_ms))
  end
  if data.message then
    vim.list_extend(lines, { "", data.message })
  end
  ---@param title string
  ---@param text string|nil
  local function block(title, text)
    if text then
      vim.list_extend(lines, { "", "## " .. title, "" })
      vim.list_extend(lines, vim.split(text, "\r?\n"))
    end
  end
  block("expected", data.expected)
  block("actual", data.actual)
  if type(data.fails) == "table" and #data.fails > 0 then
    vim.list_extend(lines, { "", "## failing assertions", "" })
    for _, fail in ipairs(data.fails) do
      lines[#lines + 1] = ("- %s%s"):format(
        fail.line and ("line %d: "):format(fail.line) or "",
        fail.msg or "assertion failed"
      )
    end
    if data.fails_total and data.fails_total > #data.fails then
      lines[#lines + 1] = ("- ... and %d more"):format(data.fails_total - #data.fails)
    end
  end
  return { lines = lines, filetype = "markdown", title = data.case }
end

return M
