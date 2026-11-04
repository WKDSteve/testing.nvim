---@module 'testing.ci.hook'
---@brief `testing ci hook install|remove`: a `pre-push` hook that asks `testing ci verify` first and runs a profile only when needed.
---@description
--- ```
--- testing ci hook install [--run=<profile>] [--verify=<profile>] [--auto-trust] [--root=<dir>]
--- testing ci hook install --all --repos-root=<dir> [--run=<profile>] [--verify=<profile>] [--auto-trust]
--- testing ci hook remove [--root=<dir>]
--- ```
---
--- The hook (`<git hooks dir>/pre-push`, wherever git keeps it: a worktree, `core.hooksPath`) does two things and
--- computes no verdict of its own:
---
---   1. `testing ci verify [--profile=<verify>]`: a state that is already proven ends the hook with exit 0
---      (a tenth of a second, no step runs);
---   2. otherwise `testing ci --profile=<run> --reuse` (default `fast`): its exit code is the hook's, so a red
---      pipeline blocks the push. `git push --no-verify` skips the hook.
---
--- It finds testing.nvim without any Neovim configuration: `$TESTING_NVIM_DIR`, `<repo>/.deps/testing.nvim`,
--- `<repo>/../testing.nvim`, then the checkout the install ran from. A hook that is not ours is never overwritten
--- or removed; the hook of `:MyPlugins ci hook` (mark `# MyPlugins ci pre-push hook`) is recognised and replaced.
---
--- `install --all --repos-root=<dir>` (repeatable) does that for every repository below the root whose `.testing.lua`
--- has a `ci` section (the repositories `testing ci --repos` finds) and prints one line per repository: `installed`,
--- `unchanged` (it was there with the same text), `replaced` (the hook of `:MyPlugins ci`) or `skipped` (a hook that
--- is not ours, a profile the repository does not have). Exit 0 when nothing was skipped, 1 otherwise. The hook is only
--- a file in the hooks folder: no step runs, and the first push is the hand test.

local M = {}

M.EXIT_OK, M.EXIT_REFUSED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

---First line (after the shebang) of the hook we write; `remove` only deletes a file that carries it.
M.MARK = "# testing ci pre-push hook"
---The mark of the hook this one replaces (nvim-config, `:MyPlugins ci hook install`).
M.LEGACY_MARK = "# MyPlugins ci pre-push hook"

M.DEFAULT_RUN = "fast"

M.USAGE = table.concat({
  "usage: testing ci hook install [--run=<profile>] [--verify=<profile>] [--auto-trust] [--snapshot] [--root=<dir>]",
  "       testing ci hook install --all --repos-root=<dir> [--run=<profile>] [--verify=<profile>] [--auto-trust]",
  "       testing ci hook remove [--root=<dir>]",
  "  --run=<profile>     the profile the hook runs when the state is not proven (default: fast)",
  "  --verify=<profile>  the profile whose proof is asked first (default: ci.default)",
  "  --auto-trust        after a green hook release the pushed commits for the runner guard when all of them",
  "                      were made here (no merge, none from a remote): testing ci trust --pushed",
  "  --snapshot          run the profile on a snapshot of each pushed commit (testing ci --snapshot --rev) instead of the working tree",
  "  --root=<dir>        the repository (default: the current directory)",
  "  --all               install: every repository below --repos-root=<dir> (repeatable) with a ci section",
  "  `git push --no-verify` skips the hook. A pre-push hook that is not ours is never touched.",
}, "\n")

---The checkout this module was loaded from (its `scripts/testing.lua` is the driver the hook falls back to).
---@return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.normalize(vim.fn.fnamemodify(src, ":p:h:h:h:h"))
end

---A word for a shell script: only the characters a profile name or a path may have, so no quoting is needed.
---@param s string
---@return boolean
local function safe_word(s)
  return s:match("^[%w%._%-/:]+$") ~= nil and s:find("..", 1, true) == nil
end

