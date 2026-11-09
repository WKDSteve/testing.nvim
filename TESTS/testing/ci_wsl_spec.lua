-- TESTS/testing/ci_wsl_spec.lua -- `testing ci commit --wsl` (testing.ci.wsl): the mirror in WSL is synced from the
-- Windows checkouts (the dependencies at their HEAD), the inner `ci commit` gets its own options BEFORE the given ones
-- (after a `--` they would be the suite's), the queue and the metrics stay on the Windows side, the document comes
-- back and is reported as without --wsl. WSL itself is a fake here.

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(
      vim.deep_equal(a, b),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a))
    )
  end
  local function has(s, part, msg)
    return ok(
      type(s) == "string" and s:find(part, 1, true) ~= nil,
      ("%s: %s not in %s"):format(msg, part, vim.inspect(s))
    )
  end
  local wsl = require("testing.ci.wsl")
  local commit = require("testing.ci.commit")

  eq(wsl.wsl_path("E:/repos/x.nvim"), "/mnt/e/repos/x.nvim", "a Windows path as WSL sees it")
  eq(wsl.wsl_path("C:\\Users\\a b\\t"), "/mnt/c/Users/a b/t", "backslashes and a blank")

  -- the script
  local script = wsl.script({
    repo = "x.nvim",
    root = "E:/repos/x.nvim",
    deps = { ["lib.nvim"] = "E:/repos/lib.nvim", ["testing.nvim"] = "E:/repos/testing.nvim" },
    argv = { "abc1234", "--quick", "--", "--cached" },
    json = "C:/T/out.json",
  })
  has(
    script,
    "sync 'lib.nvim' '/mnt/e/repos/lib.nvim' && head_of 'lib.nvim'",
    "script: a dependency at its HEAD"
  )
  has(script, "sync 'x.nvim' '/mnt/e/repos/x.nvim' ||", "script: the repository itself")
  has(script, "core.autocrlf=false", "script: no CRLF in the mirror")
  has(
    script,
    "TESTING_QUEUE=off TESTING_METRICS=off",
    "script: queue and metrics are the Windows side's"
  )
  local inner = script:match("ci commit (.-)\n")
  ok(inner ~= nil, "script: the inner ci commit")
  local root_at, dashdash_at = inner:find("--root=.", 1, true), inner:find("'--'", 1, true)
  ok(
    root_at and dashdash_at and root_at < dashdash_at,
    "script: its own options come before -- (" .. inner .. ")"
  )
  has(
    inner,
    "--json=\"$(wslpath -u 'C:/T/out.json')\"",
    "script: the document goes to a Windows path"
  )
  has(inner, "'abc1234' '--quick' '--' '--cached'", "script: the given arguments, quoted, in order")
  has(
    wsl.script({ repo = "r", root = "E:/r", deps = {}, argv = { "it's" }, json = "C:/o" }),
    [['it'\''s']],
    "script: a quote in an argument stays one argument"
  )

  -- the run: a fake WSL writes the document
  local saved_run = wsl.run_bash
  local seen
  wsl.run_bash = function(s)
    seen = s
    local out = s:match("wslpath %-u '([^']+)'")
    local f = assert(io.open(out, "wb"))
    f:write(vim.json.encode({
      schema = "testing-ci-commit/1",
      exit = 0,
      commits = {
        {
          sha = ("a"):rep(40),
          verdict = "clean",
          exit = 0,
          profile = "full",
          steps_head = { { name = "suite", state = "green" } },
          new = {},
          known = {},
          fixed = {},
          problems = {},
          exact = true,
        },
      },
    }))
    f:close()
    return 0, "", ""
  end
  local doc = wsl.run("E:/repos/x.nvim", { "HEAD" }, { ["lib.nvim"] = "E:/repos/lib.nvim" })
  eq(doc and doc.exit, 0, "run: the document came back")
  ok(seen ~= nil, "run: the script ran")

  -- through ci commit --wsl: the report, the exit code, one metrics line with os wsl
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-wsl"
  vim.fn.mkdir(tmp, "p")
  local lines = {}
  local mfile = { path = tmp .. "/m.jsonl", host = "h" }
  local code = commit.main({ "HEAD", "--wsl", "--no-agent", "--", "--cached" }, {
    out = function(s)
      lines[#lines + 1] = s
    end,
    err = function(s)
      lines[#lines + 1] = s
    end,
    metrics = mfile,
  })
  eq(code, 0, "ci commit --wsl: the exit code of the run in WSL")
  local text = table.concat(lines, "\n")
  has(text, "in WSL2", "ci commit --wsl: says where it ran")
  has(text, "CLEAN", "ci commit --wsl: the verdict as without --wsl")
  local inner2 = seen:match("ci commit (.-)\n")
  ok(not inner2:find("--wsl", 1, true), "ci commit --wsl: --wsl does not go into WSL")
  ok(
    not inner2:find("'--no-agent'", 1, true),
    "ci commit --wsl: nor the report options of this side"
  )
  has(inner2, "'HEAD' '--' '--cached'", "ci commit --wsl: the revisions and suite options do")
  -- scripts/test.sh hands down `--state-dir <dir>` and, for --cached, `--cache-dir <dir>`: Windows paths, never into WSL
  commit.main({
    "HEAD",
    "--wsl",
    "--state-dir",
    "C:/S",
    "--",
    "--cached",
    "--cache-dir",
    "C:/K",
    "--jobs",
    "2",
  }, {
    out = function() end,
    err = function() end,
  })
  local inner3 = seen:match("ci commit (.-)\n")
  ok(
    not inner3:find("C:/S", 1, true),
    "ci commit --wsl: no Windows state folder in WSL (" .. inner3 .. ")"
  )
  ok(not inner3:find("C:/K", 1, true), "ci commit --wsl: no Windows cache folder in WSL")
  has(inner3, "'--cached' '--jobs' '2'", "ci commit --wsl: the other suite options stay")
  local entries = require("testing.metrics").read(mfile.path)
  eq(entries[1] and entries[1].os, "wsl", "ci commit --wsl: the metrics line says wsl")
  eq(entries[1] and entries[1].kind, "ci-commit", "ci commit --wsl: ... of kind ci-commit")
  eq(
    commit.main({ "--since=1.day.ago", "--repos-root=" .. tmp, "--wsl" }, {
      out = function() end,
      err = function() end,
    }),
    commit.EXIT_USAGE,
    "ci commit --wsl: one repository, not --repos-root"
  )
  wsl.run_bash = saved_run
  vim.fn.delete(tmp, "rf")
end
