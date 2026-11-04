---@meta
---@module 'testing.scaffold.@types'

-- #####################################################################
-- scaffold/init.lua

---@class Testing.Scaffold.Opts
---@field force? boolean Replace files that exist (default false: they are reported in `skipped`).
---@field plugin? string Module name of the plugin (default: detected, see `testing.scaffold`).
---@field deps? string[] Dependencies of the project besides testing.nvim (default `{ "lib.nvim" }`).
---@field hooks? boolean Write the hook recipes (`scripts/hooks/*`) instead of the setup; never replaces a file, `force` or not.
---@field workflow? string Write only the workflow of this kind (`M.WORKFLOWS`) instead of the setup; `force` replaces that one file. Without `deps` the dependencies are read from the text of the repository's files.
---@field owner? string GitHub owner the CI checks the dependencies out from (default `StefanBartl`).

---@class Testing.Scaffold.Result
---@field created string[] Paths relative to the root, forward slashes.
---@field replaced string[] Existing files that `force` overwrote (empty without force).
---@field skipped string[] Existing files that were left alone.
---@field errors string[] `"<path>: <reason>"`; empty on success.
---@field plugin? string The sanitized plugin name that was used.
---@field workflow_deps? string[] With `opts.workflow`: what the workflow checks out, the runner first.
---@field workflow_deps_from? string With `opts.workflow`: the file the dependencies were read from; nil: the default or `opts.deps`.

return {}
