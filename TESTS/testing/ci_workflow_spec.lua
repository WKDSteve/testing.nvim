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
    -- rules.nvim and tasks.nvim have the wrapper: their legs run `scripts/ci.sh`
    write(root .. "/scripts/ci.sh", '#!/usr/bin/env bash\nexec scripts/test.sh ci "$@"\n')
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

  -- golden: the workflow tasks.nvim had by hand, byte for byte (third-party checkout, Node, an env variable). The
  -- project lies in a directory called `tree`, as a snapshot of `testing ci commit` does: the name comes from
  -- `ci.workflow`, never from the directory (it did, and every commit of tasks.nvim was a false regression)
  do
    local root = project(
      "tree",
      "{ 'suite', 'conformance' }",
      [[{
        name = "tasks.nvim",
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
    -- a run by hand replaces one GitHub left hanging; it gets the hosted legs (not "push") and its own
    -- concurrency group, so it never cancels a push run
    has(text, "\n  pull_request:\n  workflow_dispatch:\n", "public: a run by hand is possible")
    has(
      text,
      "group: ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}",
      "public: a run by hand does not cancel a push"
    )
    -- the security rule: whatever the push legs are, a pull request only gets hosted runners
    local push, other = text:match("github.event_name == 'push' && '(.-)' || '(.-)'")
    has(push, '"runs-on":["self-hosted","windows"]', "a push runs on the self-hosted runner")
    ok(
      other and not other:find("self-hosted", 1, true),
      "every other event (a pull request) never does"
    )
    -- the header promises a macOS leg on every event: a pull request gets one too
    has(other, '{"name":"macos","runs-on":"macos-latest"', "a pull request runs on macOS too")
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
        name = "rules.nvim",
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
    -- the job that pushes ci-verified never runs on the self-hosted runner: there it would hold write access on the
    -- maintainer's machine, whose global pre-push hook refuses the move from a shallow checkout
    local job = text:match("\n  publish%-ci%-verified:\n(.*)$")
    has(job, "runs-on: ubuntu-latest", "the publish job runs hosted")
    -- the lookup fails closed: a step without `shell:` runs `bash -e` without pipefail, so a failing
    -- `git ls-remote | cut -f1` would be an empty tip and fall through to the first-publish push without a lease
    local pipefail_at = job:find("\n          set -o pipefail\n", 1, true)
    local lookup_at = job:find("tip=$(git ls-remote", 1, true)
    ok(
      pipefail_at ~= nil and lookup_at ~= nil and pipefail_at < lookup_at,
      "the publish step sets pipefail before the ci-verified lookup"
    )
    for runs_on in job:gmatch("runs%-on:[^\n]*") do
      ok(
        not runs_on:find("self-hosted", 1, true),
        "... never on the self-hosted runner: " .. runs_on
      )
    end
  end

  -- the layouts: private (macOS by hand, no pull request) and hosted (no self-hosted runner, the result cache), each
  -- golden; every leg's job name lands in its column of `testing ci remote`, the publish job in none
  do
    local remote = require("testing.ci.remote")
    ---The legs of the matrix expression: `{ push = {...}, other = {...} }` (hosted: one list for every event).
    local function matrix(text)
      local pushed, other = text:match("github%.event_name == 'push' && '(%[.-%])' || '(%[.-%])'")
      if not pushed then
        local all = assert(text:match("fromJSON%('(%[.-%])'%)"), "a matrix")
        return { push = vim.json.decode(all), other = vim.json.decode(all) }
      end
      return { push = vim.json.decode(pushed), other = vim.json.decode(other) }
    end
    local function self_hosted(leg)
      return type(leg["runs-on"]) == "table" and vim.tbl_contains(leg["runs-on"], "self-hosted")
    end
    for _, layout in ipairs({ "private", "hosted" }) do
      local root = project(
        layout,
        "{ 'suite', 'conformance' }",
        ('{ name = "demo.nvim", layout = %q, publish = true }'):format(layout)
      )
      local text, problems = workflow.render(root)
      eq(problems, {}, layout .. ": no problem")
      ok(text == read(golden .. "/" .. layout .. ".yml"), layout .. ": the golden workflow")
      local legs = matrix(text)
      for _, leg in ipairs(vim.list_extend(vim.deepcopy(legs.push), legs.other)) do
        eq(
          remote.job_os({
            name = "testing ci (" .. leg.name .. ")",
            labels = self_hosted(leg) and leg["runs-on"] or { leg["runs-on"] },
          }),
          leg.name,
          layout .. ": ci remote puts the leg " .. leg.name .. " in its column"
        )
        eq(
          leg.hosted,
          not self_hosted(leg),
          layout .. ": hosted means no local runner: " .. leg.name
        )
      end
      eq(
        remote.job_os({ name = "publish ci-verified branch", labels = { "ubuntu-latest" } }),
        "other",
        layout .. ": the publish job is no leg"
      )
      for _, leg in ipairs(legs.other) do
        ok(
          not self_hosted(leg),
          layout .. ": no other event reaches the local runner: " .. leg.name
        )
      end
      for line in text:gmatch("[^\n]+") do
        if line:match("^%s*#") then
          ok(#line <= workflow.WIDTH, layout .. ": a comment line is at most 120 wide: " .. line)
        end
      end
      if layout == "private" then
        has(text, "\n  workflow_dispatch:\n", "private: macOS runs by hand")
        ok(not text:find("\n  pull_request:", 1, true), "private: no paid pull-request legs")
        eq(#legs.push, 1, "private: a push has one leg")
        ok(self_hosted(legs.push[1]), "private: ... on the local runner")
        eq(legs.other[1].name, "macos", "private: the run by hand is macOS")
        has(text, "means green on Windows", "private: ci-verified says what it covers")
      else
        ok(not text:find('"self-hosted"', 1, true), "hosted: no leg on a self-hosted runner")
        has(text, "actions/cache/restore@", "hosted: the result cache is restored")
        has(text, "actions/cache/save@", "hosted: ... and saved")
        has(
          text,
          "if: success() && github.event_name == 'push' && github.ref == 'refs/heads/main'",
          "hosted: ... only by a push to main"
        )
        has(text, '"--json=$env:CI_IR" --cached', "hosted: the suite uses it")
        eq(#legs.push, 3, "hosted: three systems")
      end
    end
    local bad =
      project("badlayout", "{ 'suite', 'conformance' }", '{ name = "x", layout = "cloud" }')
    local text, problems = workflow.render(bad)
    eq(text, nil, "an unknown layout: nothing is generated")
    has(problems[1], ".layout", "... and the problem names the key")
  end

  -- land = true (testing ci land): a check branch ci/** runs hosted legs, a push to main of a commit that was green
  -- there only publishes; without it the file is the same as before (the goldens above)
  do
    for _, layout in ipairs({ "hosted", "public" }) do
      local root = project(
        "land-" .. layout,
        "{ 'suite', 'conformance' }",
        ('{ name = "demo.nvim", layout = %q, publish = true, land = true }'):format(layout)
      )
      local text, problems = workflow.render(root)
      eq(problems, {}, layout .. " land: no problem")
      has(
        text,
        '    branches: [main, "ci/**"]\n',
        layout .. " land: a push to ci/** runs the workflow"
      )
      has(
        text,
        "\n  already-verified:\n",
        layout .. " land: the job that finds an earlier green run"
      )
      has(
        text,
        'select(.name == env.WORKFLOW and (.head_branch | startswith(\\"ci/\\")))',
        layout .. " land: ... of this workflow on a ci/ branch"
      )
      has(text, "    needs: [already-verified]\n", layout .. " land: the legs wait for that answer")
      has(
        text,
        "if: ${{ !cancelled() && needs.already-verified.outputs.verified != 'true' }}",
        layout .. " land: ... and are skipped when it was green already"
      )
      has(text, "needs: [already-verified, pipeline]", layout .. " land: publish waits for both")
      has(
        text,
        "(needs.pipeline.result == 'skipped' && needs.already-verified.outputs.verified == 'true')",
        layout .. " land: publish also runs for a commit that was green on ci/**"
      )
      has(
        text,
        "github.event_name == 'push' && github.ref == 'refs/heads/main' && (needs.pipeline.result",
        layout .. " land: publish only on main"
      )
      for line in text:gmatch("[^\n]+") do
        if line:match("^%s*#") then
          ok(
            #line <= workflow.WIDTH,
            layout .. " land: a comment line is at most 120 wide: " .. line
          )
        end
      end
      if layout == "public" then
        -- only a push to MAIN reaches the self-hosted runner: a push to ci/** gets the hosted legs
        local main_legs, other =
          text:match("github%.ref == 'refs/heads/main' && '(%[.-%])' || '(%[.-%])'")
        ok(main_legs ~= nil, "public land: the self-hosted legs need a push to main")
        ok(
          other and not other:find("self-hosted", 1, true),
          "public land: a push to ci/** runs no leg on the local runner"
        )
      end
    end
    local function refused(wf, needle, msg)
      local cfg, problems = workflow.validate(wf)
      eq(cfg, nil, msg .. ": refused")
      has(table.concat(problems, "\n"), needle, msg)
    end
    refused(
      { name = "x", layout = "private", publish = true, land = true },
      "not with layout",
      "land: not private"
    )
    -- without publish: the legs are skipped on main all the same, there is just nothing to publish
    local nopub = project(
      "land-nopublish",
      "{ 'suite', 'conformance' }",
      '{ name = "demo.nvim", layout = "hosted", land = true }'
    )
    local nptext, npproblems = workflow.render(nopub)
    eq(npproblems, {}, "land without publish: no problem")
    has(nptext, "\n  already-verified:\n", "land without publish: the legs still skip on main")
    ok(
      not nptext:find("\n  publish-ci-verified:\n", 1, true),
      "land without publish: no publish job"
    )
    refused({ name = "x", land = "yes" }, ".land: true or false", "land: a boolean")
    eq(workflow.validate({ name = "x" }).land, false, "land: off by default")
  end

  -- every value is checked before it reaches the template
  do
    local function refused(wf, needle, msg)
      local cfg, problems = workflow.validate(wf)
      eq(cfg, nil, msg .. ": refused")
      has(table.concat(problems, "\n"), needle, msg)
    end
    refused({ bogus = 1 }, "unknown key bogus", "an unknown key")
    refused({ platform = { "suite" } }, ".name", "no name (the directory never names the workflow)")
    refused({ name = "a/b" }, ".name", "a name with a slash")
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
    root = project(
      "badplat.nvim",
      "{ 'suite' }",
      "{ name = 'badplat.nvim', platform = { 'suite', 'conformance' } }"
    )
    problems = select(2, workflow.render(root))
    has(
      table.concat(problems or {}),
      "conformance is no step of the profile full",
      "a platform step outside the default profile"
    )

    -- more checkouts below .deps/: a repository of the owner may follow ci-verified (or be pinned, and says why),
    -- third-party code is always pinned
    root = project(
      "extra.nvim",
      "{ 'suite' }",
      "{ name = 'extra.nvim', platform = { 'suite' }, checkouts = { { repo = 'WKDSteve/hover.nvim', ref = 'ci-verified', why = 'only the sheets load it' }, { repo = 'WKDSteve/open.nvim', ref = '"
        .. ("b"):rep(40)
        .. "' } } }"
    )
    text, problems = workflow.render(root)
    ok(text ~= nil, "own checkouts: generated (" .. table.concat(problems or {}, "; ") .. ")")
    text = text or ""
    has(
      text,
      "      # only the sheets load it\n"
        .. "      - uses: actions/checkout@"
        .. workflow.ACTIONS.checkout
        .. "\n        with:\n          persist-credentials: false\n          repository: WKDSteve/hover.nvim\n"
        .. "          path: .deps/hover.nvim\n          ref: ci-verified\n",
      "own checkouts: ci-verified, below .deps/, no pin comment"
    )
    has(
      text,
      "          path: .deps/open.nvim\n          # Pinned: a commit whose own CI was green",
      "own checkouts: a pinned one of the owner is not called third-party"
    )
    -- a dependency that checkouts names too (a third-party plugin the specs load) comes from that pinned line, never as
    -- WKDSteve/<name>@ci-verified (cmdlog.nvim: deps lists telescope.nvim and plenary.nvim)
    root = project(
      "thirddep.nvim",
      "{ 'suite' }",
      "{ name = 'thirddep.nvim', platform = { 'suite' }, checkouts = { { repo = 'nvim-telescope/telescope.nvim', ref = '"
        .. ("c"):rep(40)
        .. "', why = 'the picker specs need it' } } }",
      "{ 'lib.nvim', 'telescope.nvim' }"
    )
    text, problems = workflow.render(root)
    ok(text ~= nil, "third-party dep: generated (" .. table.concat(problems or {}, "; ") .. ")")
    text = text or ""
    ok(
      not text:find("repository: WKDSteve/telescope.nvim", 1, true),
      "third-party dep: no WKDSteve/telescope.nvim"
    )
    has(
      text,
      "          repository: nvim-telescope/telescope.nvim\n          path: .deps/telescope.nvim\n",
      "third-party dep: the checkout below .deps/"
    )
    has(text, "ref: " .. ("c"):rep(40), "third-party dep: ... at its pin")
    has(
      text,
      "repository: WKDSteve/lib.nvim",
      "third-party dep: the other deps stay at ci-verified"
    )
    root = project(
      "foreign.nvim",
      "{ 'suite' }",
      "{ name = 'foreign.nvim', platform = { 'suite' }, checkouts = { { repo = 'folke/snacks.nvim', ref = 'ci-verified' } } }"
    )
    text, problems = workflow.render(root)
    eq(text, nil, "third-party ci-verified: refused")
    has(
      table.concat(problems or {}),
      "folke/snacks.nvim is no repository of WKDSteve",
      "third-party ci-verified: ... naming the repository"
    )
  end

  -- the step `workflow-in-sync`: a pipeline that names it is red when the workflow differs
  do
    local root = project(
      "insync.nvim",
      "{ 'workflow-in-sync' }",
      "{ name = 'insync.nvim', platform = { 'workflow-in-sync' } }"
    )
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

  -- packages: one step per system on every hosted leg, never on a self-hosted one, nothing without them -------------------
  do
    local function refused(wf, needle, msg)
      local cfg, problems = workflow.validate(wf)
      eq(cfg, nil, msg .. ": refused")
      has(table.concat(problems, "\n"), needle, msg)
    end
    eq(workflow.validate({ name = "x" }).packages, {}, "packages: none by default")
    refused({ name = "x", packages = "ripgrep" }, ".packages: expected a list", "packages: a list")
    refused({ name = "x", packages = { "ripgrep" } }, ".packages[1]: expected", "packages: tables")
    refused(
      { name = "x", packages = { { name = "ripgrep", why = "a", cmd = "x" } } },
      "unknown key cmd",
      "packages: no other key"
    )
    for _, bad in ipairs({ "rg; rm -rf /", "a b", "$(x)", "-y", "", "a&b", "x|y" }) do
      refused(
        { name = "x", packages = { { name = bad, why = "a" } } },
        ".packages[1].name",
        "packages: the name " .. vim.inspect(bad) .. " is no package name"
      )
    end
    refused(
      { name = "x", packages = { { name = "ripgrep" } } },
      ".packages[1].why",
      "packages: a reason"
    )
    refused(
      { name = "x", packages = { { name = "ripgrep", why = "line\nbreak" } } },
      ".packages[1].why",
      "packages: one line"
    )
    refused({
      name = "x",
      packages = { { name = "ripgrep", why = "a" }, { name = "ripgrep", why = "b" } },
    }, "ripgrep twice", "packages: no repeat")
    local many = {}
    for i = 1, workflow.MAX_PACKAGES + 1 do
      many[i] = { name = "p" .. i, why = "a" }
    end
    refused({ name = "x", packages = many }, "at most", "packages: a limit")

    local with = project(
      "with-packages",
      "{ 'suite', 'conformance' }",
      '{ name = "demo.nvim", layout = "public", packages = { { name = "ripgrep", why = "insights.nvim scans with it" } } }'
    )
    local text, problems = workflow.render(with)
    eq(problems, {}, "packages: no problem")
    has(text, "# ripgrep: insights.nvim scans with it\n", "packages: the reason is above the steps")
    has(
      text,
      "if: matrix.hosted && runner.os == 'Linux'\n        run: sudo apt-get install -y ripgrep",
      "packages: apt"
    )
    has(
      text,
      "if: matrix.hosted && runner.os == 'macOS'\n        run: brew install ripgrep",
      "packages: brew"
    )
    has(
      text,
      "if: matrix.hosted && runner.os == 'Windows'\n        run: choco install ripgrep -y --no-progress",
      "packages: choco"
    )
    -- one apt-get update per leg, before the first install (a stale index of the image fails a package it lacks)
    local update =
      "      - name: Update the apt index\n        if: matrix.hosted && runner.os == 'Linux'\n        run: sudo apt-get update -q\n"
    has(text, update, "packages: the apt index is updated")
    ok(
      (text:find(update, 1, true) or math.huge)
        < text:find("sudo apt-get install -y ripgrep", 1, true),
      "packages: the update comes before the install"
    )
    local before = project(
      "without-packages",
      "{ 'suite', 'conformance' }",
      '{ name = "demo.nvim", layout = "public" }'
    )
    local plain = workflow.render(before)
    ok(
      not plain:find("Install ripgrep", 1, true),
      "packages: a workflow without them has no such step"
    )
    ok(not plain:find("apt-get update", 1, true), "packages: no apt index update without packages")
    -- the step comes before the pipeline step that needs the program, and only that
    ok(
      text:find("Install ripgrep (Windows)", 1, true) < text:find("matrix.steps }}", 1, true),
      "packages: installed before the pipeline runs"
    )

    -- false: that system goes without (tmux: no choco package; the pty specs are n/a on Windows anyway)
    local skip = project(
      "skip-packages",
      "{ 'suite', 'conformance' }",
      '{ name = "demo.nvim", layout = "public", packages = { { name = "tmux", choco = false, why = "the pty specs" } } }'
    )
    local skip_text, skip_problems = workflow.render(skip)
    eq(skip_problems, {}, "packages false: no problem")
    has(skip_text, "Install tmux (Linux)", "packages false: apt stays")
    has(skip_text, "Install tmux (macOS)", "packages false: brew stays")
    ok(not skip_text:find("Install tmux (Windows)", 1, true), "packages false: no choco step")
    refused({
      name = "x",
      packages = { { name = "t", why = "a", apt = false, brew = false, choco = false } },
    }, "installs it nowhere", "packages false: not on every system")
    refused(
      { name = "x", packages = { { name = "t", why = "a", apt = true } } },
      ".packages[1].apt",
      "packages: true is no package name"
    )
    -- npm: one step on every hosted leg
    local npm = project(
      "npm-packages",
      "{ 'suite', 'conformance' }",
      '{ name = "demo.nvim", layout = "public", packages = { { name = "ts-ls", npm = { "typescript@5", "typescript-language-server", "@scope/pkg@1.2" }, why = "the live probe" } } }'
    )
    local npm_text, npm_problems = workflow.render(npm)
    eq(npm_problems, {}, "packages npm: no problem")
    has(
      npm_text,
      "      - name: Install ts-ls (npm)\n        if: matrix.hosted\n        run: npm install -g typescript@5 typescript-language-server @scope/pkg@1.2\n",
      "packages npm: one npm install on every hosted leg"
    )
    ok(not npm_text:find("apt-get install -y ts-ls", 1, true), "packages npm: no apt step")
    ok(not npm_text:find("apt-get update", 1, true), "packages npm: no apt index update either")
    for _, bad in ipairs({ "a b", "a;b", "$(x)", "-g", "a@1 && b", "../x", "a//b" }) do
      refused(
        { name = "x", packages = { { name = "t", why = "a", npm = { bad } } } },
        ".packages[1].npm[1]",
        "packages npm: " .. vim.inspect(bad) .. " is refused"
      )
    end
    refused(
      { name = "x", packages = { { name = "t", why = "a", npm = { "x" }, apt = "x" } } },
      "npm or apt/brew/choco",
      "packages npm: not together with a package manager"
    )
    refused(
      { name = "x", packages = { { name = "t", why = "a", npm = {} } } },
      ".packages[1].npm",
      "packages npm: at least one"
    )

    -- a name of its own per package manager where they differ (poppler: poppler-utils on apt)
    for _, pm in ipairs({ "apt", "brew", "choco" }) do
      refused(
        { name = "x", packages = { { name = "poppler", why = "a", [pm] = "a; b" } } },
        ".packages[1]." .. pm,
        "packages: the " .. pm .. " name is a package name too"
      )
    end
    eq(
      workflow.validate({
        name = "x",
        packages = { { name = "poppler", why = "a", apt = "poppler-utils" } },
      }).packages[1].apt,
      "poppler-utils",
      "packages: an apt name of its own is kept"
    )
    local own = project(
      "own-names",
      "{ 'suite', 'conformance' }",
      '{ name = "demo.nvim", layout = "public", packages = { { name = "poppler", apt = "poppler-utils", why = "pdftotext" } } }'
    )
    local own_text, own_problems = workflow.render(own)
    eq(own_problems, {}, "packages, own names: no problem")
    has(
      own_text,
      "run: sudo apt-get install -y poppler-utils\n",
      "packages, own names: apt takes its own"
    )
    has(own_text, "run: brew install poppler\n", "packages, own names: brew falls back to name")
    has(
      own_text,
      "run: choco install poppler -y --no-progress\n",
      "packages, own names: choco falls back to name"
    )
  end

  -- macOS: TMPDIR=/tmp on every repository's macOS leg (a socket below /var/folders/.../T/ exceeds sun_path) --------
  do
    local step =
      '      - if: runner.os == \'macOS\'\n        shell: bash\n        run: echo "TMPDIR=/tmp" >> "$GITHUB_ENV"\n'
    for _, layout in ipairs({ "public", "private", "hosted" }) do
      local text, problems = workflow.render(
        project(
          "tmpdir-" .. layout,
          "{ 'suite', 'conformance' }",
          ('{ name = "demo.nvim", layout = "%s" }'):format(layout)
        )
      )
      eq(problems, {}, "tmpdir " .. layout .. ": no problem")
      has(text, step, "tmpdir " .. layout .. ": the macOS leg gets TMPDIR=/tmp")
      ok(
        text:find(step, 1, true) < text:find("matrix.steps }}", 1, true),
        "tmpdir " .. layout .. ": before the pipeline step"
      )
    end
    -- an env.TMPDIR of the repository is the environment of the pipeline step itself, so it still decides
    local own = workflow.render(
      project(
        "tmpdir-own",
        "{ 'suite', 'conformance' }",
        '{ name = "demo.nvim", layout = "hosted", env = { TMPDIR = "/private/tmp" } }'
      )
    )
    has(own, '          TMPDIR: "/private/tmp"\n', "tmpdir: env.TMPDIR stays on the pipeline step")
  end

  -- setup: a command of the repository (an argv) that prepares a hosted leg before the pipeline; nothing without it ----
  do
    local function refused(wf, needle, msg)
      local cfg, problems = workflow.validate(wf)
      eq(cfg, nil, msg .. ": refused")
      has(table.concat(problems, "\n"), needle, msg)
    end
    eq(workflow.validate({ name = "x" }).setup, {}, "setup: none by default")
    local with = project(
      "with-setup",
      "{ 'suite', 'conformance' }",
      [[{ name = "demo.nvim", layout = "hosted", setup = {
        { run = { "bash", "scripts/ci-setup.sh", "--parsers" }, why = "builds the tree-sitter grammars of the call specs" },
        { run = { "bash", "scripts/link.sh", "a:b", "@x" }, why = "links lib.nvim", legs = "hosted" },
      } }]]
    )
    local text, problems = workflow.render(with)
    eq(problems, {}, "setup: no problem")
    has(
      text,
      "      # builds the tree-sitter grammars of the call specs\n"
        .. "      - name: Setup 1 (ci.workflow.setup)\n"
        .. "        if: matrix.hosted && matrix.steps == ''\n"
        .. "        shell: bash\n"
        .. "        run: |\n"
        .. "          bash scripts/ci-setup.sh --parsers\n",
      "setup: the full leg by default, the argv as one line of a block scalar"
    )
    has(
      text,
      "      - name: Setup 2 (ci.workflow.setup)\n        if: matrix.hosted\n",
      "setup: legs = hosted runs on every hosted leg"
    )
    -- a word YAML would read as its own (`a:`, `@x`) stays inside the block scalar
    has(text, "          bash scripts/link.sh a:b @x\n", "setup: the words as they are")
    ok(
      text:find("Setup 2 (ci.workflow.setup)", 1, true) < text:find("matrix.steps }}", 1, true),
      "setup: before the pipeline step (a script may write $GITHUB_ENV for it)"
    )
    ok(
      text:find("Setup 1 (ci.workflow.setup)", 1, true) > text:find("sha256sum -c", 1, true),
      "setup: after the tools (luacheck is on PATH for it)"
    )
    local plain = workflow.render(
      project(
        "without-setup",
        "{ 'suite', 'conformance' }",
        '{ name = "demo.nvim", layout = "hosted" }'
      )
    )
    ok(
      not plain:find("ci.workflow.setup", 1, true),
      "setup: a workflow without it has no such step"
    )

    refused({ name = "x", setup = "bash x.sh" }, ".setup: expected a list", "setup: a list")
    refused({ name = "x", setup = {} }, ".setup: expected a list", "setup: not empty")
    refused({ name = "x", setup = { "bash x.sh" } }, ".setup[1]: expected", "setup: tables")
    refused(
      { name = "x", setup = { { run = "bash x.sh", why = "a" } } },
      ".setup[1].run: a list",
      "setup: run is an argv, never a shell string"
    )
    for _, w in ipairs({
      "a b",
      "a;b",
      "$(x)",
      "`x`",
      "a&&b",
      "a|b",
      "x>y",
      "*",
      "'a'",
      '"a"',
      "a\\b",
      "",
    }) do
      refused(
        { name = "x", setup = { { run = { "bash", w }, why = "a" } } },
        ".setup[1].run[2]",
        "setup: the word " .. vim.inspect(w) .. " is refused"
      )
    end
    refused(
      { name = "x", setup = { { run = { "-c", "x" }, why = "a" } } },
      ".setup[1].run[1]: the program",
      "setup: the first word is the program"
    )
    refused(
      { name = "x", setup = { { run = { "bash", "x.sh" } } } },
      ".setup[1].why",
      "setup: a reason"
    )
    refused(
      { name = "x", setup = { { run = { "bash", "x.sh" }, why = "a", legs = "all" } } },
      ".setup[1].legs",
      "setup: legs full or hosted"
    )
    refused(
      { name = "x", setup = { { run = { "bash", "x.sh" }, why = "a", shell = "pwsh" } } },
      "unknown key shell",
      "setup: no other key"
    )
    local many = {}
    for i = 1, workflow.MAX_SETUP + 1 do
      many[i] = { run = { "bash", "x" .. i .. ".sh" }, why = "a" }
    end
    refused({ name = "x", setup = many }, ".setup: at most", "setup: at most MAX_SETUP")
  end

  -- min_nvim: one more hosted ubuntu leg on the promised minimum, only the suite; nothing changes without the key ------
  do
    local function refused(wf, needle, msg)
      local cfg, problems = workflow.validate(wf)
      eq(cfg, nil, msg .. ": refused")
      has(table.concat(problems, "\n"), needle, msg)
    end
    local base = { name = "x", layout = "hosted" }
    local function with(min)
      return vim.tbl_extend("force", base, { min_nvim = min })
    end
    refused(with("0.11.4"), ".min_nvim: expected", "min_nvim: a table")
    refused(with({ version = "v0.11.4", why = "a" }), ".min_nvim.version", "min_nvim: no v")
    refused(with({ version = "stable", why = "a" }), ".min_nvim.version", "min_nvim: a release")
    refused(with({ version = "0.11.4" }), ".min_nvim.why", "min_nvim: a reason")
    refused(
      with({ version = "0.11.4", why = "a", x = 1 }),
      "unknown key x",
      "min_nvim: no other key"
    )
    refused(
      { name = "x", layout = "public", min_nvim = { version = "0.11.4", why = "a" } },
      'only with layout = "hosted"',
      "min_nvim: hosted only"
    )

    local plain_root = project(
      "min-plain",
      "{ 'suite', 'conformance' }",
      '{ name = "demo.nvim", layout = "hosted" }'
    )
    local min_root = project(
      "min-leg",
      "{ 'suite', 'conformance' }",
      '{ name = "demo.nvim", layout = "hosted", min_nvim = { version = "0.11.4", why = "README badge" } }'
    )
    local plain = workflow.render(plain_root)
    local text, problems = workflow.render(min_root)
    eq(problems, {}, "min_nvim: no problem")
    has(
      text,
      ',{"name":"ubuntu-min","runs-on":"ubuntu-latest","hosted":true,"steps":"--step=suite","nvim":"0.11.4"}]\') }}\n',
      "min_nvim: the leg ends the matrix"
    )
    has(
      text,
      "nvim: v0.11.4 (README badge)",
      "min_nvim: a comment names the version (a spec can find it)"
    )
    has(
      text,
      "version: v${{ matrix.nvim || '" .. workflow.TOOLS.nvim .. "' }}\n",
      "min_nvim: the setup step takes the leg's version"
    )
    ok(
      not text:find("nvim" .. workflow.TOOLS.nvim .. "-", 1, true),
      "min_nvim: no cache key is left on the fixed version"
    )
    has(text, "nvim${{ matrix.nvim || '", "min_nvim: the cache keys carry the leg's version")
    has(
      plain,
      "version: v" .. workflow.TOOLS.nvim .. "\n",
      "min_nvim: without the key the setup step is unchanged"
    )
    ok(not plain:find("ubuntu-min", 1, true), "min_nvim: without the key there is no extra leg")
    ok(not plain:find("matrix.nvim", 1, true), "min_nvim: ... and no matrix.nvim")
  end

  -- luacheck is the release binary, checked against its pinned sum; no Lua from www.lua.org (it timed out)
  do
    local root = project("lc", "{ 'suite' }", [[{ name = "lc.nvim", platform = { "suite" } }]])
    local text = workflow.render(root)
    has(
      text,
      ('echo "%s  $RUNNER_TEMP/luacheck" | sha256sum -c -'):format(workflow.SHA256.luacheck),
      "luacheck: the download is checked against the pinned sum"
    )
    ok(not text:find("leafo/gh-actions-lua", 1, true), "luacheck: no Lua from www.lua.org")
    ok(not text:find("luarocks", 1, true), "luacheck: no luarocks")
    ok(not text:find("@@", 1, true), "luacheck: every placeholder is filled")
  end

  -- playwright: Chromium for the browser sheets on the full leg, outside the checkout; only when asked for
  do
    local root = project(
      "pw",
      "{ 'suite' }",
      [[{ name = "pw.nvim", platform = { "suite" },
          playwright = { version = "1.64.1", used_by = "the browser sheets" } }]]
    )
    local text, problems = workflow.render(root)
    eq(problems, {}, "playwright: no problem")
    has(text, "playwright-core@1.64.1", "playwright: that release of playwright-core")
    has(text, "install --with-deps chromium", "playwright: its Chromium")
    has(
      text,
      'echo "TESTING_PLAYWRIGHT_DIR=$RUNNER_TEMP/pw" >> "$GITHUB_ENV"',
      "playwright: the sheets find it"
    )
    has(
      text,
      "# the browser sheets: playwright-core 1.64.1",
      "playwright: the comment says who needs it"
    )
    local plain = workflow.render(
      project("nopw", "{ 'suite' }", [[{ name = "nopw.nvim", platform = { "suite" } }]])
    )
    ok(not plain:find("playwright", 1, true), "playwright: without the key nothing of it")
    local _, bad = workflow.render(
      project(
        "badpw",
        "{ 'suite' }",
        [[{ name = "badpw.nvim", platform = { "suite" }, playwright = { version = "latest", used_by = "x" } }]]
      )
    )
    has(
      table.concat(bad or {}, "; "),
      ".playwright: expected",
      "playwright: an inexact version is refused"
    )
  end

  -- luals: lua-language-server on the hosted full leg, the tarball checked against a pinned sum; nothing without it ---
  do
    local function refused(wf, needle, msg)
      local cfg, problems = workflow.validate(wf)
      eq(cfg, nil, msg .. ": refused")
      has(table.concat(problems, "\n"), needle, msg)
    end
    local function with(l)
      return { name = "x", luals = l }
    end
    refused(with("3.18.2"), ".luals: expected", "luals: a table")
    refused(
      with({ version = "latest", used_by = "a" }),
      ".luals: expected",
      "luals: an exact version"
    )
    refused(with({ version = "3.18.2" }), ".luals: expected", "luals: who needs it")
    refused(
      with({ version = "3.18.2", used_by = "a", sha256 = "00" }),
      "unknown key sha256",
      "luals: no sum of its own (the table pins it)"
    )
    refused(
      with({ version = "3.17.0", used_by = "a" }),
      "3.17.0 has no pinned sha256",
      "luals: a version without a pinned sum is refused"
    )

    local text, problems = workflow.render(
      project(
        "luals",
        "{ 'suite' }",
        [[{ name = "luals.nvim", layout = "hosted", platform = { "suite" },
            luals = { version = "3.18.2", used_by = "scripts/luals-check.sh" } }]]
      )
    )
    eq(problems, {}, "luals: no problem")
    local step = table.concat({
      "      # scripts/luals-check.sh: lua-language-server 3.18.2, the release tarball of LuaLS checked against its pinned",
      "      # sha256 (testing.ci.workflow.SHA256.luals), on the leg with the whole profile.",
      "      - if: matrix.hosted && matrix.steps == ''",
      "        shell: bash",
      "        run: |",
      '          tarball="$RUNNER_TEMP/luals.tar.gz"',
      '          curl -fsSL -o "$tarball" "https://github.com/LuaLS/lua-language-server/releases/download/3.18.2/lua-language-server-3.18.2-linux-x64.tar.gz"',
      '          echo "ca71415dd19f19e30aaa35a4915aefca9fdb5fec31b98331cc3d77f778d539c5  $tarball" | sha256sum -c -',
      '          mkdir -p "$RUNNER_TEMP/luals"',
      '          tar -xzf "$tarball" -C "$RUNNER_TEMP/luals"',
      '          echo "$RUNNER_TEMP/luals/bin" >> "$GITHUB_PATH"',
      "",
    }, "\n")
    has(text, step, "luals: one step on the hosted full leg, checked before it is unpacked")
    ok(
      text:find(step, 1, true) < text:find("matrix.steps }}", 1, true),
      "luals: installed before the pipeline step"
    )
    local plain = workflow.render(
      project(
        "noluals",
        "{ 'suite' }",
        [[{ name = "luals.nvim", layout = "hosted", platform = { "suite" } }]]
      )
    )
    ok(not plain:find("lua-language-server", 1, true), "luals: without the key nothing of it")
    -- the only difference the key makes is the step (the goldens above stay byte for byte without it)
    eq((text:gsub(vim.pesc(step), "", 1)), plain, "luals: the step is the only difference")
  end

  -- artifacts: more files a hosted leg uploads (the screenshots of the browser sheets); golden; nothing without them ---
  do
    local function refused(wf, needle, msg)
      local cfg, problems = workflow.validate(wf)
      eq(cfg, nil, msg .. ": refused")
      has(table.concat(problems, "\n"), needle, msg)
    end
    local function one(a)
      return {
        name = "x",
        artifacts = {
          vim.tbl_extend("force", { name = "shots", path = "out/*.png", why = "a" }, a),
        },
      }
    end
    eq(workflow.validate({ name = "x" }).artifacts, {}, "artifacts: none by default")
    refused({ name = "x", artifacts = "out" }, ".artifacts: expected a list", "artifacts: a list")
    refused({ name = "x", artifacts = {} }, ".artifacts: expected a list", "artifacts: not empty")
    for _, bad in ipairs({
      "../secret",
      "out/../../x",
      "/etc/passwd",
      "C:/x",
      "${{ secrets.GITHUB_TOKEN }}",
      "a b",
      "out\n- x",
      "-x",
      "./out",
      "a//b",
      "",
    }) do
      refused(one({ path = bad }), ".artifacts[1].path", "artifacts: the path " .. vim.inspect(bad))
    end
    for _, bad in ipairs({ "ci", "a b", "-x", "", "a/b" }) do
      refused(one({ name = bad }), ".artifacts[1].name", "artifacts: the name " .. vim.inspect(bad))
    end
    refused(one({ why = "line\nbreak" }), ".artifacts[1].why", "artifacts: one line of why")
    refused(one({ when = "success" }), ".artifacts[1].when", "artifacts: always or failure")
    refused(one({ legs = "self-hosted" }), ".artifacts[1].legs", "artifacts: full or hosted")
    refused(one({ retention = 90 }), "unknown key retention", "artifacts: no other key")
    refused({
      name = "x",
      artifacts = { { name = "a", path = "x", why = "a" }, { name = "a", path = "y", why = "b" } },
    }, "a twice", "artifacts: a name once")
    local many = {}
    for i = 1, workflow.MAX_ARTIFACTS + 1 do
      many[i] = { name = "a" .. i, path = "x", why = "a" }
    end
    refused({ name = "x", artifacts = many }, ".artifacts: at most", "artifacts: a limit")
    eq(
      workflow.validate(one({})).artifacts,
      { { name = "shots", path = "out/*.png", why = "a", when = "always", legs = "full" } },
      "artifacts: always and the full leg by default"
    )

    local wf = [[{ name = "shots.nvim", layout = "hosted", platform = { "suite" }, land = true,
        artifacts = {
          { name = "sheet-shots", path = "TESTS/sheets/out/**/*.png",
            why = "what the page looked like is the evidence a sheet leaves behind, red or green" },
          { name = "logs", path = "**/*.log", when = "failure", legs = "hosted", why = "the logs of a red leg" },
        } }]]
    local text, problems = workflow.render(project("artifacts", "{ 'suite' }", wf))
    eq(problems, {}, "artifacts: no problem")
    ok(text == read(golden .. "/artifacts.yml"), "artifacts: the golden workflow")
    has(
      text,
      "        if: always() && matrix.hosted && matrix.steps == ''\n        with:\n          name: sheet-shots-${{ matrix.name }}\n"
        .. '          path: "TESTS/sheets/out/**/*.png"\n',
      "artifacts: always, on the full leg, one name per leg"
    )
    has(
      text,
      '        if: failure() && matrix.hosted\n        with:\n          name: logs-${{ matrix.name }}\n          path: "**/*.log"\n',
      "artifacts: a leading * is quoted (no YAML alias), on a red hosted leg"
    )
    local plain =
      workflow.render(project("noartifacts", "{ 'suite' }", (wf:gsub("artifacts = %b{}", ""))))
    ok(not plain:find("sheet-shots", 1, true), "artifacts: without the key nothing of it")
    ok(
      select(2, plain:gsub("actions/upload%-artifact@", "")) == 1,
      "artifacts: without the key only the report is uploaded"
    )
  end

  vim.fn.delete(tmp, "rf")
end
