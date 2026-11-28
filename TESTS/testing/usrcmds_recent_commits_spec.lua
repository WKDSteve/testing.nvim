-- TESTS/testing/usrcmds_recent_commits_spec.lua -- the completion of `:Testing ci commit <sha>` must not freeze the
-- editor: `recent_commits` asked `git log` and waited up to 2 s on every <Tab> (109 ms measured by `testing perf`).
-- It now answers from a cache per root and asks git in the background; the next <Tab> has the answer.

return function(H)
  local eq = H.eq
  local usrcmds = require("testing.bindings.usrcmds")

  local calls, pending = {}, {}
  local saved = usrcmds.recent_system
  usrcmds.recent_system = function(argv, opts, on_exit)
    calls[#calls + 1] = { argv = argv, cwd = opts and opts.cwd }
    pending[#pending + 1] = on_exit
    return {
      wait = function()
        error("recent_commits waited for git: the completion froze the editor")
      end,
    }
  end
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-recent"
  local ok, err = pcall(function()
    eq(
      usrcmds.recent_commits(root),
      { "HEAD" },
      "first <Tab>: HEAD at once, git runs in the background"
    )
    eq(#calls, 1, "git is asked once")
    eq(calls[1].argv[2], "log", "... with git log")
    eq(type(pending[1]), "function", "... in the background (a callback, no wait)")
    eq(usrcmds.recent_commits(root), { "HEAD" }, "a second <Tab> while git runs: no second git")
    eq(#calls, 1, "... still one call")
    pending[1]({ code = 0, stdout = "abc1234\ndef5678\n" })
    eq(
      usrcmds.recent_commits(root),
      { "HEAD", "abc1234", "def5678" },
      "the next <Tab>: the commits git gave"
    )
    eq(#calls, 1, "... from the cache, no new git")
    -- a failed git: HEAD only, and not asked again on every <Tab>
    local other = root .. "-2"
    usrcmds.recent_commits(other)
    pending[2]({ code = 128, stdout = "", stderr = "not a git repository" })
    eq(usrcmds.recent_commits(other), { "HEAD" }, "no repository: HEAD only")
    eq(#calls, 2, "... and git is not asked again at once")
  end)
  usrcmds.recent_system = saved
  usrcmds.recent_reset()
  assert(ok, err)
end
