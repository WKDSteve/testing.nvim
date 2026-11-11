-- TESTS/testing/metrics_repo_name_spec.lua -- the name a line of `testing.metrics` carries for its repository
-- (`metrics.repo_name`): a linked worktree counts for its main checkout, never under the name of the worktree's folder;
-- a checkout, a submodule and a folder without git keep their directory name.

---@diagnostic disable: need-check-nil

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    return ok(a == b, ("%s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a)))
  end
  local metrics = require("testing.metrics")
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-repo-name"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  -- the main checkout: .git is a directory
  local main = tmp .. "/proj.nvim"
  vim.fn.mkdir(main .. "/.git/worktrees/topic", "p")
  eq(metrics.repo_name(main), "proj.nvim", "a checkout")

  -- a linked worktree next to it, absolute gitdir (as git writes it), with and without CRLF
  local wt = tmp .. "/proj.nvim-topic"
  write(wt .. "/.git", "gitdir: " .. main .. "/.git/worktrees/topic\n")
  eq(metrics.repo_name(wt), "proj.nvim", "a worktree counts for its main checkout")
  write(wt .. "/.git", "gitdir: " .. main .. "/.git/worktrees/topic\r\n")
  eq(metrics.repo_name(wt), "proj.nvim", "a worktree, CRLF")
  eq(metrics.repo_name(wt .. "/"), "proj.nvim", "a trailing slash")

  -- a relative gitdir
  local rel = tmp .. "/nested/tree"
  write(rel .. "/.git", "gitdir: ../../proj.nvim/.git/worktrees/topic\n")
  eq(metrics.repo_name(rel), "proj.nvim", "a relative gitdir")

  -- a submodule points into .git/modules: it is a repository of its own
  local sub = tmp .. "/proj.nvim/deps/sub"
  write(sub .. "/.git", "gitdir: ../../.git/modules/sub\n")
  eq(metrics.repo_name(sub), "sub", "a submodule keeps its name")

  -- a .git file that is no pointer, and no git at all
  local odd = tmp .. "/odd"
  write(odd .. "/.git", "something else\n")
  eq(metrics.repo_name(odd), "odd", "a .git file that is no pointer")
  vim.fn.mkdir(tmp .. "/plain", "p")
  eq(metrics.repo_name(tmp .. "/plain"), "plain", "no git")

  -- the export of a worktree reads the lines of its main checkout
  local file = tmp .. "/metrics.jsonl"
  write(file, vim.json.encode({
    v = 1,
    ts = "2026-11-01T10:00:00Z",
    kind = "suite",
    repo = "proj.nvim",
    duration_ms = 60000,
    verdict = "green",
  }) .. "\n")
  local doc, err = require("testing.export").repo(wt, {
    form = "local",
    state_dir = tmp .. "/state",
    metrics_file = file,
  })
  ok(doc ~= nil, "export of a worktree: " .. tostring(err))
  eq(doc and type(doc.metrics), "table", "export of a worktree: the lines of its repository")
  eq(doc and type(doc.metrics) == "table" and doc.metrics.runs, 1, "export of a worktree: one run")

  vim.fn.delete(tmp, "rf")
end
