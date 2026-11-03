-- TESTS/testing/cache_worktree_link_spec.lua -- the `.git` FILE of a linked worktree (`gitdir: <path>`) names a directory
-- of the checkout, not of the commit: two worktrees of the same commit must have the same key, whatever that file says
-- (`testing ci commit` checks every commit out into a worktree of its own and shares the result cache between them).
-- A real `.git` change of a plain checkout (a directory) is not what this is about.

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
    local k, why = cache.key({ file = file }, {
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
    return k, why
  end

  local PURE = "return function(H) H.ok(true, 'p') end\n"
  -- a spec that names the `.git` entry of the project (an input of its key)
  local NAMES_GIT = "return function(H) H.ok(vim.uv.fs_stat('.git') ~= nil, 'repo') end\n"

  for _, case in ipairs({ { "pure", PURE }, { "names .git", NAMES_GIT } }) do
    local a =
      S.project({ ["TESTS/p_spec.lua"] = case[2], [".git"] = "gitdir: /x/a/.git/worktrees/a\n" })
    local b =
      S.project({ ["TESTS/p_spec.lua"] = case[2], [".git"] = "gitdir: /y/b/.git/worktrees/b\n" })
    local ka, wa = key_of(a, "TESTS/p_spec.lua")
    local kb, wb = key_of(b, "TESTS/p_spec.lua")
    ok(
      ka ~= nil and kb ~= nil,
      case[1] .. ": both have a key (" .. tostring(wa) .. ", " .. tostring(wb) .. ")"
    )
    ok(ka == kb, case[1] .. ": the link file of the worktree is not part of the key")
    -- another file of the project still is
    S.edit(b, "TESTS/p_spec.lua", case[2] .. "-- edited\n")
    local kc = key_of(b, "TESTS/p_spec.lua")
    ok(kc ~= kb, case[1] .. ": an edit of the spec still changes the key")
    cache.reset()
    S.remove(a)
    S.remove(b)
  end
end
