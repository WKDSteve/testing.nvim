-- TESTS/testing/agent_full_file_spec.lua -- the agent report that leaves failures out names a file with all of them
-- (`<state>/last-failures.md`) instead of asking for a second run: the `more:` line carries the path, the file holds
-- every failure group, and a report that left nothing out writes no file.

---@diagnostic disable: need-check-nil, missing-fields, param-type-mismatch

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local cli = require("testing.cli")
  local history = require("testing.history")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-agent-full"
  local state = root .. "-state"
  vim.fn.mkdir(root .. "/TESTS", "p")
  vim.fn.mkdir(state, "p")
  local function put(rel, text)
    local fh = assert(io.open(root .. "/" .. rel, "wb"))
    fh:write(text)
    fh:close()
  end
  -- eight files, each red with a message of its own: eight failure groups
  for i = 1, 8 do
    put(
      ("TESTS/f%d_spec.lua"):format(i),
      ("return function(H)\n  H.ok(false, 'distinct failure number %d with some words to take space')\nend\n"):format(
        i
      )
    )
  end

  local function run(argv)
    local out, err = {}, {}
    local code = cli.main(vim.list_extend({ root }, argv), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
      color = false,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local file = history.dir(root, { state_dir = state }) .. "/last-failures.md"
  local r = run({ "--reporter", "agent", "--agent-budget", "400" })
  eq(r.code, 1, "red")
  has(r.out, "more: ", "the report left failures out")
  has(r.out, file:gsub("\\", "/"), "and names the file that has them")
  ok(vim.uv.fs_stat(file) ~= nil, "the file is there")
  local text = table.concat(vim.fn.readfile(file), "\n")
  for i = 1, 8 do
    has(text, ("distinct failure number %d"):format(i), "the file holds failure " .. i)
  end
  ok(not text:find("more: ", 1, true), "and is complete: no more: line in it")

  -- nothing left out: no file, and an old one is not touched
  vim.fn.delete(file)
  r = run({ "--reporter", "agent", "--agent-budget", "100000" })
  ok(not r.out:find("more: ", 1, true), "a big budget leaves nothing out")
  eq(vim.uv.fs_stat(file), nil, "and writes no file")

  vim.fn.delete(root, "rf")
  vim.fn.delete(state, "rf")
end
