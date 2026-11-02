-- TESTS/testing/cache_screen_inputs_spec.lua -- a spec that loads `testing.screen` reads the snapshot files of its own
-- name, so they are inputs of its cache key without a `-- @cache-inputs` line, in the folder the project configures
-- (`snapshots.dir`, default `TESTS/__snapshots__`). A spec that does not load it is not affected by them.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-screen"
  local function put(rel, text)
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. rel), "p")
    local fh = assert(io.open(root .. "/" .. rel, "wb"))
    fh:write(text)
    fh:close()
  end
  put(
    "TESTS/shots_spec.lua",
    'local screen = require("testing.screen")\nreturn function(H) H.ok(screen ~= nil, "x") end\n'
  )
  put("TESTS/plain_spec.lua", "return function(H) H.ok(true, 'x') end\n")
  put("TESTS/__snapshots__/shots_spec/a.snap", "one\n")
  put("TESTS/__snapshots__/plain_spec/a.snap", "one\n")
  put("TESTS/shots/b.snap", "one\n")

  local cdir = vim.fs.normalize(vim.fn.tempname())
  local function key_of(file, over)
    local k, why = cache.key(
      { file = file },
      vim.tbl_extend("force", {
        root = root,
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
      }, over or {})
    )
    ok(k ~= nil, file .. " has a key: " .. tostring(why))
    return k
  end

  local shots = key_of("TESTS/shots_spec.lua")
  local plain = key_of("TESTS/plain_spec.lua")

  -- the default folder
  put("TESTS/__snapshots__/shots_spec/a.snap", "two\n")
  ok(
    key_of("TESTS/shots_spec.lua") ~= shots,
    "a changed snapshot changes the key of a spec that loads testing.screen"
  )
  eq(key_of("TESTS/plain_spec.lua"), plain, "and not the key of a spec that does not")

  -- a snapshot that appears (the spec had none) changes the key too
  local before_new = key_of("TESTS/shots_spec.lua")
  put("TESTS/__snapshots__/shots_spec/c.snap", "new\n")
  ok(key_of("TESTS/shots_spec.lua") ~= before_new, "a new snapshot file changes the key")

  -- the folder the project configures
  local configured = key_of("TESTS/shots_spec.lua", { snapshots_dir = "TESTS/shots" })
  put("TESTS/shots/shots_spec/a.snap", "configured\n")
  local after_write = key_of("TESTS/shots_spec.lua", { snapshots_dir = "TESTS/shots" })
  ok(after_write ~= configured, "a snapshot in the configured folder changes the key")
  put("TESTS/__snapshots__/shots_spec/a.snap", "three\n")
  eq(
    key_of("TESTS/shots_spec.lua", { snapshots_dir = "TESTS/shots" }),
    after_write,
    "the default folder is not an input once another one is configured"
  )

  vim.fn.delete(root, "rf")
end
