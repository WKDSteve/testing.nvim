-- TESTS/testing/sheet_project_name_spec.lua -- the name of a project in a task's block: `sheets.project` of its
-- `.testing.lua`, else the folder. The nvim config lives in a folder `nvim`, its tasks and checkout are `nvim-config`:
-- tasks-desktop looks for the snapshots under `<checkouts>/<project>/...`.

return function(H)
  local eq = H.eq
  local tasks = require("testing.sheet.tasks")
  local report = require("testing.sheet.report")
  local base = vim.fs.normalize(vim.fn.tempname())
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  -- a config in a folder `nvim` that names itself
  local nvim = base .. "/nvim"
  write(nvim .. "/.testing.lua", 'return { sheets = { project = "nvim-config" } }\n')
  write(
    nvim .. "/TESTS/sheets/context-open.sheet.lua",
    'return { id = "cfg.context", title = "Context", task = "nvim-config/x", steps = { { keys = "x" } } }\n'
  )
  eq(tasks.project_name(nvim), "nvim-config", "sheets.project names the project")
  local entries = report.collect({ nvim }, { cases = {} })
  local block = tasks.render_block(entries)
  H.ok(
    block:find("`nvim-config/TESTS/sheets/context-open.sheet.lua`", 1, true) ~= nil,
    "the block names it: " .. block
  )
  H.ok(not block:find("`nvim/TESTS", 1, true), "... not the folder")

  -- the same root in a report of several projects
  local other = base .. "/ui.nvim"
  write(
    other .. "/TESTS/sheets/picker.sheet.lua",
    'return { id = "ui.picker", title = "Picker", steps = { { keys = "x" } } }\n'
  )
  eq(tasks.project_name(other), "ui.nvim", "without .testing.lua: the folder")
  local text = report.render(report.collect({ nvim, other }, { cases = {} }))
  H.ok(
    text:find("nvim-config/TESTS/sheets/context-open.sheet.lua", 1, true) ~= nil,
    "the report too: " .. text
  )

  -- without the key, or with one that is no name: the folder, as before
  write(nvim .. "/.testing.lua", "return { sheets = { project = '../x' } }\n-- changed\n")
  eq(tasks.project_name(nvim), "nvim", "a name with a slash is not taken")
  write(nvim .. "/.testing.lua", "return { sheets = {} }\n")
  eq(tasks.project_name(nvim), "nvim", "no key: the folder")
  write(nvim .. "/.testing.lua", "error('broken')\n-- a file that does not load\n")
  eq(tasks.project_name(nvim), "nvim", "a file that does not load: the folder")
  -- naming a project runs none of its code: the file is read as data
  vim.g.project_name_ran = nil
  write(
    nvim .. "/.testing.lua",
    'vim.g.project_name_ran = true\nreturn { sheets = { project = "nvim-config" } }\n'
  )
  eq(tasks.project_name(nvim), "nvim", "a file that calls something is not read")
  eq(vim.g.project_name_ran, nil, "... and nothing of it ran")

  vim.fn.delete(base, "rf")
end
