-- TESTS/testing/ci_commit_support.lua -- the fixture repositories behind the `testing ci commit` run specs: a throwaway
-- directory with its own state, a project whose pipeline is a suite plus a gate step that is red while gate.txt says so,
-- and `call` that runs the subcommand in process.
--
-- Used by ci_commit_run_spec (the verdicts) and ci_commit_ops_spec (the operation around them).

local M = {}

---@param H table the spec harness
---@param label string suffix of the temporary directory
function M.new(H, label)
  local ok = H.ok
  local S = {}
  function S.eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  function S.has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 2500) .. ")"
    )
  end

  local cli = require("testing.cli")
  S.cli = cli

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-" .. label
  vim.fn.mkdir(tmp, "p")
  S.tmp = tmp
  S.state_dir = tmp .. "/state"
  local nvim = vim.v.progpath

  function S.write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  function S.git_out(root, ...)
    local res = vim
      .system({
        "git",
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.autocrlf=false",
        ...,
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
    return vim.trim(res.stdout or "")
  end
  function S.commit(root, files, message)
    for rel, text in pairs(files) do
      S.write(root .. "/" .. rel, text)
    end
    S.git_out(root, "add", "-A")
    S.git_out(root, "commit", "-q", "-m", message)
    return S.git_out(root, "rev-parse", "HEAD")
  end

  -- a step that is red while gate.txt says so (no findings: compared as a whole), and the suite (findings from the IR)
  local GATE = "local f = assert(io.open(_G.arg[1] .. '/gate.txt', 'rb'))\n"
    .. "local t = f:read('*a')\nf:close()\n"
    .. "if t:find('red') then io.stderr:write('gate is red\\n') os.exit(1) end\n"
  local CFG = ("return { plugin = 'proj', minit = false, guards = { fs = 'off' }, ci = { profiles = { full = { 'suite', 'gate' } }, steps = { gate = { run = { %q, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', 'gate.lua', '${root}' } } } } }\n"):format(
    nvim
  )
  S.CFG = CFG
  S.PASS = "return function(H)\n  H.ok(true, 'fine')\nend\n"
  S.BOOM = "return function(H)\n  H.ok(false, 'boom')\nend\n"

  ---@return string root, string first_sha
  function S.project(name, files)
    local root = tmp .. "/" .. name
    vim.fn.mkdir(root, "p")
    S.git_out(root, "init", "-q")
    S.git_out(root, "symbolic-ref", "HEAD", "refs/heads/main")
    local all = { [".testing.lua"] = CFG, ["gate.lua"] = GATE, ["TESTS/a_spec.lua"] = S.PASS }
    for k, v in pairs(files) do
      all[k] = v
    end
    return root, S.commit(root, all, "init")
  end

  function S.call(root, ...)
    local out, err = {}, {}
    local code = cli.main(
      vim.list_extend({ "ci", "commit", "--root=" .. root, "--state-dir=" .. S.state_dir }, { ... }),
      {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          err[#err + 1] = s
        end,
        state_dir = S.state_dir,
        color = false,
      }
    )
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      first = out[1] or "",
    }
  end

  function S.worktrees(dir)
    local n = 0
    for line in S.git_out(dir, "worktree", "list", "--porcelain"):gmatch("[^\n]+") do
      n = n + (line:match("^worktree ") and 1 or 0)
    end
    return n
  end

  function S.cleanup()
    vim.fn.delete(tmp, "rf")
  end

  return S
end

return M
