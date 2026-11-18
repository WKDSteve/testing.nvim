-- scripts/mcp.lua -- the read-only MCP server of testing.nvim (stdio), for Claude Code and other clients.
--
--   nvim -n -i NONE --headless -u NONE -l scripts/mcp.lua [--repos-root=<dir>]
--
-- The tools are `testing.mcp` (the documents of `testing call`). `--repos-root` is the root of `testing_fleet`
-- (default `$TESTING_REPOS_ROOT`, then `$REPOS_DIR`). An MCP client starts this as a subprocess and speaks JSON-RPC
-- on its stdin/stdout; run by hand it waits for a line. lib.nvim is found as for scripts/testing.lua.

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))

---@param msg string
local function die(msg)
  io.stderr:write(msg, "\n")
  os.exit(3)
end

vim.opt.rtp:prepend(repo)
local deps = require("testing.deps")
local lib, why = deps.resolve("lib.nvim", repo)
if not lib then
  die(why or "testing: lib.nvim was not found")
  return
end
local too_old = deps.lib_problem(lib)
if too_old then
  die(too_old)
end
vim.opt.rtp:append(lib.dir)

local repos_root
for i = 1, #(arg or {}) do
  local v = arg[i]:match("^%-%-repos%-root=(.+)$")
  if not v then
    io.stderr:write(
      ("error: unknown argument %s (usage: scripts/mcp.lua [--repos-root=<dir>])\n"):format(arg[i])
    )
    os.exit(2)
  end
  repos_root = v
end

os.exit(require("testing.mcp").server({ repos_root = repos_root }):serve())
