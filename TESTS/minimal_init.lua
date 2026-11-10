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

-- git of the specs: the fixture repositories see TESTS/gitconfig, not this machine's global and system configuration
-- (a global `core.hooksPath` cost a shell per hook on every fixture commit; the file says why). Set here, so that the
-- runner computes the keys with it too (`testing.cache.tools` hashes the configuration git reads).
vim.env.GIT_CONFIG_GLOBAL = root .. "/TESTS/gitconfig"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

return { root = root, lib = lib.dir }
