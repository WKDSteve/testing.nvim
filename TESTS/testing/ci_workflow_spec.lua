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
    -- the step comes before the pipeline step that needs the program, and only that
    ok(
      text:find("Install ripgrep (Windows)", 1, true) < text:find("matrix.steps }}", 1, true),
      "packages: installed before the pipeline runs"
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

  vim.fn.delete(tmp, "rf")
end
