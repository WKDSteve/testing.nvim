-- TESTS/testing/mcp_stdio_spec.lua -- scripts/mcp.lua as a real process, talked to by the MCP client of lib.nvim with
-- stdin held open: the boot (lib.nvim resolved by testing.deps, --repos-root read), the handshake and one tool, as
-- Claude Code would.

---@diagnostic disable: need-check-nil

return function(H)
  local ok, eq = H.ok, H.eq
  local here =
    vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
  local root_dir = vim.fs.dirname(vim.fs.dirname(here))

  local lib = vim.api.nvim_get_runtime_file("lua/lib/nvim/mcp/server/init.lua", false)[1]
  ok(lib, "lib.nvim with lib.nvim.mcp.server is on the runtimepath")
  local lib_dir = vim.fs.normalize(lib):gsub("/lua/lib/nvim/mcp/server/init%.lua$", "")
  local repos_root = vim.fn.tempname()
  vim.fn.mkdir(repos_root, "p")

  -- the client's VimLeavePre group is made by its first client; a spec that made it takes it away again
  local had_group = pcall(vim.api.nvim_get_autocmds, { group = "lib.nvim.mcp" })
  local mcp = require("lib.nvim.mcp")
  local c = mcp.client({
    id = "testing-mcp-stdio-spec",
    cmd = {
      vim.v.progpath,
      "-n",
      "-i",
      "NONE",
      "--headless",
      "-u",
      "NONE",
      "-l",
      root_dir .. "/scripts/mcp.lua",
      "--repos-root=" .. repos_root,
    },
    -- NVIM cleared: inside the runner it names the parent editor
    env = { NVIM = "", NVIM_LISTEN_ADDRESS = "", LIB_NVIM_DIR = lib_dir },
    timeout_ms = 20000,
  })
  local function ask(fn)
    local done, a, b = false, nil, nil
    fn(function(x, y)
      done, a, b = true, x, y
    end)
    vim.wait(25000, function()
      return done
    end, 10)
    return a, b
  end

  local tools, err = ask(function(cb)
    c:list_tools(cb)
  end)
  ok(tools and not err, "tools/list over stdio: " .. vim.inspect(err))
  eq(tools and #tools, 4, "four read tools")
  eq((c:server() or {}).serverInfo.name, "testing.nvim", "the handshake reached scripts/mcp.lua")
  local res = ask(function(cb)
    c:call_tool("testing_hello", {}, cb)
  end)
  ok(res and not res.isError, "testing_hello over stdio answers")
  ok(res and vim.json.decode(res.content[1].text).kind ~= nil, "a document of the contract")

  mcp.forget("testing-mcp-stdio-spec")
  if not had_group then
    pcall(vim.api.nvim_del_augroup_by_name, "lib.nvim.mcp")
  end
  vim.fn.delete(repos_root, "rf")
end
