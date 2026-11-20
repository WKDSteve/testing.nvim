---@module 'testing.export.auto'
---@brief After a final check (`ci commit` of a whole tree, `ci land`), write the export folder the hubs read.
---@description
--- hub-desktop's monitor, testing-desktop and testing-web read a folder that `testing export --out` writes; written by
--- hand, it was 15 days old on 2026-11-20. With `TESTING_EXPORT_DIR` set, the command-line entry
--- (`scripts/testing.lua`) arms this module (`M.from_env`, handed down as `sv.export_after`), and after
--- `testing ci commit` without `--quick` (the final check before a push) and after `testing ci land` the export of
--- the fleet below `TESTING_EXPORT_REPOS_ROOT` (else `REPOS_DIR`, else the folder above the repository) is written there:
--- `testing export --out <dir> --repos-root=<root>`, the same code, the same data classes, about 3 s.
---
--- Never under a CI service (`CI` set), never for a library call (nothing armed), never for `--quick`, `--help` or
--- `--repos-root` of `ci commit`. The export never changes the verdict or the exit code of the run: one line says what
--- became of it. Nothing is committed or pushed (`testing-results/export.sh` does that by hand).

local M = {}

---The folder to write; unset or empty: off.
M.DIR_ENV = "TESTING_EXPORT_DIR"
---The repositories root of the export (default: `REPOS_DIR`, else the folder above the repository that ran).
M.ROOT_ENV = "TESTING_EXPORT_REPOS_ROOT"

---@class Testing.ExportAuto
---@field dir string The export folder.
---@field repos_root? string The repositories root.

---What the command-line entry arms.
---@param getenv fun(name: string): string|nil
---@return Testing.ExportAuto|nil
function M.from_env(getenv)
  local function value(name)
    local v = getenv(name)
    return (v and v ~= "") and v or nil
  end
  local dir = value(M.DIR_ENV)
  if not dir or value("CI") then
    return nil
  end
  return { dir = dir, repos_root = value(M.ROOT_ENV) or value("REPOS_DIR") }
end

---The repository a `ci commit` / `ci land` command line ran for, when its result is final; nil otherwise.
---@param kind "commit"|"land"
---@param argv string[] The arguments after `ci commit` / `ci land`.
---@return string|nil root
function M.final_root(kind, argv)
  local ok, args =
    pcall(require(kind == "land" and "testing.ci.land" or "testing.ci.commit").parse, argv)
  if not ok or type(args) ~= "table" or args.help then
    return nil
  end
  if kind == "commit" and (args.quick or #(args.repos_roots or {}) > 0) then
    return nil
  end
  return (vim.fs.normalize(vim.fn.fnamemodify(args.root or ".", ":p")):gsub("/$", ""))
end

---Write the export after a run; one line on `sv.out` either way. Never raises.
---@param kind "commit"|"land"
---@param argv string[] The arguments after `ci commit` / `ci land`.
---@param sv table The services (`export_after`, `out`, `env`, `state_dir`).
---@return boolean|nil written nil when nothing was to be written (not armed, not a final check)
function M.after(kind, argv, sv)
  local auto = sv.export_after
  if type(auto) ~= "table" or type(auto.dir) ~= "string" then
    return nil
  end
  local root = M.final_root(kind, argv)
  if not root then
    return nil
  end
  local repos_root = auto.repos_root or vim.fs.dirname(root)
  local said, errs = {}, {}
  local ok, code = pcall(require("testing.export.folder").main, {
    "--out",
    auto.dir,
    "--repos-root=" .. repos_root,
  }, {
    out = function(line)
      said[#said + 1] = line
    end,
    err = function(line)
      errs[#errs + 1] = line
    end,
    env = sv.env,
    state_dir = sv.state_dir,
  })
  if ok and code == 0 then
    sv.out(("export (%s): %s"):format(M.DIR_ENV, said[#said] or "written"))
    return true
  end
  local why = ok and (errs[1] or ("exit " .. tostring(code))) or tostring(code)
  sv.out(("export (%s): not written (%s); the verdict above stands"):format(M.DIR_ENV, why))
  return false
end

return M
