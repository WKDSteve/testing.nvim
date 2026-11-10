-- testing:keep-file the dogfood init: it resolves lib.nvim and the checkout itself, no generated bootstrap
-- TESTS/minimal_init.lua -- puts testing.nvim and lib.nvim on the runtimepath for a headless child.
--
-- Named by `minit` in .testing.lua; isolated child runs load it (`nvim -u TESTS/minimal_init.lua`),
-- it does not run anything itself. lib.nvim is a hard runtime dependency, so a missing checkout is
-- fatal: the message names all four places that were searched (testing.deps) and the process exits
-- with code 3 (a run that cannot load its dependency must never look green).

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))

vim.opt.rtp:prepend(root)

local deps = require("testing.deps")
local lib, why = deps.resolve("lib.nvim", root)
if not lib then
  io.stderr:write(why, "\n")
  os.exit(3)
end
vim.opt.rtp:append(lib.dir)

-- git of the specs: the fixture repositories a spec makes see the configuration below, not this machine's global and
-- system configuration. A global `core.hooksPath` ran a shell per hook on every `git commit` of a fixture (four per
-- commit, about 0.4 s each on Windows), signing settings start ssh-keygen, `core.autocrlf` differs from machine to
-- machine. A spec that needs a setting passes it with `-c` or `git config` in its repository.
-- Only in a spec's child editor: the runner's own process runs this file too (for the keys; `testing.run.project` is
-- loaded there), and its git works on the real checkout, which needs the machine's configuration (`safe.directory`,
-- credentials, ...). The text is here, not in a file of the checkout, so that it is part of every key (this file is)
-- and no key names the place of a checkout.
if package.loaded["testing.run.project"] == nil then
  local gitconfig = vim.fn.stdpath("data") .. "/testing-spec.gitconfig"
  vim.fn.mkdir(vim.fn.stdpath("data"), "p")
  local f = io.open(gitconfig, "wb")
  if f then
    f:write(table.concat({
      "[core]",
      "\tautocrlf = false",
      "\tfscache = true",
      "[init]",
      "\tdefaultBranch = master",
      "[user]",
      "\tname = testing.nvim spec",
      "\temail = spec@example.invalid",
      "[commit]",
      "\tgpgsign = false",
      "[tag]",
      "\tgpgsign = false",
      "",
    }, "\n"))
    f:close()
    vim.env.GIT_CONFIG_GLOBAL = gitconfig
    vim.env.GIT_CONFIG_NOSYSTEM = "1"
  end
end

return { root = root, lib = lib.dir }
