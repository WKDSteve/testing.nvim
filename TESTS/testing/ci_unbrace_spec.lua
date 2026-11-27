-- TESTS/testing/ci_unbrace_spec.lua -- `ci commit` reads `@upstream`, `@u` and `@push` that lost their braces (Git Bash
-- started by node or Python expands `{...}` in its own arguments) as `@{upstream}`, `@{u}`, `@{push}`: in --base,
-- --range, a revision and the commit ids that go to WSL2. A real repository, no network.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local snapshot = require("testing.ci.snapshot")
  local commit = require("testing.ci.commit")
  local wsl = require("testing.ci.wsl")

  local root = vim.fs.normalize(vim.fn.tempname()) .. "-unbrace"
  vim.fn.mkdir(root, "p")
  local function git(args)
    local res = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
    return vim.trim(res.stdout or "")
  end
  local function commit_empty(msg)
    git({ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", msg })
    return git({ "rev-parse", "HEAD" })
  end
  git({ "init", "-q", "-b", "main" })
  local a = commit_empty("a")
  git({ "branch", "up" })
  git({ "branch", "-q", "--set-upstream-to=up" })
  local b = commit_empty("b")

  local notes = {}
  local saved_note = snapshot.note
  snapshot.note = function(s)
    notes[#notes + 1] = s
  end

  eq(snapshot.resolve(root, "@{upstream}"), a, "resolve: @{upstream} as before")
  eq(#notes, 0, "resolve: ... without a note")
  eq(snapshot.resolve(root, "@upstream"), a, "resolve: @upstream (braces lost) is @{upstream}")
  ok(
    notes[1] and notes[1]:find("@upstream read as @{upstream}", 1, true) ~= nil,
    "resolve: ... and says so (" .. tostring(notes[1]) .. ")"
  )
  ok(notes[1] and notes[1]:find("MSYS=noglob", 1, true) ~= nil, "resolve: ... with the way out")
  eq(snapshot.resolve(root, "@u"), a, "resolve: @u is @{u}")
  eq(snapshot.resolve(root, "main@upstream"), a, "resolve: main@upstream is main@{upstream}")
  notes = {}
  eq(snapshot.resolve(root, "HEAD"), b, "resolve: an ordinary revision stays")
  eq(snapshot.unbrace(root, "main@other"), "main@other", "unbrace: another word stays")
  eq(snapshot.unbrace(root, "a{b}@u"), "a{b}@u", "unbrace: braces left elsewhere: stays")
  eq(#notes, 0, "unbrace: nothing said for what stays")

  -- a branch really called `@upstream` is what it names
  git({ "branch", "@upstream", b })
  eq(snapshot.resolve(root, "@upstream"), b, "resolve: a branch called @upstream wins")
  eq(#notes, 0, "resolve: ... without a note")
  git({ "branch", "-q", "-D", "@upstream" })

  -- --range, as `CI-04` spells it
  eq(
    commit.internal.range_shas(root, "@upstream..HEAD"),
    { b },
    "range: @upstream..HEAD is @{upstream}..HEAD"
  )

  -- --wsl: the commit ids that go into WSL2
  local saved_run = wsl.run_bash
  local seen
  wsl.run_bash = function(s)
    seen = s
    return 3, "", "fake"
  end
  commit.main(
    { "HEAD", "--base=@upstream", "--wsl", "--root=" .. root },
    { out = function() end, err = function() end }
  )
  wsl.run_bash = saved_run
  local inner = (seen or ""):match("ci commit (.-)\n") or ""
  ok(
    inner:find(("'--base=%s'"):format(a), 1, true) ~= nil,
    "wsl: --base=@upstream goes as the id of @{upstream} (" .. inner .. ")"
  )

  snapshot.note = saved_note
  vim.fn.delete(root, "rf")
end
