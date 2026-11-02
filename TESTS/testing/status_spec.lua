-- TESTS/testing/status_spec.lua -- `testing status`: one verdict line, one line per repository, exit 0 only when every
-- repository is proven; nothing is run (the proof comes from `ci verify`, stubbed here); --json prints the overview
-- document; usage errors are exit 2.

---@diagnostic disable: need-check-nil, missing-fields, param-type-mismatch

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local status = require("testing.status")
  local overview = require("testing.ci.overview")
  local cli = require("testing.cli")

  local base = vim.fs.normalize(vim.fn.tempname()) .. "-status"
  local state = base .. "/state"
  local function repo(name)
    local dir = base .. "/" .. name
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "return {}" }, dir .. "/.testing.lua")
    return dir
  end
  local good, bad = repo("good.nvim"), repo("bad.nvim")
  local plain = base .. "/plain"
  vim.fn.mkdir(plain, "p")

  local real_verify = overview.deps.verify
  overview.deps.verify = function(dir)
    if dir:find("good.nvim", 1, true) then
      return { status = "verified", profile = "full", reasons = {} }
    end
    return { status = "changed", profile = "full", reasons = { "tree differs" } }
  end

  local function run(argv)
    local out, err = {}, {}
    local code = status.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local r = run({ good })
  eq(r.code, 0, "a proven repository: exit 0")
  has(r.out, "OK | 1 repository, 0 not proven", "the verdict line")
  has(r.out, "good.nvim", "and its line")
  has(r.out, "local proven", "with its state")

  r = run({ good, bad })
  eq(r.code, 1, "one repository not proven: exit 1")
  has(r.out, "NOT OK | 2 repositories, 1 not proven", "the verdict line counts them")
  has(r.out, "bad.nvim", "the other one is listed")
  has(r.out, "changed", "with the reason")

  r = run({ plain })
  eq(r.code, 1, "a directory without testing.nvim is not proven")
  has(r.out, "no testing.nvim", "and says so")

  r = run({ good, "--json" })
  eq(r.code, 0, "--json: exit 0 for a proven repository")
  local doc = vim.json.decode(r.out)
  eq(doc.repos[1]["local"].state, "proven", "--json: the overview document")

  r = run({ "--bogus" })
  eq(r.code, 2, "an unknown option: exit 2")
  r = run({ "--all", good })
  eq(r.code, 2, "--all with named repositories: exit 2")
  r = run({ "--help" })
  eq(r.code, 0, "--help")
  has(r.out, "usage: testing status", "prints the usage")

  -- through the command line, and nothing but the workstation's refusal changes it there
  local out = {}
  local code = cli.main({ "status", good }, {
    out = function(s)
      out[#out + 1] = s
    end,
    err = function() end,
    state_dir = state,
  })
  eq(code, 0, "testing status through the CLI")
  local errs = {}
  code = cli.main({ "status", good }, {
    out = function() end,
    err = function(s)
      errs[#errs + 1] = s
    end,
    state_dir = state,
    getenv = function(name)
      return name == "NVIM_MACHINE_ROLE" and "workstation" or nil
    end,
  })
  eq(code, 2, "status verifies with the repository's tools: refused on the workstation")
  ok(#errs > 0, "with a message")

  overview.deps.verify = real_verify
  vim.fn.delete(base, "rf")
end
