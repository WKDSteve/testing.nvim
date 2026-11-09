-- TESTS/testing/cache_git_literal_spec.lua -- a guessed input under `.git` is no input: a module or spec that names
-- `".git"` looks for the repository root of the project it works on, not at this checkout's history, and the whole
-- object store as an input made every such spec uncacheable (more than 5000 files). A declared input under `.git`
-- (`-- @cache-inputs .git/HEAD`) stays strict.

---@diagnostic disable: need-check-nil, missing-fields, param-type-mismatch

-- @cache-allow env
-- (the fixtures of this spec are project files that mention the environment)
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")

  local function key_of(root, file)
    cache.reset()
    return cache.key({ file = file }, {
      root = root,
      cache_dir = vim.fs.normalize(vim.fn.tempname()),
      dep_roots = {},
      runner_version = "runner-1",
      nvim = "0.12.0-test",
      config_digest = "cfg-1",
      dialect = "a",
      env_names = {},
      environ = function()
        return {}
      end,
      hasher = hash.new(),
      spec_roots = { "TESTS" },
      unresolved = "error",
    })
  end

  -- the spec itself names `.git`; a project module that reads files names it (the root finder)
  local SPEC_NAMES_GIT =
    "return function(H) local f = io.open('.git/HEAD') H.ok(f ~= nil, 'repo') end\n"
  local MODULE = "local M = {}\nfunction M.head() local f = io.open('.git/HEAD') return f and f:read('*a') end\n"
    .. "return M\n"
  local SPEC_USES_MODULE =
    "return function(H) H.ok(require('proj.root').head() ~= nil, 'head') end\n"
  local DECLARED = "-- @cache-inputs .git/HEAD\n" .. SPEC_NAMES_GIT

  local cases = {
    { "spec literal", { ["TESTS/p_spec.lua"] = SPEC_NAMES_GIT }, true },
    {
      "module literal",
      { ["TESTS/p_spec.lua"] = SPEC_USES_MODULE, ["lua/proj/root.lua"] = MODULE },
      true,
    },
    { "declared", { ["TESTS/p_spec.lua"] = DECLARED }, false },
  }
  for _, case in ipairs(cases) do
    local files = vim.deepcopy(case[2])
    files[".git/HEAD"] = "ref: refs/heads/main\n"
    files[".git/objects/aa/one"] = "object one\n"
    local root = S.project(files)
    local k1, w1 = key_of(root, "TESTS/p_spec.lua")
    ok(k1 ~= nil, case[1] .. ": has a key (" .. tostring(w1) .. ")")
    S.edit(root, ".git/HEAD", "ref: refs/heads/other\n")
    S.edit(root, ".git/objects/bb/two", "object two\n")
    local k2 = key_of(root, "TESTS/p_spec.lua")
    if case[3] then
      ok(k1 == k2, case[1] .. ": a change below .git leaves the key alone")
    else
      ok(k1 ~= k2, case[1] .. ": a declared input below .git still changes the key")
    end
    -- the project is still an input
    S.edit(root, "TESTS/p_spec.lua", files["TESTS/p_spec.lua"] .. "-- edited\n")
    ok(key_of(root, "TESTS/p_spec.lua") ~= k2, case[1] .. ": an edit of the spec changes the key")
    cache.reset()
    S.remove(root)
  end
end
