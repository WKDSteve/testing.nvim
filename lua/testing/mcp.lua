---@module 'testing.mcp'
---@brief The documents of `testing-export/1` as read-only MCP tools, served by `lib.nvim.mcp.server` (`scripts/mcp.lua`).
---@description
--- Each tool is one method of `testing call` (`testing.export.call`), asked through `testing.cli.main` with the
--- arguments the tool's schema allows: the answer is the canonical JSON the command line prints, a refusal (exit 2 or 3)
--- is an `isError` result with the message of stderr. The same rules hold as for `testing call`: it runs nothing (no
--- suite, no pipeline, no `.testing.lua`) and writes nothing.
---
--- Tools: `testing_hello` (what this engine is), `testing_repo` (one repository with its last run and its red cases),
--- `testing_findings` (the findings of the last run, `testing-finding/1`), `testing_fleet` (one row per repository).
--- `remote` (the CI adapter: network and a token) is not offered: an answer of a tool stays local.
---
--- Nothing that runs or writes is a tool: a run, `ci commit`, `ci trust` or `ci land` started by an agent would spend
--- the machine (or prove a commit) without the person who reads the verdict; until a policy for that exists there is
--- none.

local M = {}

---@param argv string[]
---@param env table<string, string|nil>
---@return Lib.Mcp.Server.Result
local function call(argv, env)
  local mcp_server = require("lib.nvim.mcp.server")
  local out, err = {}, {}
  local pass, code = pcall(require("testing.cli").main, vim.list_extend({ "call" }, argv), {
    out = function(s)
      out[#out + 1] = s
    end,
    err = function(s)
      err[#err + 1] = s
    end,
    env = env,
  })
  if not pass then
    return mcp_server.error_text("testing call failed: " .. tostring(code))
  end
  if code ~= 0 then
    return mcp_server.error_text(
      #err > 0 and table.concat(err, "\n") or ("exit code " .. tostring(code))
    )
  end
  return mcp_server.text(table.concat(out, "\n"))
end

---A directory argument (never one that starts with `-`) as an absolute path, or the server's own working directory (the project the client started
---the server in). Absolute on purpose: the value goes into the argv of `testing call`, and a bare `--remote` or
---`--state-dir=...` from the model would otherwise be read as an option (the CI adapter with its token, another
---state folder) instead of as a directory.
---@param dir any
---@return string
local function dir_or_cwd(dir)
  if dir == nil or dir == "" then
    return assert(vim.uv.cwd())
  end
  if type(dir) ~= "string" then
    error("dir must be a text", 0)
  end
  -- refused, not made absolute: `fnamemodify(":p")` leaves `--state-dir=C:/x` as it is on Windows
  if dir:sub(1, 1) == "-" then
    error("dir must not start with '-' (it would be read as an option of testing call)", 0)
  end
  return vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))
end

---The server. `opts.repos_root` is the root of `testing_fleet` and of a `repo` key (nil: `$TESTING_REPOS_ROOT`, then
---`$REPOS_DIR`).
---@param opts? { repos_root?: string }
---@return Lib.Mcp.Server
function M.server(opts)
  opts = opts or {}
  local mcp_server = require("lib.nvim.mcp.server")
  local root = opts.repos_root or vim.env.TESTING_REPOS_ROOT or vim.env.REPOS_DIR
  local env = { TESTING_REPOS_ROOT = (root and root ~= "") and root or nil }
  local s = mcp_server.new({
    name = "testing.nvim",
    instructions = "Read-only tools over the results of testing.nvim (testing-export/1): the last run of a "
      .. "repository, its red cases and findings, the fleet. Nothing here runs a suite or writes.",
  })
  s:add("testing_hello", {
    description = "What this test engine is: its build, the versions of the contract, what it answers.",
    run = function()
      return call({ "hello" }, env)
    end,
  })
  s:add("testing_repo", {
    description = "One repository with its last run (verdict, counts, when) and its red cases. `dir` is the "
      .. "repository (default: the directory this server runs in).",
    input_schema = { type = "object", properties = { dir = { type = "string" } } },
    run = function(args)
      return call({ "repo", dir_or_cwd(args.dir) }, env)
    end,
  })
  s:add("testing_findings", {
    description = "The findings of the last run of a repository (documents testing-finding/1, a JSON array). "
      .. "`dir` as for testing_repo; `fp` (16 hex digits) only that finding.",
    input_schema = {
      type = "object",
      properties = {
        dir = { type = "string" },
        fp = { type = "string", pattern = "^[0-9a-fA-F]+$" },
      },
    },
    run = function(args)
      local argv = { "finding", dir_or_cwd(args.dir) }
      if args.fp ~= nil then
        if type(args.fp) ~= "string" or not args.fp:match("^%x+$") then
          error("fp must be hex digits", 0)
        end
        argv[#argv + 1] = "--fp=" .. args.fp
      end
      local res = call(argv, env)
      if not res.isError then
        -- one document per line: one JSON array for the model
        local lines = vim.split(res.content[1].text, "\n", { trimempty = true })
        res.content[1].text = "[" .. table.concat(lines, ",") .. "]"
      end
      return res
    end,
  })
  s:add("testing_fleet", {
    description = "One row per repository below the repositories root (state of the last run, red count). "
      .. "`include`/`exclude`: directory names, comma separated.",
    input_schema = {
      type = "object",
      properties = { include = { type = "string" }, exclude = { type = "string" } },
    },
    run = function(args)
      if not env.TESTING_REPOS_ROOT then
        error("no repositories root: set $TESTING_REPOS_ROOT or $REPOS_DIR", 0)
      end
      local argv = { "fleet", "--repos-root=" .. env.TESTING_REPOS_ROOT }
      for _, key in ipairs({ "include", "exclude" }) do
        if args[key] ~= nil then
          if type(args[key]) ~= "string" or args[key] == "" then
            error(key .. " must be a list of names, comma separated", 0)
          end
          argv[#argv + 1] = ("--%s=%s"):format(key, args[key])
        end
      end
      return call(argv, env)
    end,
  })
  return s
end

return M
