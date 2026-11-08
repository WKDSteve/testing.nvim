-- TESTS/testing/ci_workflow_spec.lua -- `testing init --workflow=public` (testing.ci.workflow): the workflow of a
-- public repository generated from `ci.workflow`. The output is byte for byte the workflow tasks.nvim had by hand
-- (golden), and the one of rules.nvim (publish job); a pull request never reaches the self-hosted runner; every value is
-- checked before it reaches the template; `--check` (and the step `workflow-in-sync`) is red when the file differs; an
-- existing file is kept unless `--force`.
-- @cache-inputs TESTS/testing/fixtures/ci_workflow/

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local read = require("lib.nvim.fs.read")
  local workflow = require("testing.ci.workflow")
  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local golden = here .. "/fixtures/ci_workflow"

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-workflow"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  ---A project named `name` (the directory name names the workflow) with `ci.workflow = <workflow>`.
  local function project(name, profile, wf, deps)
    local root = tmp .. "/" .. name
    write(root .. "/lua/proj/init.lua", "return {}\n")
    write(
      root .. "/.testing.lua",
      ("return { plugin = 'proj', deps = %s, ci = { default = 'full', profiles = { full = %s }, workflow = %s } }\n"):format(
        deps or "{ 'lib.nvim' }",
        profile,
        wf
      )
    )
    return root
  end
  local cli = require("testing.cli")
  ---`testing init <root> --workflow=public <args...>`
  local function call(root, ...)
    local out, err = {}, {}
    local code = cli.main(vim.list_extend({ "init", root, "--workflow=public" }, { ... }), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    })
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end

  -- golden: the workflow tasks.nvim had by hand, byte for byte (third-party checkout, Node, an env variable)
  do
    local root = project(
      "tasks.nvim",
      "{ 'suite', 'conformance' }",
      [[{
        platform = { "suite", "conformance" },
        node = { version = "22", used_by = "the Node contract check" },
        checkouts = { {
          repo = "folke/snacks.nvim",
          ref = "882c996cf28183f4d63640de0b4c02ec886d01f2",
          why = "The dashboard specs drive the real Snacks picker; without it they would pass with no assertion.",
        } },
        env = { TASKS_REQUIRE_SNACKS = "1" },
      }]]
    )
    local text, problems = workflow.render(root)
    eq(problems, {}, "tasks: no problem")
    ok(
      text == read(golden .. "/tasks.yml"),
      "tasks: byte for byte the workflow tasks.nvim had by hand"
    )
    -- the security rule: whatever the push legs are, a pull request only gets hosted runners
    local push, other = text:match("github.event_name == 'push' && '(.-)' || '(.-)'")
    has(push, '"runs-on":["self-hosted","windows"]', "a push runs on the self-hosted runner")
    ok(
      other and not other:find("self-hosted", 1, true),
      "every other event (a pull request) never does"
    )
    has(
      text,
      "never approve a pull request that touches `.github/`",
      "the header names the approval rule"
    )

    -- --check, --write
    local code, out = call(root, "--check")
    eq(code, 1, "--check without a file: exit 1")
    has(out, "workflow missing", "... says so")
    code, out = call(root)
    eq(
      { code, out },
      { 0, "created: .github/workflows/ci.yml" },
      "init --workflow=public creates it"
    )
    eq(read(root .. "/.github/workflows/ci.yml"), text, "... with the generated text")
    code, out = call(root, "--check")
    eq({ code, out }, { 0, "workflow in sync: .github/workflows/ci.yml" }, "--check: in sync")
    local edited = text:gsub("timeout%-minutes: 30", "timeout-minutes: 99")
    write(root .. "/.github/workflows/ci.yml", edited)
    code, out = call(root, "--check")
    eq(code, 1, "--check: a hand edit is exit 1")
    has(out, "-    timeout-minutes: 99", "... with the diff")
    has(out, "+    timeout-minutes: 30", "... both sides")
    code, out = call(root)
    eq(code, 0, "an existing file without --force: exit 0")
    has(out, "kept:", "... it is kept")
    eq(read(root .. "/.github/workflows/ci.yml"), edited, "... untouched")
    code, out = call(root, "--force")
    eq({ code, out }, { 0, "replaced: .github/workflows/ci.yml" }, "--force replaces it")
    eq(read(root .. "/.github/workflows/ci.yml"), text, "... with the generated text")
    eq(call(root, "--force", "--check"), 2, "--force and --check exclude each other")
    eq(call(root, "--update"), 2, "--workflow=public takes no --update")
  end

  -- golden: rules.nvim (a third platform step, the job that moves ci-verified)
  do
    local root = project(
      "rules.nvim",
      "{ 'suite', 'conformance', 'contracts' }",
      [[{
        platform = { "suite", "conformance", "contracts" },
        publish = { why = "docmap.nvim checks this repository out to run the rules engine in its standalone gate." },
      }]]
    )
    write(
      root .. "/.testing.lua",
      read(root .. "/.testing.lua"):gsub(
        "ci = {",
        "ci = { steps = { contracts = { run = { 'true' } } },",
        1
      )
    )
    local text, problems = workflow.render(root)
    eq(problems, {}, "rules: no problem")
    ok(text == read(golden .. "/rules.yml"), "rules: the golden workflow")
    has(text, "--step=suite,conformance,contracts", "the platform steps on the hosted legs")
    has(text, "publish-ci-verified:", "the publish job")
    has(text, "docmap.nvim checks this repository out", "... with why")
  end

  -- every value is checked before it reaches the template
  do
    local function refused(wf, needle, msg)
      local cfg, problems = workflow.validate(wf)
      eq(cfg, nil, msg .. ": refused")
      has(table.concat(problems, "\n"), needle, msg)
    end
    refused({ bogus = 1 }, "unknown key bogus", "an unknown key")
    refused({ platform = {} }, ".platform", "no platform step")
    refused({ platform = { "a b" } }, ".platform[1]", "a step name with a blank")
    refused(
      { checkouts = { { repo = "x", ref = ("a"):rep(40) } } },
      "owner/name",
      "a repo without owner"
    )
    refused(
      { checkouts = { { repo = "o/x", ref = "main" } } },
      "full commit id",
      "a third-party checkout by branch"
    )
    refused(
      { checkouts = { { repo = "o/x", ref = ("a"):rep(40), why = "two\nlines" } } },
      ".why",
      "a newline in a comment"
    )
    refused({ env = { CI_STEPS = "x" } }, "CI_STEPS", "an env name the step sets itself")
    refused({ env = { lower = "x" } }, "lower", "an env name that is no NAME")
    refused({ env = { A = "x\ny" } }, ".env.A", "a newline in an env value")
    refused(
      { node = { version = "latest", used_by = "x" } },
      ".node",
      "a node version that is no number"
    )
    refused({ publish = "yes" }, ".publish", "publish that is neither true nor a table")
    refused({ timeout = 0 }, ".timeout", "a timeout of 0")
    local root = project("noflow.nvim", "{ 'suite' }", "nil")
    local text, problems = workflow.render(root)
    eq(text, nil, "no ci.workflow: nothing generated")
    has(table.concat(problems), "has no ci.workflow", "... and why")
    root = project("badplat.nvim", "{ 'suite' }", "{ platform = { 'suite', 'conformance' } }")
    problems = select(2, workflow.render(root))
    has(
      table.concat(problems or {}),
      "conformance is no step of the profile full",
      "a platform step outside the default profile"
    )
  end

  -- the step `workflow-in-sync`: a pipeline that names it is red when the workflow differs
  do
    local root =
      project("insync.nvim", "{ 'workflow-in-sync' }", "{ platform = { 'workflow-in-sync' } }")
    eq(call(root), 0, "workflow-in-sync: the workflow is written")
    local state = tmp .. "/state"
    local function ci()
      local out = {}
      local code = cli.main({ "ci", "--root=" .. root, "--no-agent", "--state-dir=" .. state }, {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          out[#out + 1] = s
        end,
        state_dir = state,
        color = false,
      })
      return code, table.concat(out, "\n")
    end
    local code, out = ci()
    eq(code, 0, "workflow-in-sync: green while the file is the generated one: " .. out)
    write(root .. "/.github/workflows/ci.yml", "name: CI\n")
    code, out = ci()
    eq(code, 1, "workflow-in-sync: red once it differs")
    has(out, "workflow-in-sync", "... naming the step")
  end

  vim.fn.delete(tmp, "rf")
end