---Text of the hook. No backslashes: it runs in Git Bash and in Linux sh alike.
---@param o { run: string, verify?: string, driver_dir: string, auto_trust?: boolean, snapshot?: boolean }
---@return string
function M.text(o)
  local verify = o.verify and (" --profile=" .. o.verify) or ""
  -- git gives the hook what it pushes on stdin; read once, before a step can take it. A release never blocks a push.
  local read_refs = {}
  if o.auto_trust or o.snapshot then
    read_refs[1] = 'refs="$(cat)"'
  end
  if o.auto_trust then
    read_refs[2] =
      "trust_pushed() { printf '%s\\n' \"$refs\" | testing_ci trust --pushed >&2 || true; }"
  end
  local blocked =
    'echo "pre-push: testing ci is red, push blocked (git push --no-verify skips it)" >&2; exit 1;'
  local run_lines
  if o.snapshot then
    -- Every commit the push names on a branch, on a snapshot of its own: the working tree (another session's edits)
    -- has no say, and neither has HEAD when the push names something else. A tag or a deletion checks nothing.
    run_lines = {
      'head="$(git rev-parse HEAD)"',
      'seen=""',
      'for sha in $(echo "$refs" | while read -r local_ref local_sha remote_ref remote_sha; do case "$remote_ref" in refs/heads/*) case "$local_sha" in *[!0]*) echo "$local_sha" ;; esac ;; esac; done); do',
      '  case " $seen " in *" $sha "*) continue ;; esac',
      '  seen="$seen $sha"',
      ('  if [ "$sha" = "$head" ] && testing_ci verify%s; then continue; fi'):format(verify),
      '  echo "pre-push: not proven, running testing ci --profile='
        .. o.run
        .. ' --snapshot --rev=$sha"',
      ('  testing_ci --profile=%s --snapshot --rev="$sha" || { %s }'):format(o.run, blocked),
      "done",
    }
  else
    run_lines = {
      ("testing_ci verify%s && %s"):format(
        verify,
        o.auto_trust and "{ trust_pushed; exit 0; }" or "exit 0"
      ),
      'echo "pre-push: not proven, running testing ci --profile=' .. o.run .. '"',
      ("testing_ci --profile=%s --reuse || { %s }"):format(o.run, blocked),
    }
  end
  local lines = {
    "#!/bin/sh",
    M.MARK .. " (git push --no-verify skips it)",
    'root="$(git rev-parse --show-toplevel)" || exit 1',
    'driver=""',
    ('for dir in "${TESTING_NVIM_DIR:-}" "$root/.deps/testing.nvim" "$root/../testing.nvim" "%s"; do'):format(
      o.driver_dir
    ),
    '  if [ -n "$dir" ] && [ -f "$dir/scripts/testing.lua" ]; then driver="$dir/scripts/testing.lua"; break; fi',
    "done",
    'if [ -z "$driver" ]; then',
    "  echo 'pre-push: testing.nvim was not found ($TESTING_NVIM_DIR, .deps/testing.nvim, ../testing.nvim): not checking' >&2",
    "  exit 1",
    "fi",
    'cd "$root" || exit 1',
    "# git hands a hook the variables of the operation in progress; a spec that runs git must not inherit them",
    "unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY",
    "unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE",
    "unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE",
    'testing_ci() { nvim -n -i NONE --headless -u NONE -l "$driver" ci "$@"; }',
    "@READ_REFS@",
    "@RUN@",
    "@TRUST_LAST@",
    "",
  }
  local out = {}
  for _, line in ipairs(lines) do
    if line == "@READ_REFS@" then
      vim.list_extend(out, read_refs)
    elseif line == "@RUN@" then
      vim.list_extend(out, run_lines)
    elseif line == "@TRUST_LAST@" then
      out[#out + 1] = o.auto_trust and "trust_pushed" or nil
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

---Hook folder of a checkout, as git sees it (a worktree's `.git` is a file, `core.hooksPath` may move it).
---@param dir string
---@return string|nil
function M.hooks_dir(dir)
  local ok, obj = pcall(
    vim.system,
    { "git", "-C", dir, "rev-parse", "--git-path", "hooks" },
    { text = true }
  )
  local res = ok and obj and obj:wait(10000) or nil
  local out = res and vim.trim(res.stdout or "") or ""
  if not res or res.code ~= 0 or out == "" then
    return nil
  end
  if out:match("^%a:[/\\]") or out:sub(1, 1) == "/" then
    return out
  end
  return dir .. "/" .. out
end

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---A global `core.hooksPath` (a guard against force pushes, say) puts its own `pre-push` where git looks for hooks and
---hands over to the one of the repository, `<git-common-dir>/hooks/pre-push`. Writing ours over that hook is out of
---the question; writing it to the repository's own folder is exactly what the global hook runs next.
---@param dir string The checkout.
---@param hooks string The folder git looks in (`M.hooks_dir`).
---@return string hooks The folder to write to.
---@return string|nil existing The text of the `pre-push` there.
---@return boolean chained The hook of the repository's own folder is used because the global one chains to it.
function M.resolve(dir, hooks)
  local existing = read(hooks .. "/pre-push")
  if existing and not (M.marked(existing, M.MARK) or M.marked(existing, M.LEGACY_MARK)) then
    if existing:find("--git-common-dir)/hooks/pre-push", 1, true) then
      local ok, obj = pcall(
        vim.system,
        { "git", "-C", dir, "rev-parse", "--git-common-dir" },
        { text = true }
      )
      local res = ok and obj and obj:wait(10000) or nil
      local out = res and res.code == 0 and vim.trim(res.stdout or "") or ""
      if out ~= "" then
        if not (out:match("^%a:[/\\]") or out:sub(1, 1) == "/") then
          out = dir .. "/" .. out
        end
        local own = vim.fs.normalize(out) .. "/hooks"
        if own ~= vim.fs.normalize(hooks) then
          return own, read(own .. "/pre-push"), true
        end
      end
    end
  end
  return hooks, existing, false
end

---Does a hook carry the mark as its second line (right after the shebang)? A foreign hook that merely mentions it does not.
---@param text string|nil
---@param mark string
---@return boolean
function M.marked(text, mark)
  if not text then
    return false
  end
  local second = text:match("^[^\n]*\n([^\n]*)")
  return second ~= nil and second:sub(1, #mark) == mark
end

---@class Testing.Ci.Hook.Args
---@field action "install"|"remove"|nil
---@field run string
---@field verify? string
---@field auto_trust boolean
---@field snapshot boolean
---@field root string
---@field all boolean
---@field repos_roots string[]
---@field help boolean

---@param argv string[] The arguments after `hook`.
---@return Testing.Ci.Hook.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Hook.Args
  local args = {
    run = M.DEFAULT_RUN,
    root = ".",
    help = false,
    auto_trust = false,
    snapshot = false,
    all = false,
    repos_roots = {},
  }
  for i, a in ipairs(argv) do
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    if a == "-h" or a == "--help" then
      args.help = true
    elseif i == 1 and (a == "install" or a == "remove") then
      args.action = a
    elseif a == "--auto-trust" then
      args.auto_trust = true
    elseif a == "--snapshot" then
      args.snapshot = true
    elseif a == "--all" then
      args.all = true
    elseif key == "repos-root" then
      if value == "" then
        return nil, "--repos-root needs a value"
      end
      table.insert(args.repos_roots, value)
    elseif key == "run" or key == "verify" or key == "root" then
      if value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key ~= "root" and not safe_word(value) then
        return nil, ("--%s: '%s' is not a profile name"):format(key, value)
      end
      args[key] = value
    else
      return nil, ("unknown argument %s"):format(a)
    end
  end
  if not args.action and not args.help then
    return nil, "say install or remove"
  end
  if args.all and args.action ~= "install" then
    return nil, "--all goes with install"
  end
  if args.all and #args.repos_roots == 0 then
    return nil, "--all needs --repos-root=<dir>"
  end
  if #args.repos_roots > 0 and not args.all then
    return nil, "--repos-root goes with --all"
  end
  return args
end

---Write the hook of one checkout. `existing` is the text of a hook already there.
---@param root string
---@param hooks string The hooks folder of the checkout.
---@param args Testing.Ci.Hook.Args
---@param existing string|nil
---@return integer code
---@return string message
---@return string|nil state `installed`, `unchanged` or `replaced` (when the code is 0).
function M.install(root, hooks, args, existing)
  local path = hooks .. "/pre-push"
  local ours = M.marked(existing, M.MARK)
  local legacy = M.marked(existing, M.LEGACY_MARK)
  if existing and not (ours or legacy) then
    return M.EXIT_REFUSED, "testing ci hook: a pre-push hook that is not ours exists, left alone"
  end
  -- the profiles must exist, or the first push would fail with a usage error
  local pipeline, problems = require("testing.ci.schema").load(root)
  if not pipeline then
    return M.EXIT_USAGE, "testing ci hook: " .. table.concat(problems or {}, "; ")
  end
  for _, name in ipairs({ args.run, args.verify or pipeline.default }) do
    if not pipeline.profiles[name] then
      return M.EXIT_USAGE, ("testing ci hook: unknown profile %s"):format(name)
    end
  end
  local driver_dir = plugin_root()
  if not safe_word(driver_dir) then
    return M.EXIT_USAGE,
      ("testing ci hook: the path %s has characters a hook script cannot take"):format(driver_dir)
  end
  local text = M.text({
    run = args.run,
    verify = args.verify,
    driver_dir = driver_dir,
    auto_trust = args.auto_trust,
    snapshot = args.snapshot,
  })
  if ours and existing == text then
    return M.EXIT_OK,
      "testing ci hook: pre-push hook already installed (git push --no-verify skips it)",
      "unchanged"
  end
  local atomic = require("lib.nvim.fs.write.atomic")
  local ok, err = atomic(path, text, { mkdirp = true })
  if not ok then
    return M.EXIT_INFRA, ("testing ci hook: cannot write %s: %s"):format(path, tostring(err))
  end
  local chmod_ok, chmod_err = vim.uv.fs_chmod(path, tonumber("755", 8))
  if not chmod_ok then
    return M.EXIT_INFRA,
      ("testing ci hook: cannot make %s executable: %s"):format(path, tostring(chmod_err))
  end
  return M.EXIT_OK,
    ("testing ci hook: pre-push hook installed%s (git push --no-verify skips it)"):format(
      legacy and ", replacing the one of :MyPlugins ci" or ""
    ),
    legacy and "replaced" or "installed"
end

---`install --all`: every repository below the roots that has a `ci` section, one line each.
---@param args Testing.Ci.Hook.Args
---@param sv { out: fun(s: string), err: fun(s: string) }
---@return integer
local function install_all(args, sv)
  local repos = require("testing.ci.repos")
  local dirs = {}
  for _, r in ipairs(args.repos_roots) do
    local root = vim.fs.normalize(vim.fn.fnamemodify(r, ":p")):gsub("/$", "")
    if vim.fn.isdirectory(root) ~= 1 then
      sv.err(("testing ci hook: --repos-root %s is not a directory"):format(root))
      return M.EXIT_USAGE
    end
    vim.list_extend(dirs, repos.scan(root))
  end
  if #dirs == 0 then
    sv.err("testing ci hook: no repository with a ci section below the roots")
    return M.EXIT_USAGE
  end
  local skipped, worst = 0, M.EXIT_OK
  for _, dir in ipairs(dirs) do
    local name = vim.fs.basename(dir)
    local hooks = M.hooks_dir(dir)
    if not hooks then
      skipped, worst = skipped + 1, math.max(worst, M.EXIT_REFUSED)
      sv.out(("%-28s skipped: not a git checkout"):format(name))
    else
      local own, existing, chained = M.resolve(dir, hooks)
      local code, msg, state = M.install(dir, own, args, existing)
      if code == M.EXIT_OK then
        sv.out(
          ("%-28s %s%s"):format(
            name,
            state,
            chained and " (in the repository's own hooks: a global hook chains to it)" or ""
          )
        )
      else
        skipped = skipped + 1
        worst = math.max(worst, code == M.EXIT_INFRA and code or M.EXIT_REFUSED)
        sv.out(("%-28s skipped: %s"):format(name, (msg:gsub("^testing ci hook: ", ""))))
      end
    end
  end
  sv.out(
    ("testing ci hook: %d repositor%s, %d skipped"):format(
      #dirs,
      #dirs == 1 and "y" or "ies",
      skipped
    )
  )
  return worst
end

---@param argv string[] The arguments after `hook`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing ci hook: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  if args.all then
    return install_all(args, sv)
  end
  local root = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  local hooks = vim.fn.isdirectory(root) == 1 and M.hooks_dir(root) or nil
  if not hooks then
    sv.err(("testing ci hook: %s is not a git checkout"):format(root))
    return M.EXIT_USAGE
  end
  local existing, chained
  hooks, existing, chained = M.resolve(root, hooks)
  local path = hooks .. "/pre-push"
  local ours = M.marked(existing, M.MARK)
  local legacy = M.marked(existing, M.LEGACY_MARK)

  if args.action == "remove" then
    if not existing then
      sv.out("testing ci hook: no pre-push hook")
      return M.EXIT_OK
    elseif not (ours or legacy) then
      sv.err("testing ci hook: the pre-push hook is not ours, left alone")
      return M.EXIT_REFUSED
    end
    local removed, why = os.remove(path)
    if not removed then
      sv.err(("testing ci hook: cannot remove %s: %s"):format(path, tostring(why)))
      return M.EXIT_INFRA
    end
    sv.out("testing ci hook: pre-push hook removed")
    return M.EXIT_OK
  end

  local code, msg = M.install(root, hooks, args, existing)
  if code ~= M.EXIT_OK then
    sv.err(msg)
    return code
  end
  sv.out(msg .. (chained and " (in the repository's own hooks: a global hook chains to it)" or ""))
  return M.EXIT_OK
end

M._plugin_root = plugin_root

return M
