---@module 'testing.ci.workflow'
---@brief `testing init --workflow=public`: the GitHub workflow of a public repository, generated from the `ci` section.
---@description
--- What is checked lives only in `.testing.lua`; the workflow only prepares the machine and runs `scripts/ci.sh` on
--- each leg. What was still written twice by hand (the checkouts of the dependencies, the tools and their versions, the
--- action SHAs, the choice of runner) is generated here, from `ci.workflow` of `.testing.lua` and the tables below.
---
---   ci = {
---     profiles = { ... },
---     workflow = {
---       name = "tasks.nvim",                        -- the repository (never the directory: a worktree is named otherwise)
---       platform = { "suite", "conformance" },     -- the steps that depend on the platform (hosted windows, macOS)
---       node = { version = "22", used_by = "the Node contract check" },   -- optional: Node on the hosted full legs
---       checkouts = {                               -- optional: more checkouts below .deps/ (third-party: pinned)
---         { repo = "folke/snacks.nvim", ref = "<40 hex>", why = "the dashboard specs drive the real picker" },
---       },
---       env = { TASKS_REQUIRE_SNACKS = "1" },       -- optional: environment of the pipeline step
---       publish = true,                             -- optional: the job that moves `ci-verified` (or { why = "..." })
---       timeout = 30,                               -- optional: minutes of a leg
---     },
---   }
---
--- The layout is the one of `docs/WORKFLOW-CI.md`: a push to main runs on the self-hosted Windows runner plus a
--- hosted macOS leg, a pull request (also from a fork) only on hosted runners, never on the self-hosted one.
---
---   testing init [<root>] --workflow=public            write `.github/workflows/ci.yml` (an existing one is kept)
---   testing init [<root>] --workflow=public --force    replace it
---   testing init [<root>] --workflow=public --check    compare it byte for byte, print a diff; exit 1 when it differs
---
--- A kind of `testing init --workflow`, not a `ci` verb: `testing init` writes the setup of a repository, `testing ci`
--- runs a pipeline (docs/WORKFLOW-CI.md). The step `workflow-in-sync` (a preset) is that `--check`: a repository that names it in a profile is red when its
--- workflow is no longer the one its `.testing.lua` gives. A repository without `ci.workflow` is not checked (opt-in).
--- `.testing.lua` is loaded through the project loader (the trust gate decides, as for `testing ci`); every value is
--- checked here before it reaches the template, and inserted in the quoting of YAML or as a vetted block.

local render = require("testing.scaffold.render")
local scaffold = require("testing.scaffold")

local M = {}

---Where the workflow lives.
M.PATH = ".github/workflows/ci.yml"

---Width the generated comments are wrapped at.
M.WIDTH = 120

---The versions the self-hosted runner has on its PATH; the hosted legs install exactly these.
M.TOOLS = { nvim = "0.12.2", stylua = "2.5.2", luacheck = "1.2.0", lua = "5.4" }

---The actions, pinned by commit (third-party code runs on the self-hosted runner too). Bump on purpose.
M.ACTIONS = {
  checkout = "fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5",
  setup_vim = "febef33995d6649302e9d88dda81e071b68f16a7 # v1",
  stylua = "76fd70c03e6340ceaf673366712db9b20560b402 # v5",
  lua = "6919171ccf181b826f44b9bca76307b577217377 # v13",
  luarocks = "35d062def313a7699a0d513e996bcf4352f05389 # v6",
  node = "249970729cb0ef3589644e2896645e5dc5ba9c38 # v6",
  upload = "cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7",
  cache = "0057852bfaa89a56745cba8c7296529d2fc39830 # v4",
}

---Where the legs run (`ci.workflow.layout`):
---  public   a push on the self-hosted runner plus hosted macOS; every other event (a pull request) only hosted runners
---  private  a push on the self-hosted runner; macOS hosted by hand (`workflow_dispatch`), no pull_request trigger
---  hosted   every event on hosted runners only (ubuntu, windows, macOS), with the result cache
M.LAYOUTS = { public = true, private = true, hosted = true }

---Environment names the pipeline step sets itself.
local RESERVED_ENV = { CI_STEPS = true, CI_REPORT = true, CI_IR = true }

