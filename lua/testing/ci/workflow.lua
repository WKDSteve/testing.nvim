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
---       playwright = { version = "1.64.1", used_by = "the browser sheets" },  -- optional: Chromium on the full leg
---       luals = { version = "3.18.2", used_by = "scripts/luals-check.sh" },  -- optional: lua-language-server, pinned
---       go = { version_file = "go.mod", used_by = "the relay build" },  -- optional: Go on the hosted legs
---       artifacts = { { name = "sheet-shots", path = "TESTS/sheets/out/**/*.png", why = "..." } },  -- optional: uploads
---       checkouts = {                               -- optional: more checkouts below .deps/ (third-party: pinned)
---         { repo = "folke/snacks.nvim", ref = "<40 hex>", why = "the dashboard specs drive the real picker" },
---       },
---       env = { TASKS_REQUIRE_SNACKS = "1" },       -- optional: environment of the pipeline step
---       packages = { { name = "ripgrep", why = "insights.nvim scans with it" } },   -- optional: installed on the hosted legs
---       setup = { { run = { "bash", "scripts/ci-setup.sh" }, why = "builds the grammars" } },  -- optional: an argv
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
M.TOOLS = { nvim = "0.12.2", stylua = "2.5.2", luacheck = "1.2.0" }

---The sha256 of the release files the hosted legs download (the same as scripts/wsl-tools.sh). luacheck: the Linux binary
---of lunarmodules/luacheck v1.2.0, checked on 2026-11-12 against its signature (Caleb Maclennan, 63CC496475267693).
---`luals`: per version, the sum of `lua-language-server-<version>-linux-x64.tar.gz` of LuaLS/lua-language-server (the
---digest GitHub lists for the release asset; 3.18.2 as terminal.nvim's hand-written job had it). `ci.workflow.luals`
---takes only a version listed here: a bump adds its sum, no download goes unpinned.
M.SHA256 = {
  luacheck = "d68da17fca0697d9e2fb04201f3884abd259fa558b3a449bccaed47f1390defc",
  luals = {
    ["3.18.2"] = "ca71415dd19f19e30aaa35a4915aefca9fdb5fec31b98331cc3d77f778d539c5",
  },
}

---The actions, pinned by commit (third-party code runs on the self-hosted runner too). Bump on purpose.
M.ACTIONS = {
  checkout = "fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5",
  setup_vim = "febef33995d6649302e9d88dda81e071b68f16a7 # v1",
  stylua = "76fd70c03e6340ceaf673366712db9b20560b402 # v5",
  node = "249970729cb0ef3589644e2896645e5dc5ba9c38 # v6",
  go = "924ae3a1cded613372ab5595356fb5720e22ba16 # v6",
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

---The keys of one entry of `ci.workflow.packages`.
local PACKAGE_KEYS = { name = true, why = true, apt = true, brew = true, choco = true, npm = true }

---One word for a package manager: nothing a shell could read as its own.
---@param v any
---@return boolean
local function is_package_name(v)
  return type(v) == "string" and v:match("^[%w][%w._+-]*$") ~= nil and #v <= 64
end

---One package of npm (`typescript@5`, `@scope/name@1.2`): a name, an optional scope and an optional version; nothing a
---shell could read as its own.
---@param v any
---@return boolean
local function is_npm_package(v)
  return type(v) == "string"
    and #v <= 100
    and (v:match("^[%w][%w._-]*$") or v:match("^@[%w][%w._-]*/[%w][%w._-]*$") or v:match(
      "^@?[%w][%w._/-]*@[%w][%w.^~_-]*$"
    )) ~= nil
    and not v:find("//", 1, true)
end

---Most packages a workflow installs: every one is a step of every hosted leg.
M.MAX_PACKAGES = 8

---Most setup steps a workflow runs, and most words of one: a setup step calls a script of the repository, it is no
---second pipeline.
M.MAX_SETUP = 4
M.MAX_SETUP_WORDS = 16

---The keys of one entry of `ci.workflow.setup`.
local SETUP_KEYS = { run = true, why = true, legs = true }

---Which legs a setup step runs on: `full` the hosted leg that runs the whole profile (ubuntu), `hosted` every hosted
---leg (also windows, macOS and ubuntu-min). Never a self-hosted one, whose machine is not the workflow's to change.
M.SETUP_LEGS = {
  full = "matrix.hosted && matrix.steps == ''",
  hosted = "matrix.hosted",
}

---One word of a setup command: nothing a shell reads as its own (no blank, quote, `$`, `;`, `&`, `|`, `<`, `>`, `*`,
---backslash, backtick), so the words can be joined into the `run:` line without quoting.
---@param v any
---@return boolean
local function is_setup_word(v)
  return type(v) == "string" and #v <= 200 and v:match("^[%w@%%+=:,./_-]+$") ~= nil
end

---Most extra artifacts a workflow uploads (`ci.workflow.artifacts`).
M.MAX_ARTIFACTS = 4

---The keys of one entry of `ci.workflow.artifacts`.
local ARTIFACT_KEYS = { name = true, path = true, when = true, legs = true, why = true }

---When an extra artifact is uploaded: `always` also after a green run (a screenshot is the evidence a sheet leaves
---behind), `failure` only from a red leg (as the report).
M.ARTIFACT_WHEN = { always = "always()", failure = "failure()" }

---A path of an artifact: relative to the checkout, a glob of `actions/upload-artifact` (`*`, `**`), never `..`, never an
---absolute path, and no character YAML or an expression (`${{`) reads as its own.
---@param v any
---@return boolean
local function is_artifact_path(v)
  if type(v) ~= "string" or #v > 200 or not v:match("^[%w._/*-]+$") then
    return false
  end
  if v:sub(1, 1) == "/" or v:sub(1, 1) == "-" or v:find("//", 1, true) then
    return false
  end
  for part in v:gmatch("[^/]+") do
    if part == ".." or part == "." then
      return false
    end
  end
  return true
end

---The `name:` of a workflow file (`testing ci land --also`, `ci.workflow.land.also`): what `testing ci remote` compares
---a run's name with, without case.
---@param v any
---@return boolean
function M.is_workflow_name(v)
  return type(v) == "string" and #v <= 100 and v:match("^[%w][%w ._()-]*$") ~= nil
end

local KEYS = {
  name = true,
  min_nvim = true,
  layout = true,
  platform = true,
  node = true,
  playwright = true,
  luals = true,
  go = true,
  artifacts = true,
  checkouts = true,
  packages = true,
  setup = true,
  env = true,
  publish = true,
  timeout = true,
  land = true,
}

---@class Testing.Ci.Workflow.Checkout
---@field repo string `owner/name`.
---@field ref string A full commit id.
---@field why? string One comment line above the checkout.

---@class Testing.Ci.Workflow.Config
---@field platform string[]
---@field node? { version: string, used_by: string }
---@field playwright? { version: string, used_by: string } playwright-core and Chromium on the hosted full leg, outside the checkout (`TESTING_PLAYWRIGHT_DIR`, `PLAYWRIGHT_BROWSERS_PATH`): the browser sheets run instead of being a reported skip.
---@field luals? { version: string, used_by: string } lua-language-server, the release tarball pinned by its sha256 (`M.SHA256.luals`), on the hosted full leg: a step of the profile (`scripts/luals-check.sh`) can run it there.
---@field go? { version_file: string, used_by: string, legs: "full"|"hosted" } Go through `actions/setup-go`, its version from a file of the repository (`go.mod`): the hosted macOS image has Go only in its tool cache.
---@field artifacts { name: string, path: string, when: "always"|"failure", legs: "full"|"hosted", why: string }[] More files a hosted leg uploads after the pipeline (`<name>-<leg>`, 14 days): the screenshots of the browser sheets.
---@field checkouts Testing.Ci.Workflow.Checkout[]
---@field packages { name: string, why: string, apt?: string|false, brew?: string|false, choco?: string|false, npm?: string[] }[] Installed on every hosted leg (apt, brew, choco; a name of its own per manager where they differ, false to go without; or npm on every leg), never on a self-hosted one.
---@field setup { run: string[], why: string, legs: "full"|"hosted" }[] Commands of the repository (an argv, no shell text) that prepare a hosted leg before the pipeline: build grammars, install rocks, link a checkout, write `$GITHUB_ENV`.
---@field env table<string, string>
---@field publish? { why?: string }
---@field land boolean `testing ci land`: a push to `ci/**` runs the hosted legs, and a push to main of a commit that was
---green there only publishes (docs/CI.md, "Land through the hosted CI"). `land = { also = { "native" } }` is true too.
---@field land_also string[] Other workflows (by name) `testing ci land` waits for besides CI; the file is the same.
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
    artifacts = {},
    checkouts = {},
    packages = {},
    setup = {},
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
  if raw.playwright ~= nil then
    local p = raw.playwright
    if
      type(p) ~= "table"
      or type(p.version) ~= "string"
      or not p.version:match("^%d+%.%d+%.%d+$")
      or not is_text(p.used_by)
    then
      bad(
        '.playwright: expected { version = "1.64.1", used_by = "<what needs it, for a comment>" }'
      )
    else
      for k in pairs(p) do
        if k ~= "version" and k ~= "used_by" then
          bad(".playwright: unknown key %s", tostring(k))
        end
      end
      cfg.playwright = { version = p.version, used_by = p.used_by }
    end
  end
  if raw.luals ~= nil then
    local l = raw.luals
    if
      type(l) ~= "table"
      or type(l.version) ~= "string"
      or not l.version:match("^%d+%.%d+%.%d+$")
      or not is_text(l.used_by)
    then
      bad('.luals: expected { version = "3.18.2", used_by = "<what needs it, for a comment>" }')
    else
      local fine = true
      for k in pairs(l) do
        if k ~= "version" and k ~= "used_by" then
          bad(".luals: unknown key %s", tostring(k))
          fine = false
        end
      end
      -- only a version whose sum testing.nvim lists: the tarball is checked before it is unpacked
      if not M.SHA256.luals[l.version] then
        local known = vim.tbl_keys(M.SHA256.luals)
        table.sort(known)
        bad(
          ".luals.version: %s has no pinned sha256 in testing.ci.workflow.SHA256.luals (known: %s)",
          l.version,
          table.concat(known, ", ")
        )
        fine = false
      end
      if fine then
        cfg.luals = { version = l.version, used_by = l.used_by }
      end
    end
  end
  if raw.go ~= nil then
    local g = raw.go
    if
      type(g) ~= "table"
      or not is_artifact_path(g.version_file)
      or g.version_file:find("*", 1, true)
      or not is_text(g.used_by)
    then
      bad(
        '.go: expected { version_file = "go.mod", used_by = "<what needs it, for a comment>" } (a file of the repository)'
      )
    else
      local fine = true
      for k in pairs(g) do
        if k ~= "version_file" and k ~= "used_by" and k ~= "legs" then
          bad(".go: unknown key %s", tostring(k))
          fine = false
        end
      end
      if g.legs ~= nil and (type(g.legs) ~= "string" or not M.SETUP_LEGS[g.legs]) then
        bad(
          '.go.legs: "hosted" (every hosted leg, default) or "full" (the leg with the whole profile)'
        )
        fine = false
      end
      if fine then
        cfg.go = { version_file = g.version_file, used_by = g.used_by, legs = g.legs or "hosted" }
      end
    end
  end
  if raw.artifacts ~= nil then
    local shape =
      '{ name = "sheet-shots", path = "TESTS/sheets/out/**/*.png", why = "<one line>" } (when, legs optional)'
    if not is_list(raw.artifacts) or #raw.artifacts == 0 then
      bad(".artifacts: expected a list of %s", shape)
    else
      if #raw.artifacts > M.MAX_ARTIFACTS then
        bad(".artifacts: at most %d", M.MAX_ARTIFACTS)
      end
      local seen = {}
      for i, a in ipairs(raw.artifacts) do
        if type(a) ~= "table" then
          bad(".artifacts[%d]: expected %s", i, shape)
        else
          local fine = true
          for k in pairs(a) do
            if not ARTIFACT_KEYS[k] then
              bad(".artifacts[%d]: unknown key %s", i, tostring(k))
              fine = false
            end
          end
          -- uploaded as `<name>-<leg>`; `ci-<leg>` is the report's own
          if
            type(a.name) ~= "string"
            or not a.name:match("^[%w][%w._-]*$")
            or #a.name > 64
            or a.name == "ci"
          then
            bad(
              '.artifacts[%d].name: letters, digits, ".", "_" and "-" (not "ci": the report is ci-<leg>)',
              i
            )
            fine = false
          elseif seen[a.name] then
            bad(".artifacts[%d].name: %s twice", i, a.name)
            fine = false
          end
          if not is_artifact_path(a.path) then
            bad(
              '.artifacts[%d].path: a path relative to the checkout, letters, digits and "._/*-" (no "..", not absolute)',
              i
            )
            fine = false
          end
          if not is_text(a.why) then
            bad(".artifacts[%d].why: one line of text, what the files show", i)
            fine = false
          end
          if a.when ~= nil and (type(a.when) ~= "string" or not M.ARTIFACT_WHEN[a.when]) then
            bad('.artifacts[%d].when: "always" (default, also a green run) or "failure"', i)
            fine = false
          end
          if a.legs ~= nil and (type(a.legs) ~= "string" or not M.SETUP_LEGS[a.legs]) then
            bad(
              '.artifacts[%d].legs: "full" (the leg with the whole profile, default) or "hosted" (every hosted leg)',
              i
            )
            fine = false
          end
          if fine then
            seen[a.name] = true
            cfg.artifacts[#cfg.artifacts + 1] = {
              name = a.name,
              path = a.path,
              why = a.why,
              when = a.when or "always",
              legs = a.legs or "full",
            }
          end
        end
      end
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
  if raw.packages ~= nil then
    if not is_list(raw.packages) then
      bad(".packages: expected a list")
    else
      if #raw.packages > M.MAX_PACKAGES then
        bad(".packages: at most %d", M.MAX_PACKAGES)
      end
      local seen = {}
      for i, p in ipairs(raw.packages) do
        if type(p) ~= "table" then
          bad('.packages[%d]: expected { name = "ripgrep", why = "<one line>" }', i)
        else
          for k in pairs(p) do
            if not PACKAGE_KEYS[k] then
              bad(".packages[%d]: unknown key %s", i, tostring(k))
            end
          end
          -- a name of its own per package manager where they differ (poppler-utils on apt, poppler on brew and choco),
          -- or false: that system goes without (tmux: no choco package; the pty specs are n/a on Windows anyway)
          local skipped = 0
          for _, pm in ipairs({ "apt", "brew", "choco" }) do
            if p[pm] == false then
              skipped = skipped + 1
            elseif p[pm] ~= nil and not is_package_name(p[pm]) then
              bad(
                '.packages[%d].%s: a package name, letters, digits, ".", "_", "+" and "-", or false (that system goes without)',
                i,
                pm
              )
            end
          end
          if skipped == 3 then
            bad(".packages[%d]: false for apt, brew and choco installs it nowhere", i)
          end
          -- npm: one step `npm install -g ...` on every hosted leg, instead of the three package managers
          if p.npm ~= nil then
            if not is_list(p.npm) or #p.npm == 0 or #p.npm > 8 then
              bad('.packages[%d].npm: a list of 1 to 8 npm packages ("typescript@5")', i)
            else
              for j, n in ipairs(p.npm) do
                if not is_npm_package(n) then
                  bad(
                    '.packages[%d].npm[%d]: an npm package, "name", "@scope/name" or "name@version"',
                    i,
                    j
                  )
                end
              end
            end
            if p.apt ~= nil or p.brew ~= nil or p.choco ~= nil then
              bad(".packages[%d]: npm or apt/brew/choco, not both", i)
            end
          end
          if not is_package_name(p.name) then
            -- one word for apt, brew and choco: nothing a shell could read as its own
            bad('.packages[%d].name: a package name, letters, digits, ".", "_", "+" and "-"', i)
          elseif seen[p.name] then
            bad(".packages[%d].name: %s twice", i, p.name)
          elseif not is_text(p.why) then
            bad(".packages[%d].why: one line of text, why the runs need it", i)
          else
            seen[p.name] = true
            cfg.packages[#cfg.packages + 1] = {
              name = p.name,
              why = p.why,
              apt = p.apt,
              brew = p.brew,
              choco = p.choco,
              npm = p.npm,
            }
          end
        end
      end
    end
  end
  if raw.setup ~= nil then
    if not is_list(raw.setup) or #raw.setup == 0 then
      bad(
        '.setup: expected a list of { run = { "bash", "scripts/ci-setup.sh" }, why = "<one line>" }'
      )
    else
      if #raw.setup > M.MAX_SETUP then
        bad(".setup: at most %d", M.MAX_SETUP)
      end
      for i, s in ipairs(raw.setup) do
        if type(s) ~= "table" then
          bad(
            '.setup[%d]: expected { run = { "bash", "scripts/ci-setup.sh" }, why = "<one line>" }',
            i
          )
        else
          local fine = true
          for k in pairs(s) do
            if not SETUP_KEYS[k] then
              bad(".setup[%d]: unknown key %s", i, tostring(k))
              fine = false
            end
          end
          -- an argv, never a shell string: every word is checked, the line is the words joined by blanks
          if not is_list(s.run) or #s.run == 0 or #s.run > M.MAX_SETUP_WORDS then
            bad(
              ".setup[%d].run: a list of 1 to %d words (an argv, no shell text)",
              i,
              M.MAX_SETUP_WORDS
            )
            fine = false
          else
            for j, w in ipairs(s.run) do
              if not is_setup_word(w) then
                bad(
                  '.setup[%d].run[%d]: one word, letters, digits and "@%%+=:,./_-" (nothing a shell reads as its own)',
                  i,
                  j
                )
                fine = false
              elseif j == 1 and w:sub(1, 1) == "-" then
                bad(".setup[%d].run[1]: the program, not an option", i)
                fine = false
              end
            end
          end
          if not is_text(s.why) then
            bad(".setup[%d].why: one line of text, what the step prepares", i)
            fine = false
          end
          if s.legs ~= nil and (type(s.legs) ~= "string" or not M.SETUP_LEGS[s.legs]) then
            bad(
              '.setup[%d].legs: "full" (the leg with the whole profile, default) or "hosted" (every hosted leg)',
              i
            )
            fine = false
          end
          if fine then
            cfg.setup[#cfg.setup + 1] = { run = s.run, why = s.why, legs = s.legs or "full" }
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
  cfg.land = false
  cfg.land_also = {}
  local land = raw.land
  if type(land) == "table" then
    -- { also = { "native" } }: land, and `testing ci land` waits for these workflows of the repository too
    local fine = true
    for k in pairs(land) do
      if k ~= "also" then
        bad(".land: unknown key %s", tostring(k))
        fine = false
      end
    end
    if not is_list(land.also) or #land.also == 0 or #land.also > 8 then
      bad(
        '.land.also: a list of 1 to 8 workflow names ("native"), the `name:` of another workflow file'
      )
      fine = false
    else
      for i, n in ipairs(land.also) do
        if not M.is_workflow_name(n) then
          bad(".land.also[%d]: a workflow name, letters, digits, blanks and ._-()", i)
          fine = false
        elseif n:lower() == "ci" then
          bad(".land.also[%d]: CI is the generated workflow itself, land always waits for it", i)
          fine = false
        end
      end
    end
    land = fine and true or nil
    if fine then
      cfg.land_also = vim.deepcopy(raw.land.also)
    end
  end
  if land ~= nil then
    if type(land) ~= "boolean" then
      bad('.land: true or false, or { also = { "<workflow name>" } }')
    elseif land and (raw.layout or "public") == "private" then
      -- a private repository pays for hosted minutes: it lands with a local full run (testing ci commit), not here
      bad(
        '.land: not with layout = "private" (hosted minutes are paid there; land a private repository locally)'
      )
    else
      cfg.land = land
    end
  end
  if raw.min_nvim ~= nil then
    local m = raw.min_nvim
    if type(m) ~= "table" then
      bad('.min_nvim: expected { version = "0.11.4", why = "<what promises it>" }')
    else
      for k in pairs(m) do
        if k ~= "version" and k ~= "why" then
          bad(".min_nvim: unknown key %s", tostring(k))
        end
      end
      if type(m.version) ~= "string" or not m.version:match("^%d+%.%d+%.%d+$") then
        bad('.min_nvim.version: a release like "0.11.4" (no "v", no "stable")')
      elseif not is_text(m.why) then
        bad(".min_nvim.why: one line of text, what promises that version")
      elseif (raw.layout or "public") ~= "hosted" then
        bad('.min_nvim: only with layout = "hosted" (the extra leg is a hosted ubuntu runner)')
      else
        cfg.min_nvim = { version = m.version, why = m.why }
      end
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

---The steps that install the packages of `ci.workflow.packages` on a hosted leg, one per system (apt, brew, choco): the
---name is checked to be one word nobody's shell reads as its own. Nothing for none, so a workflow without packages stays
---byte for byte what it was; never on a self-hosted leg (`matrix.hosted`), whose machine is not the workflow's to change.
---@param packages { name: string, why: string, apt?: string|false, brew?: string|false, choco?: string|false, npm?: string[] }[]
---@return string
local function package_steps(packages)
  if #packages == 0 then
    return ""
  end
  local out = {}
  -- the package index of a runner image can be older than its mirrors: a package that is not in the image would then
  -- fail with a 404 depending on the image's age. One update per leg, before the first apt install.
  for _, p in ipairs(packages) do
    if not p.npm and p.apt ~= false then
      out[#out + 1] = table.concat({
        "      - name: Update the apt index",
        "        if: matrix.hosted && runner.os == 'Linux'",
        "        run: sudo apt-get update -q",
        "",
      }, "\n")
      break
    end
  end
  for _, p in ipairs(packages) do
    out[#out + 1] = "      # " .. p.name .. ": " .. p.why .. "\n"
    if p.npm then
      out[#out + 1] = table.concat({
        "      - name: Install " .. p.name .. " (npm)",
        "        if: matrix.hosted",
        "        run: npm install -g " .. table.concat(p.npm, " "),
        "",
      }, "\n")
    else
      for _, sys in ipairs({
        { "Linux", p.apt ~= false and ("sudo apt-get install -y " .. (p.apt or p.name)) },
        { "macOS", p.brew ~= false and ("brew install " .. (p.brew or p.name)) },
        {
          "Windows",
          p.choco ~= false and ("choco install " .. (p.choco or p.name) .. " -y --no-progress"),
        },
      }) do
        if sys[2] then
          out[#out + 1] = table.concat({
            "      - name: Install " .. p.name .. " (" .. sys[1] .. ")",
            "        if: matrix.hosted && runner.os == '" .. sys[1] .. "'",
            "        run: " .. sys[2],
            "",
          }, "\n")
        end
      end
    end
  end
  return table.concat(out)
end

---The steps of `ci.workflow.setup`: one per entry, in bash (Git Bash on Windows), after the tools and packages and
---before the pipeline step, so a script may write `$GITHUB_ENV` for it. The words are checked to need no shell
---quoting; the line is a YAML block scalar, so no word (`a:`, `@x`) is read as YAML either. Nothing for none, so a
---workflow without setup stays byte for byte what it was.
---@param setup { run: string[], why: string, legs: "full"|"hosted" }[]
---@return string
local function setup_steps(setup)
  local out = {}
  for i, s in ipairs(setup) do
    out[#out + 1] = M.wrap(s.why, "      # ")
    out[#out + 1] = table.concat({
      ("      - name: Setup %d (ci.workflow.setup)"):format(i),
      "        if: " .. M.SETUP_LEGS[s.legs],
      "        shell: bash",
      "        run: |",
      "          " .. table.concat(s.run, " "),
      "",
    }, "\n")
  end
  return table.concat(out)
end

---The steps of `ci.workflow.artifacts`: one upload per entry after the report's, named `<name>-<leg>` (unique per leg,
---as `ci-<leg>` is), 14 days. The path is a checked glob, always quoted (a leading `*` would be a YAML alias). Nothing
---for none, so a workflow without artifacts stays byte for byte what it was.
---@param artifacts { name: string, path: string, when: "always"|"failure", legs: "full"|"hosted", why: string }[]
---@return string
local function artifact_steps(artifacts)
  local out = {}
  for _, a in ipairs(artifacts) do
    out[#out + 1] = M.wrap(a.name .. ": " .. a.why, "      # ")
    out[#out + 1] = table.concat({
      "      - uses: actions/upload-artifact@" .. M.ACTIONS.upload,
      ("        if: %s && %s"):format(M.ARTIFACT_WHEN[a.when], M.SETUP_LEGS[a.legs]),
      "        with:",
      "          name: " .. a.name .. "-${{ matrix.name }}",
      "          path: " .. render.yaml_quote(a.path),
      "          if-no-files-found: ignore",
      "          retention-days: 14",
      "",
    }, "\n")
  end
  return table.concat(out)
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
      "# - workflow_dispatch: started by hand with `gh workflow run ci.yml` (write access only), the hosted legs as for a",
      "#   pull request. It replaces a run GitHub left hanging without jobs (cancel and rerun fail there); `testing ci",
      "#   remote` counts push runs only, so the next push is still the verdict.",
      "",
    }, "\n"),
    FORK_TEXT = "#\n" .. M.wrap(fork, "# "),
    TRIGGERS = push_pr .. "  workflow_dispatch:\n",
    CONCURRENCY = "  # The event is part of the group: a run by hand must not cancel a push, and a push must not cancel it.\n"
      .. "  group: ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}\n",
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
  -- a dependency that `checkouts` names too (a third-party plugin the specs need: telescope.nvim) comes from that line,
  -- with its repository and its pin: `<owner>/<name>@ci-verified` would be a repository that does not exist
  local in_checkouts = {}
  for _, c in ipairs(cfg.checkouts) do
    local base = c.repo:match("/(.+)$")
    if base then
      in_checkouts[base] = true
    end
  end
  local listed = {}
  for _, d in ipairs(deps) do
    if not in_checkouts[d] then
      listed[#listed + 1] = d
    end
  end
  deps = listed
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
  -- `testing ci land`: a check branch `ci/**` runs the hosted legs (in the public layout only a push to MAIN goes to the
  -- self-hosted runner), and a push to main of a commit that is already green there only publishes
  local verified_job, pipeline_gate = "", ""
  local publish_needs, publish_if =
    "[pipeline]", "github.event_name == 'push' && github.ref == 'refs/heads/main'"
  if cfg.land then
    parts.TRIGGERS = parts.TRIGGERS:gsub("branches: %[main%]", 'branches: [main, "ci/**"]', 1)
    if cfg.layout == "public" then
      parts.MATRIX = parts.MATRIX:gsub(
        "github%.event_name == 'push' &&",
        "github.event_name == 'push' && github.ref == 'refs/heads/main' &&",
        1
      )
    end
    local vtext, verr = scaffold.render_template("ci_already_verified_job.yml.tpl", {})
    if not vtext then
      return nil, { tostring(verr) }
    end
    verified_job = vtext
    pipeline_gate = table.concat({
      "    needs: [already-verified]",
      "    # Not on main when the same commit was green on a check branch ci/** (testing ci land): it ran there already.",
      "    if: ${{ !cancelled() && needs.already-verified.outputs.verified != 'true' }}",
      "",
    }, "\n")
    publish_needs = "[already-verified, pipeline]"
    publish_if = "${{ !cancelled() && github.event_name == 'push' && github.ref == 'refs/heads/main' && "
      .. "(needs.pipeline.result == 'success' || "
      .. "(needs.pipeline.result == 'skipped' && needs.already-verified.outputs.verified == 'true')) }}"
  end
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
    local text, err = scaffold.render_template("ci_publish_job.yml.tpl", {
      WHY = (M.wrap(why, "  # "):gsub("\n$", "")),
      NEEDS = publish_needs,
      IF = publish_if,
    })
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
    LUACHECK_SUM = M.SHA256.luacheck,
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
    UPLOAD_ACTION = M.ACTIONS.upload,
    CHECKOUTS = (table.concat(checkouts):gsub("\n$", "")),
    PACKAGE_STEPS = package_steps(cfg.packages),
    SETUP_STEPS = setup_steps(cfg.setup),
    ARTIFACT_STEPS = artifact_steps(cfg.artifacts),
    -- the version comes from the repository's file (GOTOOLCHAIN=auto on the images would fetch it too, but the hosted
    -- macOS image has no go on the PATH at all); no cache: a module cache keyed on go.sum is the repository's choice
    GO_STEP = cfg.go
        and table.concat({
          M.wrap(
            ("%s: Go at the version of %s (on the hosted macOS image Go is only in the tool cache, not on the PATH)."):format(
              cfg.go.used_by,
              cfg.go.version_file
            ),
            "      # "
          )
            .. "      - uses: actions/setup-go@"
            .. M.ACTIONS.go,
          "        if: " .. M.SETUP_LEGS[cfg.go.legs],
          "        with:",
          "          go-version-file: " .. render.yaml_quote(cfg.go.version_file),
          "          cache: false",
          "",
        }, "\n")
      or "",
    NODE_STEP = cfg.node
        and ("      - uses: actions/setup-node@%s\n        if: matrix.hosted && matrix.steps == ''\n        with:\n          node-version: %s\n"):format(
          M.ACTIONS.node,
          render.yaml_quote(cfg.node.version)
        )
      or "",
    -- an exact version (checked above): npm installs that release of playwright-core, which names its own Chromium
    PLAYWRIGHT_STEP = cfg.playwright
        and table.concat({
          ("      # %s: playwright-core %s and its Chromium, outside the checkout; without them a browser"):format(
            cfg.playwright.used_by,
            cfg.playwright.version
          ),
          "      # sheet is a reported skip.",
          "      - if: matrix.hosted && matrix.steps == ''",
          "        shell: bash",
          "        run: |",
          ('          npm install --prefix "$RUNNER_TEMP/pw" --no-save --no-package-lock playwright-core@%s'):format(
            cfg.playwright.version
          ),
          '          export PLAYWRIGHT_BROWSERS_PATH="$RUNNER_TEMP/pw-browsers"',
          '          "$RUNNER_TEMP/pw/node_modules/.bin/playwright-core" install --with-deps chromium',
          '          echo "TESTING_PLAYWRIGHT_DIR=$RUNNER_TEMP/pw" >> "$GITHUB_ENV"',
          '          echo "PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWSERS_PATH" >> "$GITHUB_ENV"',
          "",
        }, "\n")
      or "",
    -- a version listed in M.SHA256.luals (checked above): the tarball is checked before it is unpacked
    LUALS_STEP = cfg.luals
        and table.concat({
          M.wrap(
            ("%s: lua-language-server %s, the release tarball of LuaLS checked against its pinned sha256 (testing.ci.workflow.SHA256.luals), on the leg with the whole profile."):format(
              cfg.luals.used_by,
              cfg.luals.version
            ),
            "      # "
          ) .. "      - if: matrix.hosted && matrix.steps == ''",
          "        shell: bash",
          "        run: |",
          '          tarball="$RUNNER_TEMP/luals.tar.gz"',
          ('          curl -fsSL -o "$tarball" "https://github.com/LuaLS/lua-language-server/releases/download/%s/lua-language-server-%s-linux-x64.tar.gz"'):format(
            cfg.luals.version,
            cfg.luals.version
          ),
          ('          echo "%s  $tarball" | sha256sum -c -'):format(
            M.SHA256.luals[cfg.luals.version]
          ),
          '          mkdir -p "$RUNNER_TEMP/luals"',
          '          tar -xzf "$tarball" -C "$RUNNER_TEMP/luals"',
          '          echo "$RUNNER_TEMP/luals/bin" >> "$GITHUB_PATH"',
          "",
        }, "\n")
      or "",
    ENV = table.concat(env),
    PUBLISH_JOB = publish_job,
    VERIFIED_JOB = verified_job,
    PIPELINE_GATE = pipeline_gate,
  }
  local text, err = scaffold.render_template("ci_generated.yml.tpl", vars)
  if not text then
    return nil, { tostring(err) }
  end
  if cfg.min_nvim then
    text = M.with_min_nvim(text, cfg.min_nvim)
  end
  return text, {}
