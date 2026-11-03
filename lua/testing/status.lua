---@module 'testing.status'
---@brief `testing status`: is this repository (or the fleet) proven, in one line each and one exit code.
---@description
--- ```
--- testing status [<repo>...] [--all] [--remote] [--json] [--state-dir=<dir>]
--- ```
---
--- The answer to "is it good?" in one call, from what is already there (`testing ci overview` collects it): per
--- repository the local proof (`proven`: the last complete pipeline run is for this tree and verifies; `red`;
--- `unknown`; `none`: no testing.nvim) and, with `--remote`, the latest GitHub Actions run. Nothing is run (`ci verify`
--- compares the proof with now, it starts no pipeline).
---
--- * No argument: the repository of the current directory. `<repo>...` names directories; `--all` takes the
---   repositories of the setting `ci.overview` (as `testing ci overview` does).
--- * The first line is the verdict (`OK` or `NOT OK`) and the counts; a line per repository follows, the reason last.
--- * `--json` prints the document of `testing ci overview` (`testing-ci-overview/1`) instead.
--- * Exit 0 only when every repository is `proven` (and, with `--remote`, its CI is green); 1 otherwise; 2 usage;
---   3 internal failure.

local M = {}

M.EXIT_OK, M.EXIT_NOT_OK, M.EXIT_USAGE = 0, 1, 2

M.USAGE = table.concat({
  "usage: testing status [<repo>...] [--all] [--remote] [--json] [--state-dir=<dir>]",
  "  <repo>...        directories to report (default: the current directory)",
  "  --all            the repositories of the setting ci.overview (as `testing ci overview`)",
  "  --remote         also ask GitHub for the latest CI run (needs a read-only token; default: local only)",
  "  --json           print the document testing-ci-overview/1 instead of lines",
  "  --state-dir=<d>  the state directory (default: stdpath('state'))",
  "  exit: 0 every repository proven (and CI green with --remote), 1 not, 2 usage",
}, "\n")

---@class Testing.Status.Args
---@field repos string[]
---@field all boolean
---@field remote boolean
---@field json boolean
---@field help boolean
---@field state_dir? string

---@param argv string[]
---@return Testing.Status.Args|nil
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Status.Args
  local args = { repos = {}, all = false, remote = false, json = false, help = false }
  for _, a in ipairs(argv) do
    if a == "-h" or a == "--help" then
      args.help = true
    elseif a == "--all" then
      args.all = true
    elseif a == "--remote" then
      args.remote = true
    elseif a == "--json" then
      args.json = true
    elseif a:match("^%-%-state%-dir=.+") then
      args.state_dir = a:match("^%-%-state%-dir=(.+)$")
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      args.repos[#args.repos + 1] = a
    end
  end
  if args.all and #args.repos > 0 then
    return nil, "--all and named repositories exclude each other"
  end
  return args
end

---One line of a repository.
---@param r table A record of `testing.ci.overview.collect`.
---@param remote boolean
---@return string line
---@return boolean good
local function line_of(r, remote)
  local l = r["local"]
  local good = l.state == "proven"
  local parts = { ("%-24s local %-8s"):format(r.repo, l.state) }
  if remote then
    good = good and r.ci.overall == "success"
    parts[#parts + 1] = ("ci %s"):format(tostring(r.ci.overall))
  end
  local why = l.note
  if (not why or why == "") and remote and r.ci.note and r.ci.note ~= "" then
    why = r.ci.note
  end
  if why and why ~= "" then
    parts[#parts + 1] = "- " .. why
  end
  return table.concat(parts, "  "), good
end

---@param argv string[] The arguments after `status`.
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string }
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing status: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local overview = require("testing.ci.overview")
  local oargs
  if args.all then
    oargs = overview.parse({})
  else
    local repos = #args.repos > 0 and args.repos or { "." }
    oargs = overview.parse(repos)
  end
  if not oargs then
    sv.err("testing status: cannot work out the repositories")
    return M.EXIT_USAGE
  end
  local cfg = overview.config(vim.fs.normalize(vim.fn.fnamemodify(".", ":p")):gsub("/$", ""))
  local dirs, info = overview.resolve(oargs, cfg)
  if not dirs or #dirs == 0 then
    sv.err("testing status: " .. (dirs and "no repository found" or tostring(info)))
    return M.EXIT_USAGE
  end
  ---@cast info { excluded: string[], missing: string[] }
  local state_dir = args.state_dir
      and vim.fs.normalize(vim.fn.fnamemodify(args.state_dir, ":p")):gsub("/$", "")
    or sv.state_dir
  local now = overview.deps.now()
  local records =
    overview.collect(dirs, { state_dir = state_dir, no_remote = not args.remote, now = now }, sv)
  if args.json then
    sv.out(require("lib.nvim.json.canonical").encode(overview.document(records, info, now)))
  end
  local lines, bad = {}, 0
  for _, r in ipairs(records) do
    local text, good = line_of(r, args.remote)
    lines[#lines + 1] = text
    if not good then
      bad = bad + 1
    end
  end
  if not args.json then
    sv.out(
      ("%s | %d repositor%s, %d not proven%s"):format(
        bad == 0 and "OK" or "NOT OK",
        #records,
        #records == 1 and "y" or "ies",
        bad,
        args.remote and " or red in CI" or ""
      )
    )
    for _, text in ipairs(lines) do
      sv.out(text)
    end
  end
  return bad == 0 and M.EXIT_OK or M.EXIT_NOT_OK
end

return M
