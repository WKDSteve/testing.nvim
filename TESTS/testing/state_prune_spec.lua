-- TESTS/testing/state_prune_spec.lua -- `testing state prune`: a run leaves the marker root.json in its state folder;
-- prune removes a folder whose project path is gone and keeps the folder of a project that is there, one without a
-- marker, one whose marker belongs to another folder, one with a fresh lock, and anything of another form. The state
-- directory is a temp folder of this spec.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local prune = require("testing.state_prune")
  local history = require("testing.history")
  local result = require("testing.core.result")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-prune"
  local base = tmp .. "/state"
  local opts = { state_dir = base }
  local function project(name)
    local root = tmp .. "/" .. name
    vim.fn.mkdir(root, "p")
    return root
  end
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function run(argv)
    local out, err = {}, {}
    local code = prune.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    })
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end

  -- a run marks its folder (testing.state.record)
  local kept = project("kept")
  local ok_rec, rerr = require("testing.state").record(
    kept,
    result.finalize(result.new({ root = kept, id = "2026-01-01T00:00:00Z-0001" })),
    { ran_files = {}, known_files = {}, time = 1700000000 },
    opts
  )
  ok(ok_rec, "record: " .. tostring(rerr))
  local kept_dir = history.dir(kept, opts)
  eq(
    prune.read(kept_dir),
    require("lib.nvim.fs.project_key")(kept),
    "a recorded run leaves the marker with its project"
  )

  -- a worktree that is gone, one with a fresh lock, one without a marker, one marked for another folder
  local gone = project("wt-gone")
  local gone_dir = history.dir(gone, opts)
  ok(prune.mark(gone_dir, gone), "mark")
  write(gone_dir .. "/runs.jsonl", "{}\n")
  local busy = project("wt-busy")
  local busy_dir = history.dir(busy, opts)
  prune.mark(busy_dir, busy)
  write(busy_dir .. "/ci-commit/x.json.lock", "1 1")
  local unmarked_dir = history.dir(project("wt-old"), opts)
  write(unmarked_dir .. "/last.json", "{}")
  local foreign_dir = base .. "/testing/foreign-aaaaaaaaaaaa"
  prune.mark(foreign_dir, gone)
  local odd_dir = base .. "/testing/not-a-project"
  write(odd_dir .. "/root.json", vim.json.encode({ v = 1, root = gone }))
  vim.fn.delete(gone, "rf")
  vim.fn.delete(busy, "rf")
  vim.fn.delete(tmp .. "/wt-old", "rf")

  local code, out = run({ "prune", "--dry-run", "--state-dir=" .. base })
  eq(code, 0, "dry run: exit 0")
  ok(out:find("would remove " .. vim.fs.basename(gone_dir), 1, true) ~= nil, "dry run: names it")
  ok(vim.uv.fs_stat(gone_dir) ~= nil, "dry run: removes nothing")

  code, out = run({ "prune", "--state-dir=" .. base })
  eq(code, 0, "prune: exit 0")
  eq(vim.uv.fs_stat(gone_dir), nil, "prune: the folder of a project that is gone is removed")
  ok(vim.uv.fs_stat(kept_dir) ~= nil, "prune: a project that is there keeps its folder")
  ok(
    vim.uv.fs_stat(busy_dir) ~= nil,
    "prune: a fresh lock keeps the folder (a run may write there)"
  )
  ok(vim.uv.fs_stat(unmarked_dir) ~= nil, "prune: a folder without a marker is left alone")
  ok(vim.uv.fs_stat(foreign_dir) ~= nil, "prune: a marker of another folder removes nothing")
  ok(vim.uv.fs_stat(odd_dir) ~= nil, "prune: a folder of another name form is not looked at")
  ok(
    out:find("1 removed, 1 kept (project there), 1 without a marker", 1, true) ~= nil,
    "prune: the tally: " .. out
  )
  ok(out:find("a lock there is fresh", 1, true) ~= nil, "prune: the busy folder is named")

  -- an old lock is a crashed run's: the folder goes
  local lock = busy_dir .. "/ci-commit/x.json.lock"
  local old = os.time() - prune.BUSY_S - 60
  vim.uv.fs_utime(lock, old, old)
  run({ "prune", "--state-dir=" .. base })
  eq(vim.uv.fs_stat(busy_dir), nil, "prune: a lock older than BUSY_S does not keep it")

  eq(select(1, run({ "prune", "--bogus" })), 2, "usage: an unknown argument is exit 2")
  eq(select(1, run({})), 2, "usage: no subcommand is exit 2")
  vim.fn.delete(tmp, "rf")
end