local KEYS = {
  name = true,
  layout = true,
  platform = true,
  node = true,
  checkouts = true,
  env = true,
  publish = true,
  timeout = true,
}

---@class Testing.Ci.Workflow.Checkout
---@field repo string `owner/name`.
---@field ref string A full commit id.
---@field why? string One comment line above the checkout.

---@class Testing.Ci.Workflow.Config
---@field platform string[]
---@field node? { version: string, used_by: string }
---@field checkouts Testing.Ci.Workflow.Checkout[]
---@field env table<string, string>
---@field publish? { why?: string }
---@field timeout integer
---@field layout "public"|"private"|"hosted"
---@field name string The repository's name, for the header (never the directory's: a worktree or a clone is named
---otherwise).

---@param v any
---@return boolean
local function is_text(v)
  return type(v) == "string" and v ~= "" and #v <= 300 and not v:find("[%c]")
end

---@param v any
---@return boolean
local function is_list(v)
  if type(v) ~= "table" then
    return false
  end
  local n = 0
  for k in pairs(v) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  return n == #v
end

---Check `ci.workflow` and fill the defaults.
---@param raw any
---@return Testing.Ci.Workflow.Config|nil cfg
---@return string[] problems
function M.validate(raw)
  local problems = {}
  local function bad(fmt, ...)
    problems[#problems + 1] = ("ci.workflow" .. fmt):format(...)
  end
  if type(raw) ~= "table" then
    return nil, { ("ci.workflow: expected a table, got %s"):format(type(raw)) }
  end
  for k in pairs(raw) do
    if not KEYS[k] then
      bad(": unknown key %s", tostring(k))
    end
  end
  local cfg = {
    checkouts = {},
    env = {},
    timeout = 30,
    platform = { "suite", "conformance" },
    layout = "public",
  }
  if raw.layout ~= nil then
    if type(raw.layout) ~= "string" or not M.LAYOUTS[raw.layout] then
      bad('.layout: "public", "private" or "hosted"')
    else
      cfg.layout = raw.layout
    end
  end
  -- named, never taken from the directory: `ci commit` checks a snapshot in a directory called `tree`
  if type(raw.name) ~= "string" or not raw.name:match("^[%w][%w._-]*$") or #raw.name > 100 then
    bad('.name: the repository\'s name (name = "tasks.nvim"), letters, digits, ".", "_" and "-"')
  else
    cfg.name = raw.name
  end
  if raw.platform ~= nil then
    if not is_list(raw.platform) or #raw.platform == 0 then
      bad(".platform: expected a non-empty list of step names")
    else
      for i, name in ipairs(raw.platform) do
        if type(name) ~= "string" or not name:match("^[%a_][%w_%-]*$") then
          bad(".platform[%d]: not a step name", i)
        end
      end
      cfg.platform = raw.platform
    end
  end
  if raw.node ~= nil then
    local n = raw.node
    if
      type(n) ~= "table"
      or type(n.version) ~= "string"
      or not n.version:match("^%d+[%d.]*$")
      or not is_text(n.used_by)
    then
      bad('.node: expected { version = "22", used_by = "<what needs it, for a comment>" }')
    else
      for k in pairs(n) do
        if k ~= "version" and k ~= "used_by" then
          bad(".node: unknown key %s", tostring(k))
        end
      end
      cfg.node = { version = n.version, used_by = n.used_by }
    end
  end
  if raw.checkouts ~= nil then
    if not is_list(raw.checkouts) then
      bad(".checkouts: expected a list")
    else
      for i, c in ipairs(raw.checkouts) do
        if type(c) ~= "table" then
          bad(".checkouts[%d]: expected a table", i)
        else
          for k in pairs(c) do
            if k ~= "repo" and k ~= "ref" and k ~= "why" then
              bad(".checkouts[%d]: unknown key %s", i, tostring(k))
            end
          end
          if type(c.repo) ~= "string" or not c.repo:match("^[%w][%w._-]*/[%w][%w._-]*$") then
            bad(".checkouts[%d].repo: expected owner/name", i)
          elseif
            type(c.ref) ~= "string"
            or not (c.ref:match("^" .. ("%x"):rep(40) .. "$") or c.ref == scaffold.DEFAULT_REF)
          then
            bad(
              ".checkouts[%d].ref: expected a full commit id (third-party code is pinned) or %q (a repository of the owner)",
              i,
              scaffold.DEFAULT_REF
            )
          elseif c.why ~= nil and not is_text(c.why) then
            bad(".checkouts[%d].why: one line of text", i)
          else
            cfg.checkouts[#cfg.checkouts + 1] = { repo = c.repo, ref = c.ref, why = c.why }
          end
        end
      end
    end
  end
  if raw.env ~= nil then
    if type(raw.env) ~= "table" then
      bad(".env: expected a table")
    else
      for k, v in pairs(raw.env) do
        if type(k) ~= "string" or not k:match("^[A-Z_][A-Z0-9_]*$") or RESERVED_ENV[k] then
          bad(".env: %s is not a name the pipeline step may take", tostring(k))
        elseif type(v) ~= "string" or #v > 200 or v:find("[%c]") then
          bad(".env.%s: one line of text", k)
        else
          cfg.env[k] = v
        end
      end
    end
  end
  if raw.publish ~= nil and raw.publish ~= false then
    if raw.publish == true then
      cfg.publish = {}
    elseif
      type(raw.publish) == "table" and (raw.publish.why == nil or is_text(raw.publish.why))
    then
      for k in pairs(raw.publish) do
        if k ~= "why" then
          bad(".publish: unknown key %s", tostring(k))
        end
      end
      cfg.publish = { why = raw.publish.why }
    else
      bad('.publish: true, or { why = "<who checks out ci-verified>" }')
    end
  end
  if raw.timeout ~= nil then
    local t = raw.timeout
    if type(t) ~= "number" or t ~= math.floor(t) or t < 1 or t > 360 then
      bad(".timeout: minutes, a whole number from 1 to 360")
    else
      cfg.timeout = t
    end
  end
  if #problems > 0 then
    return nil, problems
  end
  return cfg, problems
end

---Width of the comment above the checkouts: the workflows of rules.nvim and tasks.nvim wrapped it there by hand, and
---a generated workflow is theirs byte for byte.
M.CHECKOUTS_WIDTH = 114

---Wrap words into comment lines of at most `width` (default `M.WIDTH`) columns.
---@param text string
---@param prefix string What every line starts with (`  # `).
---@param width? integer
---@param rest? string What the lines after the first start with (default `prefix`; `#   ` under a `# - ` bullet).
---@return string lines Each line ends with a newline.
function M.wrap(text, prefix, width, rest)
  width = width or M.WIDTH
  rest = rest or prefix
  local out, line, empty = {}, prefix, true
  for word in text:gmatch("%S+") do
    if not empty and #line + 1 + #word > width then
      out[#out + 1] = line
      line = rest .. word
    else
      line = empty and (line .. word) or (line .. " " .. word)
    end
    empty = false
  end
  if not empty then
    out[#out + 1] = line
  end
  return table.concat(out, "\n") .. "\n"
end

---`a`, `a and b`, `a, b and c`.
---@param words string[]
---@return string
local function english(words)
  if #words <= 1 then
    return words[1] or ""
  end
  return table.concat(words, ", ", 1, #words - 1) .. " and " .. words[#words]
end

---@param name string
---@param repo string
---@param ref string
---@param pinned? string The comment above the ref of a pinned checkout.
---@return string
local function checkout_block(name, repo, ref, pinned)
  local lines = {
    "      - uses: actions/checkout@" .. M.ACTIONS.checkout,
    "        with:",
    "          persist-credentials: false",
    "          repository: " .. repo,
    "          path: .deps/" .. name,
  }
  if pinned then
    lines[#lines + 1] = "          # " .. pinned
  end
  lines[#lines + 1] = "          ref: " .. ref
  return table.concat(lines, "\n") .. "\n"
end

---The text of the workflow of `root`.
---@param root string
---@return string|nil text
---@return string[] problems
function M.render(root)
  local loaded = require("testing.config.project").load(root)
  if loaded.error then
    return nil, { loaded.error }
  end
  local ci = loaded.config.ci
  if type(ci) ~= "table" or ci.workflow == nil then
    return nil,
      {
        ("%s/.testing.lua has no ci.workflow: nothing is generated (docs/WORKFLOW-CI.md)"):format(
          root
        ),
      }
  end
  local cfg, problems = M.validate(ci.workflow)
  if not cfg then
    return nil, problems
  end
  -- every step that runs on a platform leg must be one of the default profile, or that leg runs nothing
  local pipeline = require("testing.ci.schema").load(root)
  if pipeline then
    local in_default = {}
    for _, n in ipairs(pipeline.profiles[pipeline.default] or {}) do
      in_default[n] = true
    end
    for _, n in ipairs(cfg.platform) do
      if not in_default[n] then
        problems[#problems + 1] = ("ci.workflow.platform: %s is no step of the profile %s"):format(
          n,
          pipeline.default
        )
      end
    end
  end
  local deps = {}
  for _, d in ipairs(type(loaded.config.deps) == "table" and loaded.config.deps or {}) do
    local dname = type(d) == "table" and (d.name or d[1]) or d
    if type(dname) ~= "string" or not require("testing.deps").is_valid_name(dname) then
      problems[#problems + 1] = ("deps: %s is no dependency name"):format(vim.inspect(dname))
    elseif dname ~= "testing.nvim" then
      deps[#deps + 1] = dname
    end
  end
  if #problems > 0 then
    return nil, problems
  end
  return M.render_cfg(cfg, deps, { script = M.script_of(root) })
end

---What every leg runs: `scripts/ci.sh` where the repository has that wrapper, else `scripts/test.sh ci`.
---@param root string
---@return string
function M.script_of(root)
  return vim.uv.fs_stat(root .. "/scripts/ci.sh") and "scripts/ci.sh" or "scripts/test.sh ci"
end

---The `ci.workflow` that `testing init` writes a workflow from when the repository has none of its own: the name, a
---layout, the suite as the step that depends on the platform.
---@param name string
---@param layout "public"|"private"|"hosted"
---@return Testing.Ci.Workflow.Config|nil cfg
---@return string[] problems
function M.defaults(name, layout)
  return M.validate({ name = name, layout = layout, platform = { "suite" } })
end

local LEG = {
  self_hosted = '{"name":"windows","runs-on":["self-hosted","windows"],"hosted":false,"steps":""}',
  ubuntu = '{"name":"ubuntu","runs-on":"ubuntu-latest","hosted":true,"steps":""}',
  windows = '{"name":"windows","runs-on":"windows-latest","hosted":true,"steps":"--step=%s"}',
  macos = '{"name":"macos","runs-on":"macos-latest","hosted":true,"steps":"--step=%s"}',
}

---The parts of the workflow that depend on the layout.
---@param cfg Testing.Ci.Workflow.Config
---@param words { platform: string, portable: string, tools: string, steps: string }
---@return table<string, string>
local function layout_parts(cfg, words)
  local function legs(...)
    local list = {}
    for i, leg in ipairs({ ... }) do
      list[i] = leg:find("%s", 1, true) and leg:format(words.steps) or leg
    end
    return "[" .. table.concat(list, ",") .. "]"
  end
  local function bullet(text)
    return M.wrap(text, "# - ", M.WIDTH, "#   ")
  end
  local fork = "A fork can edit this file in its pull request (e.g. `runs-on: self-hosted`). The repository therefore "
    .. "requires approval before a workflow of an outside contributor runs; never approve a pull request that touches "
    .. "`.github/`."
  local push_pr = "  push:\n    branches: [main]\n  pull_request:\n"
  local group = "  group: ci-${{ github.workflow }}-${{ github.ref }}\n"
  local self_tools = "Hosted legs only: the tools the self-hosted runner has on its PATH."
  if cfg.layout == "private" then
    return {
      KINDS = "two kinds of runner",
      LAYOUT_TEXT = bullet(
        "push to main: the self-hosted runner (the maintainer's local Windows machine), tools on its PATH, the whole "
          .. 'profile. Without a running runner its job stays "Queued" (no red mark, discarded after 24 h).'
      )
        .. bullet(
          ("workflow_dispatch: a GitHub-hosted macOS leg, started by hand with `gh workflow run ci.yml`. It runs the steps that depend on the platform: %s. There is no local Mac; a throwaway VM, never the local machine. The leg pins the versions the self-hosted runner has (%s)."):format(
            words.platform,
            words.tools
          )
        ),
      FORK_TEXT = "#\n"
        .. M.wrap(
          "Why macOS only by hand: hosted minutes of a private repository are paid, a leg on every push would use them up within days, and an empty budget ends a job without a single step. Hence no pull_request trigger either. `testing ci remote` counts push runs only: a macOS run by hand is no verdict there and the MACOS cell stays `-`.",
          "# "
        ),
      TRIGGERS = "  push:\n    branches: [main]\n  workflow_dispatch:\n",
      CONCURRENCY = "  # The event is part of the group: a push must not cancel the paid macOS run, and that run must not cancel a push.\n"
        .. "  group: ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}\n",
      TIMEOUT_TEXT = "    # On the macOS leg this is also the price limit of one run.\n",
      MATRIX_TEXT = M.wrap(
        ("Only a push to main uses the self-hosted runner (the whole `full` profile); every other event, also one added later, gets the hosted macOS leg with the steps that depend on the platform (%s do not)."):format(
          words.portable
        ),
        "        # "
      ),
      MATRIX = ("${{ fromJSON(github.event_name == 'push' && '%s' || '%s') }}"):format(
        legs(LEG.self_hosted),
        legs(LEG.macos)
      ),
      TOOLS_TEXT = self_tools,
      SYSTEMS = "the self-hosted runner (macOS runs by hand)",
      PUBLISH_HEADER = bullet(
        "publish-ci-verified: after a green push only, on a GitHub-hosted runner: the one job with write access never runs on the maintainer's machine. It waits for the self-hosted leg: `ci-verified` means green on Windows."
      ),
    }
  elseif cfg.layout == "hosted" then
    return {
      KINDS = "GitHub-hosted runners only",
      LAYOUT_TEXT = bullet(
        ("every event (a push to main, a pull request, also from a fork): GitHub-hosted runners only, a throwaway VM with a read-only token and no secrets; nothing runs on the maintainer's machine. The whole profile runs on ubuntu, the steps that depend on the platform (%s) on windows and macOS. The legs pin %s."):format(
          words.platform,
          words.tools
        )
      )
        .. bullet(
          "the result cache (docs/CI-CACHE.md of testing.nvim): the suite reuses the green results of earlier runs; a pull request only restores it, only a push to main saves it."
        ),
      FORK_TEXT = "#\n" .. M.wrap(fork, "# "),
      TRIGGERS = push_pr,
      CONCURRENCY = group,
      TIMEOUT_TEXT = "",
      MATRIX_TEXT = M.wrap(
        ("Every event gets hosted runners: the whole profile on ubuntu, and on windows and macOS the steps that depend on the platform (%s do not)."):format(
          words.portable
        ),
        "        # "
      ),
      MATRIX = ("${{ fromJSON('%s') }}"):format(legs(LEG.ubuntu, LEG.windows, LEG.macos)),
      TOOLS_TEXT = "The tools every leg needs, at the versions of the table in testing.nvim (testing.ci.workflow).",
      SYSTEMS = "all three systems",
      PUBLISH_HEADER = bullet(
        "publish-ci-verified: after a green push only. It waits for every leg: `ci-verified` means green on all three systems."
      ),
    }
  end
  -- public: rules.nvim and tasks.nvim had this by hand, and their files are generated byte for byte
  return {
    KINDS = "two kinds of runner",
    LAYOUT_TEXT = table.concat({
      "# - push to main: the self-hosted runner (the maintainer's local Windows machine), tools on its PATH. Without a running",
      '#   runner a push stays "Queued" (no red mark, discarded after 24 h).',
      "# - pull_request (also from forks): GitHub-hosted runners, a throwaway VM with a read-only token and no secrets (every",
      "#   dependency is a public repository). A pull request never runs on the self-hosted runner: it would run its own",
      "#   workflow code on the maintainer's machine. The hosted legs pin the versions the self-hosted runner has (nvim",
      ("#   %s); a difference between the two is a finding."):format(
        (words.tools:gsub("^nvim ", ""))
      ),
      "# - macOS: a GitHub-hosted leg on every event, also on a push: the repository is public, so it costs nothing, and no",
      ("#   self-hosted runner has macOS. It runs the steps that depend on the platform: %s."):format(
        words.platform
      ),
      "",
    }, "\n"),
    FORK_TEXT = "#\n" .. M.wrap(fork, "# "),
    TRIGGERS = push_pr,
    CONCURRENCY = group,
    TIMEOUT_TEXT = "",
    MATRIX_TEXT = M.wrap(
      ("Only a push to main uses the self-hosted runner (the whole `full` profile); every other event, also one added later (workflow_dispatch, pull_request_target, ...), gets hosted runners: the whole profile on ubuntu, and on windows and macOS the steps that depend on the platform (%s do not)."):format(
        words.portable
      ),
      "        # "
    ),
    MATRIX = ("${{ fromJSON(github.event_name == 'push' && '%s' || '%s') }}"):format(
      legs(LEG.self_hosted, LEG.macos),
      legs(LEG.ubuntu, LEG.windows, LEG.macos)
    ),
    TOOLS_TEXT = self_tools,
    SYSTEMS = "all three systems",
    PUBLISH_HEADER = "# - publish-ci-verified: after a green push only, on a GitHub-hosted runner: the one job with write access never runs\n#   on the maintainer's machine. It waits for macOS too: `ci-verified` means green on all three systems.\n",
  }
end

---The text of a workflow from a checked `ci.workflow` (`M.validate`) and the dependencies (testing.nvim is added).
---@param cfg Testing.Ci.Workflow.Config
---@param deps string[] Dependency names, checked by the caller (`testing.deps.is_valid_name`), without testing.nvim.
---@param opts? { script?: string, owner?: string } `script`: what every leg runs (default `scripts/test.sh ci`); `owner`: of the
---dependency repositories (default `testing.scaffold.DEFAULT_OWNER`, checked by the caller).
---@return string|nil text
---@return string[] problems
function M.render_cfg(cfg, deps, opts)
  opts = opts or {}
  local script = opts.script or "scripts/test.sh ci"
  local owner = opts.owner or scaffold.DEFAULT_OWNER
  if not owner:match("^[%w][%w-]*$") then
    return nil, { "the owner of the dependencies: letters, digits and -" }
  end
  if script ~= "scripts/ci.sh" and script ~= "scripts/test.sh ci" then
    return nil, { "the script of a leg is scripts/ci.sh or scripts/test.sh ci" }
  end
  local name = cfg.name
  local own = vim.list_extend(vim.deepcopy(deps), { "testing.nvim" })
  local checkouts = {}
  checkouts[1] = M.wrap(
    ("Found by scripts/test.sh in `.deps/<name>`. %s %s from the branch that only moves once the dependency's own CI is green."):format(
      english(own),
      #own == 1 and "comes" or "come"
    ),
    "      # ",
    M.CHECKOUTS_WIDTH
  )
  for _, d in ipairs(deps) do
    checkouts[#checkouts + 1] = checkout_block(d, owner .. "/" .. d, scaffold.DEFAULT_REF)
  end
  for _, c in ipairs(cfg.checkouts) do
    local mine = c.repo:match("^([^/]+)/") == owner
    if c.ref == scaffold.DEFAULT_REF and not mine then
      return nil,
        {
          ("ci.workflow.checkouts: %s is no repository of %s: only those have %s, third-party code is pinned"):format(
            c.repo,
            owner,
            scaffold.DEFAULT_REF
          ),
        }
    end
    if c.why then
      checkouts[#checkouts + 1] = M.wrap(c.why, "      # ")
    end
    local pinned = nil
    if not mine then
      pinned =
        "Pinned: third-party code runs inside the specs on the self-hosted runner. Bump on purpose."
    elseif c.ref ~= scaffold.DEFAULT_REF then
      pinned = ("Pinned: a commit whose own CI was green (no %s branch to follow). Bump on purpose."):format(
        scaffold.DEFAULT_REF
      )
    end
    checkouts[#checkouts + 1] = checkout_block(c.repo:match("/(.+)$"), c.repo, c.ref, pinned)
  end
  checkouts[#checkouts + 1] =
    checkout_block("testing.nvim", owner .. "/testing.nvim", scaffold.DEFAULT_REF)

  local platform_words = {}
  for i, n in ipairs(cfg.platform) do
    platform_words[i] = n == "suite" and "the suite" or n
  end
  local portable = { "stylua", "luacheck" }
  if cfg.node then
    portable[#portable + 1] = cfg.node.used_by
  end
  local env_names = vim.tbl_keys(cfg.env)
  table.sort(env_names)
  local env = {}
  for _, k in ipairs(env_names) do
    env[#env + 1] = ("          %s: %s\n"):format(k, render.yaml_quote(cfg.env[k]))
  end

  local tools = ("nvim %s, stylua %s, luacheck %s%s"):format(
    M.TOOLS.nvim,
    M.TOOLS.stylua,
    M.TOOLS.luacheck,
    cfg.node and (", Node " .. cfg.node.version) or ""
  )
  local parts = layout_parts(cfg, {
    platform = english(platform_words),
    portable = english(portable),
    tools = tools,
    steps = table.concat(cfg.platform, ","),
  })
  -- the cache transport and `--cached` belong to the hosted layout only (its legs start empty every time)
  local cache = cfg.layout == "hosted"
  local key = ("testing-${{ runner.os }}-nvim%s-"):format(M.TOOLS.nvim)
  if cache then
    table.insert(env, 1, "          TESTING_CACHE_HOME: ${{ runner.temp }}/testing-cache\n")
  end

  local publish_job = ""
  if cfg.publish then
    local why = ("Moves the branch `ci-verified` to a commit whose pipeline is green on %s, never backwards "):format(
      parts.SYSTEMS
    ) .. "along main (two pushes can finish out of order), and retries a lost lease. A consumer that checks this " .. "repository out with `ref: ci-verified` always tests against a known-good commit."
    if cfg.publish.why then
      why = why .. " " .. cfg.publish.why
    end
    local text, err = scaffold.render_template(
      "ci_publish_job.yml.tpl",
      { WHY = (M.wrap(why, "  # "):gsub("\n$", "")) }
    )
    if not text then
      return nil, { tostring(err) }
    end
    publish_job = text
  end

  local vars = {
    NAME = name,
    NVIM_VERSION = M.TOOLS.nvim,
    STYLUA_VERSION = M.TOOLS.stylua,
    LUACHECK_VERSION = M.TOOLS.luacheck,
    LUA_VERSION = M.TOOLS.lua,
    TIMEOUT = tostring(cfg.timeout),
    KINDS = parts.KINDS,
    INTRO = M.wrap(
      ("What is checked lives only in the `ci` section of .testing.lua; every leg runs it with %s, exactly as the pre-push hook and `:Testing ci` do. This file only prepares the machine."):format(
        script == "scripts/ci.sh" and "`scripts/ci.sh` (`testing ci`)" or ("`" .. script .. "`")
      ),
      "# "
    ),
    LAYOUT_TEXT = parts.LAYOUT_TEXT,
    FORK_TEXT = parts.FORK_TEXT,
    TRIGGERS = parts.TRIGGERS,
    CONCURRENCY = parts.CONCURRENCY,
    TIMEOUT_TEXT = parts.TIMEOUT_TEXT,
    MATRIX_TEXT = parts.MATRIX_TEXT,
    MATRIX = parts.MATRIX,
    TOOLS_TEXT = parts.TOOLS_TEXT,
    SCRIPT = script,
    SCRIPT_FILE = script:match("^(%S+)"),
    SUITE_EXTRA = cache and " --cached" or "",
    CACHE_RESTORE = cache
        and table.concat({
          "      # The result cache (docs/CI-CACHE.md of testing.nvim). The key is only the transport: every entry carries its",
          "      # own full spec key and is checked against it when read, so a wrong restore can lower the hit rate and never turn",
          "      # a result green. A pull request only restores; only a push to main saves.",
          "      - uses: actions/cache/restore@" .. M.ACTIONS.cache,
          "        with:",
          "          path: ${{ runner.temp }}/testing-cache",
          "          key: " .. key .. "${{ github.sha }}",
          "          restore-keys: " .. key,
          "",
        }, "\n")
      or "",
    CACHE_SAVE = cache and table.concat({
      "      - uses: actions/cache/save@" .. M.ACTIONS.cache,
      "        if: success() && github.event_name == 'push' && github.ref == 'refs/heads/main'",
      "        with:",
      "          path: ${{ runner.temp }}/testing-cache",
      "          key: " .. key .. "${{ github.sha }}",
      "",
    }, "\n") or "",
    PUBLISH_HEADER = cfg.publish and parts.PUBLISH_HEADER or "",
    CHECKOUT_ACTION = M.ACTIONS.checkout,
    SETUP_VIM_ACTION = M.ACTIONS.setup_vim,
    STYLUA_ACTION = M.ACTIONS.stylua,
    LUA_ACTION = M.ACTIONS.lua,
    LUAROCKS_ACTION = M.ACTIONS.luarocks,
    UPLOAD_ACTION = M.ACTIONS.upload,
    CHECKOUTS = (table.concat(checkouts):gsub("\n$", "")),
    NODE_STEP = cfg.node
        and ("      - uses: actions/setup-node@%s\n        if: matrix.hosted && matrix.steps == ''\n        with:\n          node-version: %s\n"):format(
          M.ACTIONS.node,
          render.yaml_quote(cfg.node.version)
        )
      or "",
    ENV = table.concat(env),
    PUBLISH_JOB = publish_job,
  }
  local text, err = scaffold.render_template("ci_generated.yml.tpl", vars)
  if not text then
    return nil, { tostring(err) }
  end
  return text, {}
end

---A unified diff of two texts (`have` the file, `want` the generated one).
---@param have string
---@param want string
---@return string
function M.diff(have, want)
  return vim.diff(have, want, { ctxlen = 2 }) --[[@as string]]
end

---`testing init --workflow=public [--force | --check]`: 0 written, kept or in sync; 1 `--check` found a difference (or no
---file); 2 a problem of `ci.workflow`; 3 the file could not be written. `create` writes a missing file and keeps an
---existing one (as every `testing init`), `force` replaces it, `check` compares byte for byte and prints a diff.
---@param root string Absolute, no trailing slash.
---@param mode "create"|"force"|"check"
---@param sv { out: fun(s: string), err: fun(s: string) }
---@return integer
function M.run(root, mode, sv)
  local want, problems = M.render(root)
  if not want then
    sv.err("testing: init --workflow=public: " .. table.concat(problems, "\n  "))
    return 2
  end
  local path = root .. "/" .. M.PATH
  local have = require("lib.nvim.fs.read")(path)
  if mode == "check" then
    if have == want then
      sv.out(("workflow in sync: %s"):format(M.PATH))
      return 0
    end
    if not have then
      sv.out(("workflow missing: %s (testing init --workflow=public)"):format(M.PATH))
      return 1
    end
    sv.out(
      ("workflow out of sync: %s (testing init --workflow=public --force)\n%s"):format(
        M.PATH,
        M.diff(have, want)
      )
    )
    return 1
  end
  if have == want then
    sv.out(("workflow unchanged: %s"):format(M.PATH))
    return 0
  end
  if have and mode ~= "force" then
    sv.out(
      ("kept: %s differs from the generated one; --force replaces it, --check shows the difference"):format(
        M.PATH
      )
    )
    return 0
  end
  local ok, err = require("lib.nvim.fs.mkdirp")(vim.fs.dirname(path))
  if ok then
    ok, err = require("lib.nvim.fs.write.atomic")(path, want)
  end
  if not ok then
    sv.err(("testing: init --workflow=public: cannot write %s: %s"):format(path, tostring(err)))
    return 3
  end
  sv.out(("%s: %s"):format(have and "replaced" or "created", M.PATH))
  return 0
end

return M
