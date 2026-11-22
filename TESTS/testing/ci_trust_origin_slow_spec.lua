-- TESTS/testing/ci_trust_origin_slow_spec.lua -- `testing ci trust --pushed` in a pre-push hook on a machine at 100 % CPU:
-- a `git remote get-url origin` that runs out of its first wait is asked once more with a longer one, and when git
-- still does not answer the hook says so instead of "no origin to name a repository". Driven with a stubbed
-- `vim.system` (a timeout is what `SystemObj:wait` reports: code 124 after SIGTERM); nothing is released or written.

---@diagnostic disable: duplicate-set-field

-- @cache-allow spawn
-- (`vim.system` is replaced by a stub: no process starts)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local guard = require("testing.ci.runner_guard")
  local TIMEOUT = { code = 124, signal = 15, stdout = "", stderr = "" }
  local URL =
    { code = 0, signal = 0, stdout = "https://github.com/WKDSteve/docmap.nvim.git\n", stderr = "" }

  ---@param answers table[] The answer of the n-th start of git.
  local function stub(answers)
    local real = vim.system
    local waits = {}
    vim.system = function()
      local n = #waits + 1
      return {
        wait = function(_, ms)
          waits[#waits + 1] = ms
          return answers[n] or TIMEOUT
        end,
      }
    end
    return waits, function()
      vim.system = real
    end
  end

  -- ---- the first wait runs out, the longer one answers --------------------------------------------------------
  do
    local waits, restore = stub({ TIMEOUT, URL })
    local repo, why = guard.repo_of_cwd(nil, "/wt")
    restore()
    eq(repo, "WKDSteve/docmap.nvim", "the origin is found on the second, longer wait")
    eq(why, nil, "and there is nothing to explain")
    ok(#waits == 2 and waits[2] > waits[1], "the second wait is longer: " .. vim.inspect(waits))
  end

  -- ---- an answer at once: one start only --------------------------------------------------------------------
  do
    local waits, restore = stub({ URL })
    local repo = guard.repo_of_cwd(nil, "/wt")
    restore()
    eq(repo, "WKDSteve/docmap.nvim", "an answer at once")
    eq(#waits, 1, "starts git once")
  end

  -- ---- no origin at all is still "no origin", without a second start ----------------------------------------
  do
    local waits, restore =
      stub({ { code = 2, signal = 0, stdout = "", stderr = "error: No such remote" } })
    local repo, why = guard.repo_of_cwd(nil, "/wt")
    restore()
    ok(repo == nil and why == nil, "a missing origin is no timeout")
    eq(#waits, 1, "and is not asked twice")
  end

  -- ---- git never answers: the hook says so ------------------------------------------------------------------
  do
    local _, restore = stub({})
    local errs = {}
    local code = guard.trust_pushed("", {
      out = function() end,
      err = function(s)
        errs[#errs + 1] = s
      end,
      cwd = "/wt",
    })
    restore()
    eq(code, 0, "the hook never fails the push")
    local text = table.concat(errs, "\n")
    ok(text:find("did not answer in time", 1, true) ~= nil, "it says git did not answer: " .. text)
    ok(not text:find("no origin to name", 1, true), "and not that there is no origin")
  end
end
