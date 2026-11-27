-- TESTS/testing/ci_commit_supersede_spec.lua -- a full `ci commit` that waits in the queue leaves when a run for a
-- strict descendant of the same repository and profile, with a base that is its base or older, is there: verdict
-- superseded, exit 0, nothing kept. --no-supersede, --quick, another repository, another profile, a younger base and
-- an unrelated commit keep it waiting.
-- It starts git (fixture repositories in the temp directory) and nothing else: no run reaches the suite.
-- @cache-allow spawn

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local S = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
      .. "/ci_commit_support.lua"
  ).new(H, "ci-commit-supersede")
  local eq, has, git_out = S.eq, S.has, S.git_out
  local commit = require("testing.ci.commit")

  local saved_mod = package.loaded["testing.queue"]
  package.loaded["testing.queue"] = nil
  local queue = require("testing.queue")
  local saved_token = vim.env[queue.TOKEN_ENV]
  vim.env[queue.TOKEN_ENV] = nil

  -- c0 - c1 - c2 on main, x1 on a side line from c0
  local root, c0 = S.project("proj", { ["gate.txt"] = "green\n" })
  local c1 = S.commit(root, { ["a.txt"] = "1\n" }, "c1")
  local c2 = S.commit(root, { ["a.txt"] = "2\n" }, "c2")
  git_out(root, "checkout", "-q", "-b", "side", c0)
  local x1 = S.commit(root, { ["b.txt"] = "x\n" }, "x1")
  git_out(root, "checkout", "-q", "main")
  -- the repository as the run names it: absolute, whatever the cwd of this process is
  local repo =
    vim.fs.normalize(git_out(root, "rev-parse", "--path-format=absolute", "--git-common-dir"))
  ok(
    vim.fn.getcwd() ~= root,
    "fixture: the spec runs outside the project, as another session would"
  )

  -- overtaken_by: the rule
  local mine = { sha = c1, base = c0, profile = "", repo = repo }
  local function other(t)
    return vim.tbl_extend("force", { sha = c2, base = c0, profile = "", repo = repo }, t or {})
  end
  has(
    commit.overtaken_by(root, mine, { other() }),
    c2:sub(1, 12),
    "a descendant with the same base overtakes"
  )
  has(
    commit.overtaken_by(root, mine, { other({ base = c0 }) }) or "",
    "covers this one",
    "... and the reason says why"
  )
  eq(commit.overtaken_by(root, mine, { other({ sha = c1 }) }), nil, "the same commit does not")
  eq(
    commit.overtaken_by(root, mine, { other({ sha = x1 }) }),
    nil,
    "a commit of another line does not"
  )
  eq(commit.overtaken_by(root, mine, { other({ sha = c0 }) }), nil, "an ancestor does not")
  eq(
    commit.overtaken_by(root, mine, { other({ base = c1 }) }),
    nil,
    "a descendant with a younger base does not"
  )
  eq(
    commit.overtaken_by(root, mine, { other({ profile = "fast" }) }),
    nil,
    "another profile does not"
  )
  eq(
    commit.overtaken_by(root, mine, { other({ repo = repo .. "x" }) }),
    nil,
    "another repository does not"
  )
  eq(
    commit.overtaken_by(root, mine, { other({ base = "" }) }),
    nil,
    "a run without a base does not"
  )
  eq(commit.overtaken_by(root, mine, { {} }), nil, "a run that says nothing does not")

  -- supersede_opts: only a single full check takes part
  local function opts(args)
    return commit.supersede_opts(
      root,
      c1,
      c0,
      vim.tbl_extend("force", { supersede = true }, args or {})
    )
  end
  eq(opts().meta, mine, "supersede_opts: the run says what it is, with the absolute repository")
  ok(type(opts().give_up) == "function", "supersede_opts: ... and asks at every look")
  eq(opts({ supersede = false }), {}, "supersede_opts: off (--no-supersede, several commits)")
  eq(opts({ quick = true }), {}, "supersede_opts: never for --quick")
  eq(opts({ force = true }), {}, "supersede_opts: never for --force")
  eq(opts({ keep = true }), {}, "supersede_opts: never for --keep")
  eq(
    commit.supersede_opts(root, c1, nil, { supersede = true }),
    {},
    "supersede_opts: never without a base"
  )

  -- the whole call: a live run for c2 holds the queue, the check of c1 leaves at once
  local lock = S.tmp .. "/heavy.lock"
  local function holder(meta)
    local f = assert(io.open(lock, "wb"))
    f:write(vim.json.encode({
      pid = vim.uv.os_getppid(),
      token = "other",
      started = os.time(),
      what = "ci commit c2",
      meta = meta,
    }))
    f:close()
  end
  local function call(...)
    local out, err = {}, {}
    local code = require("testing.cli").main(
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
        queue = { path = lock, off = false },
      }
    )
    return {
      code = code,
      first = out[1] or "",
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
    }
  end
  local saved_poll, saved_max = queue.POLL_MS, queue.MAX_WAIT_MS
  queue.POLL_MS, queue.MAX_WAIT_MS = 1, 200

  holder({ sha = c2, base = c0, profile = "full", repo = repo })
  local r = call(c1, "--base=" .. c0, "--profile=full")
  eq(r.code, 0, "call: superseded is exit 0 (" .. r.first .. r.err:sub(1, 300) .. ")")
  has(r.first, "SUPERSEDED", "call: the headline says superseded")
  has(r.first, c2:sub(1, 12), "call: ... and by which commit")
  local kept = vim.fn.glob(S.state_dir .. "/**/" .. c1 .. "-*.json", true, true)
  eq(kept, {}, "call: nothing is kept for the superseded commit")

  r = call(c1, "--base=" .. c0, "--profile=full", "--no-supersede")
  eq(r.code, 3, "call: --no-supersede keeps waiting (here: until the wait is too long)")
  has(r.first .. r.out, "queue:", "call: ... and says so")

  local json = S.tmp .. "/result.json"
  r = call(c1, "--base=" .. c0, "--profile=full", "--json=" .. json)
  eq(r.code, 0, "json: superseded again")
  local f = io.open(json, "rb")
  local okd, doc = pcall(vim.json.decode, f and f:read("*a") or "")
  if f then
    f:close()
  end
  ok(okd and type(doc) == "table", "json: the document is written")
  local item = okd and type(doc) == "table" and (doc.results or doc.commits or {})[1] or {}
  eq(
    item.verdict,
    "superseded",
    "json: verdict superseded (" .. vim.inspect(doc):sub(1, 200) .. ")"
  )
  eq(item.superseded_by, c2:sub(1, 12), "json: superseded_by")

  queue.POLL_MS, queue.MAX_WAIT_MS = saved_poll, saved_max
  os.remove(lock)
  vim.fn.delete(queue.waiting_dir(lock), "rf")
  vim.env[queue.TOKEN_ENV] = saved_token
  package.loaded["testing.queue"] = saved_mod
  S.cleanup()
end
