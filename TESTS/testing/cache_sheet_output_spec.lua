-- TESTS/testing/cache_sheet_output_spec.lua -- what the test sheets write while the suite runs (`TESTS/sheets/out`:
-- the page they open, their screenshots) is no input of a cache key. In a fresh tree (`ci commit`, a snapshot, the WSL
-- mirror) the folder appears during the run; as part of a directory digest it changed the key of every spec that
-- reads files of TESTS/ or loads by ex command, and the run stored nothing ("an input changed while the run was going").

return function(H)
  local ok = H.ok
  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-sheet-out"
  local function put(rel, text)
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. rel), "p")
    local fh = assert(io.open(root .. "/" .. rel, "wb"))
    fh:write(text)
    fh:close()
  end
  -- reads a file of the spec root: the spec root (TESTS/) is an input
  put(
    "TESTS/reader_spec.lua",
    'return function(H) local f = io.open("TESTS/data.txt") H.ok(f ~= nil, "x") end\n'
  )
  -- loads by ex command: the whole project is an input
  put(
    "TESTS/loader_spec.lua",
    'return function(H) vim.cmd.runtime("plugin/x.lua") H.ok(true, "x") end\n'
  )
  put("TESTS/data.txt", "one\n")

  local cdir = vim.fs.normalize(vim.fn.tempname())
  local function key_of(file, at)
    local k, why = cache.key({ file = file }, {
      root = at or root,
      cache_dir = cdir,
      dep_roots = {},
      runner_version = "runner-1",
      nvim = "0.12.0-test",
      config_digest = "cfg-1",
      dialect = "a",
      env_names = {},
      environ = function()
        return {}
      end,
      hasher = hash.new(),
    })
    ok(k ~= nil, file .. " has a key: " .. tostring(why))
    return k
  end

  -- reads files and looks at line endings (`fileformat`): its key comes from the raw pass (the bytes as they are)
  put(
    "TESTS/eol_spec.lua",
    'return function(H) local f = io.open("TESTS/data.txt") H.ok(vim.o.fileformat ~= "", "x") end\n'
  )

  local reader, loader = key_of("TESTS/reader_spec.lua"), key_of("TESTS/loader_spec.lua")
  local eol = key_of("TESTS/eol_spec.lua")

  -- a sheet writes its page and a screenshot during the run
  put("TESTS/sheets/out/keyword-page.html", "<html>page</html>\n")
  put("TESTS/sheets/out/card.shot.80x24.png", "png\n")
  ok(
    key_of("TESTS/reader_spec.lua") == reader,
    "TESTS/sheets/out is no input of a spec reading TESTS/"
  )
  ok(
    key_of("TESTS/loader_spec.lua") == loader,
    "... nor of a spec whose input is the whole project"
  )
  ok(
    key_of("TESTS/eol_spec.lua") == eol,
    "... nor in the raw pass (a spec that looks at line endings)"
  )

  -- anything else below TESTS/ still is: a sheet itself, data next to it
  put("TESTS/sheets/card.sheet.lua", "return {}\n")
  ok(key_of("TESTS/reader_spec.lua") ~= reader, "a sheet file is still an input")
  local with_sheet = key_of("TESTS/reader_spec.lua")
  put("TESTS/sheets/outline.txt", "a name that only starts like the folder\n")
  ok(
    key_of("TESTS/reader_spec.lua") ~= with_sheet,
    "TESTS/sheets/outline.txt is not the output folder"
  )

  -- a root named relatively (`testing explain` in the project: `.`) is the same project
  do
    local here = vim.fn.getcwd()
    vim.fn.chdir(root)
    local rel_before = key_of("TESTS/reader_spec.lua", ".")
    put("TESTS/sheets/out/second.png", "png\n")
    local rel_after = key_of("TESTS/reader_spec.lua", ".")
    vim.fn.chdir(here)
    ok(rel_before == rel_after, "a relative root: TESTS/sheets/out is no input either")
  end

  ok(cache.is_output("TESTS/sheets/out"), "is_output: the folder")
  ok(cache.is_output("TESTS/sheets/out/a/b.png"), "is_output: below it")
  ok(
    not cache.is_output("TESTS/sheets/outx/a.png"),
    "is_output: not a sibling with the same prefix"
  )
  ok(not cache.is_output("TESTS/sheets"), "is_output: not its parent")

  vim.fn.delete(root, "rf")
  vim.fn.delete(cdir, "rf")
end