end

---`ci.workflow.min_nvim`: one more hosted ubuntu leg, `ubuntu-min`, runs the suite on the promised minimum version.
---Only the text of a workflow WITH the key changes: the leg joins the matrix, the setup step and the cache key take the
---version of the leg (`matrix.nvim`, unset on the other legs), and a comment line names the version
---(`nvim: v0.11.4`, which a spec of the repository can look for).
---@param text string The rendered workflow (layout hosted).
---@param min { version: string, why: string }
---@return string
function M.with_min_nvim(text, min)
  local leg = ('{"name":"ubuntu-min","runs-on":"ubuntu-latest","hosted":true,"steps":"--step=suite","nvim":"%s"}'):format(
    min.version
  )
  local version = ("${{ matrix.nvim || '%s' }}"):format(M.TOOLS.nvim)
  ---Replace the first plain `old` at or after `from`; it must be there.
  local function swap(old, new, what, from)
    local at = text:find(old, from or 1, true)
    assert(at, "min_nvim: " .. what .. " was not found")
    text = text:sub(1, at - 1) .. new .. text:sub(at + #old)
    return at
  end
  -- the leg joins the end of the matrix line, a comment above it names the version
  local include = swap("        include: ", "        include: ", "the matrix line")
  swap("]') }}\n", "," .. leg .. "]') }}\n", "the end of the matrix line", include)
  local note = M.wrap(
    ("ubuntu-min: the suite on the promised minimum, nvim: v%s (%s). It runs only the suite: the tools come from the full leg."):format(
      min.version,
      min.why
    ),
    "        # "
  )
  swap("        include: ", note .. "        include: ", "the matrix line")
  swap(
    "\n          version: v" .. M.TOOLS.nvim .. "\n",
    "\n          version: v" .. version .. "\n",
    "the setup step"
  )
  -- every cache key (restore, restore-keys, save) carries the version of the leg
  local plain = "nvim" .. M.TOOLS.nvim .. "-"
  while text:find(plain, 1, true) do
    swap(plain, "nvim" .. version .. "-", "a cache key")
  end
  return text
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
