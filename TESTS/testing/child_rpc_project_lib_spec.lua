-- TESTS/testing/child_rpc_project_lib_spec.lua -- a REAL child editor of the rpc driver (`testing.rpc`) without
-- `rtp_prepend` loads the project's lib.nvim when the project is lib.nvim itself (a worktree): before, the driver
-- resolved lib.nvim from the project (`$LIB_NVIM_DIR` first), which named the main checkout, and the worktree's code
-- never ran in the child. As `run.options.child_rtp` (`testing.deps.project_lib`); the runner's lib.nvim stays behind.

-- @cache-allow spawn
-- @cache-allow outside
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local deps = require("testing.deps")
  local runner_lib = assert(deps.resolve("lib.nvim", deps.self_dir()), "the runner's lib.nvim")

  local dir = vim.fs.normalize(vim.fn.tempname()) .. "-libwt"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end
  -- a lib.nvim checkout: copies of what this runner needs of it (else it counts as too old and is not taken), and one
  -- module only it has
  local probe
  for _, req in ipairs(deps.LIB_REQUIRED) do
    for _, tail in ipairs({ ".lua", "/init.lua" }) do
      local rel = "lua/" .. req.module .. tail
      if vim.fn.filereadable(runner_lib.dir .. "/" .. rel) == 1 then
        write(dir .. "/" .. rel, read(runner_lib.dir .. "/" .. rel))
        probe = probe or rel
      end
    end
  end
  assert(probe, "a module of deps.LIB_REQUIRED in the runner's lib.nvim")
  write(dir .. "/lua/lib/nvim/__project_probe.lua", "return 'project'\n")

  local child = assert(require("testing.rpc").spawn({
    root = dir,
    guard = false,
    call_timeout_ms = 20000,
  }))
  local ok_run, err = pcall(function()
    eq(
      child.lua("return (pcall(require, 'lib.nvim.__project_probe'))"),
      true,
      "the project's own module loads in the child"
    )
    local first = child.lua("return vim.api.nvim_get_runtime_file(..., false)[1]", probe)
    eq(
      type(first) == "string" and vim.fs.normalize(first):lower():find(dir:lower(), 1, true) == 1,
      true,
      "a module both have comes from the project (" .. tostring(first) .. ")"
    )
    eq(
      deps.same_dir(child.lua("return vim.env.LIB_NVIM_DIR") or "", dir),
      true,
      "$LIB_NVIM_DIR of the child is the project"
    )
    local rtp = vim.fs.normalize(child.lua("return vim.o.runtimepath")):lower()
    ok(
      rtp:find(vim.fs.normalize(runner_lib.dir):lower(), 1, true) ~= nil,
      "the runner's lib.nvim stays behind it"
    )
  end)
  child.kill()
  vim.fn.delete(dir, "rf")
  assert(ok_run, err)
end
