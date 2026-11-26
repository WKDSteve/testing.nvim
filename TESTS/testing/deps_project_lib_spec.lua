-- TESTS/testing/deps_project_lib_spec.lua -- the lib.nvim the specs of a project load (`testing.deps.project_lib`):
-- a project that is lib.nvim itself (a worktree, the snapshot of `ci commit`) loads its own checkout, not the lib.nvim
-- beside the runner, in this process and in a child; a consumer loads the lib.nvim it resolves, and a note says when
-- that is no checkout of its own. Found 2026-11-24: in a lib.nvim worktree `testing run` / `ci commit` loaded
-- `$REPOS_DIR/lib.nvim`, the new code of the worktree never ran.
-- It starts editors that run the file of a fixture project and nothing else: the key holds nvim and, through the
-- closure of `testing.cli`, every module of this runner a started editor loads.
---@diagnostic disable: need-check-nil

-- @cache-allow spawn
-- @cache-allow outside
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 900) .. ")"
    )
  end
  local deps = require("testing.deps")
  local runner_lib = assert(deps.resolve("lib.nvim", deps.self_dir()), "the runner's lib.nvim")

  local made = {}
  local function tmp(suffix)
    local d = vim.fs.normalize(vim.fn.tempname()) .. suffix
    vim.fn.mkdir(d, "p")
    made[#made + 1] = d
    return d
  end
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end
  ---A lib.nvim checkout at `dir`: the marker and, with `complete`, copies of what this runner needs of it (the files of
  ---`deps.LIB_REQUIRED`, from the runner's lib.nvim: a module this runner loads from it later still works).
  local function fake_lib(dir, complete)
    vim.fn.mkdir(dir .. "/lua/lib/nvim", "p")
    if complete then
      for _, req in ipairs(deps.LIB_REQUIRED) do
        for _, tail in ipairs({ ".lua", "/init.lua" }) do
          local src = runner_lib.dir .. "/lua/" .. req.module .. tail
          if vim.fn.filereadable(src) == 1 then
            write(dir .. "/lua/" .. req.module .. tail, read(src))
          end
        end
      end
    end
    return dir
  end

  -- ======================================================================== project_lib
  local own = fake_lib(tmp("-libwt"), true)
  local lib, note = deps.project_lib(own, {}, runner_lib)
  ok(lib ~= nil and deps.same_dir(lib.dir, own), "lib.nvim itself: its own checkout")
  eq(lib and lib.source, "the project itself", "... named so")
  has(
    note,
    "lib.nvim for the specs: the project itself",
    "... and a note says it is not the runner's"
  )

  local old = fake_lib(tmp("-libold"), false)
  lib, note = deps.project_lib(old, {}, runner_lib)
  eq(lib, nil, "lib.nvim itself, too old for this runner: the runner's stays")
  has(
    note,
    "is too old for this runner",
    "... and the note says the specs do not load the project's"
  )

  lib, note = deps.project_lib(runner_lib.dir, {}, runner_lib)
  eq({ lib and lib.dir, note }, { runner_lib.dir, nil }, "the runner's own lib.nvim: no note")

  local consumer = tmp("-consumer")
  eq(
    { deps.project_lib(consumer, {}, runner_lib) },
    {},
    "a project without lib.nvim: the runner's, no note"
  )

  local beside = fake_lib(tmp("-beside"), true)
  lib, note = deps.project_lib(consumer, {
    { name = "lib.nvim", dir = beside, source = "../lib.nvim (beside the runner)", locations = {} },
  }, runner_lib)
  eq(lib and lib.dir, beside, "a consumer: the lib.nvim it resolves")
  has(note, "not a checkout of the project's own", "... from beside the runner: said so")
  note = select(
    2,
    deps.project_lib(consumer, {
      { name = "lib.nvim", dir = beside, source = "stdpath('data')/lazy/lib.nvim", locations = {} },
    }, runner_lib)
  )
  has(note, "stdpath('data')/lazy/lib.nvim", "... from the plugin manager: said so too")
  lib, note = deps.project_lib(consumer, {
    { name = "lib.nvim", dir = beside, source = ".deps/lib.nvim", locations = {} },
  }, runner_lib)
  eq({ lib and lib.dir, note }, { beside, nil }, "... from .deps/lib.nvim: its own, no note")
  lib, note = deps.project_lib(consumer, {
    { name = "lib.nvim", dir = beside, source = "$LIB_NVIM_DIR", locations = {} },
  }, runner_lib)
  eq(
    { lib and lib.dir, note },
    { beside, nil },
    "... from $LIB_NVIM_DIR: an explicit choice, no note"
  )

  -- ======================================================================== child_rtp
  local options = require("testing.run.options")
  local _, append, env = options.child_rtp({ root = own, project = { deps = {} }, args = {} })
  eq(append[1], own, "child of lib.nvim itself: its own checkout first, not the runner's")
  eq(env.LIB_NVIM_DIR, own, "... and $LIB_NVIM_DIR names it")
  if not deps.same_dir(own, runner_lib.dir) then
    ok(
      append[2] ~= nil and deps.same_dir(append[2], runner_lib.dir),
      "... the runner's lib.nvim only behind it (what the runner needs and the project lacks): "
        .. vim.inspect(append)
    )
  end
  _, append, env = options.child_rtp({ root = old, project = { deps = {} }, args = {} })
  eq(
    { append[1], env.LIB_NVIM_DIR },
    { runner_lib.dir, runner_lib.dir },
    "child of a too old one: the runner's"
  )

  -- ======================================================================== use_lib
  do
    local saved_rtp = vim.o.runtimepath
    local saved = {}
    for name, mod in pairs(package.loaded) do
      if name == "lib" or name:sub(1, 4) == "lib." then
        saved[name] = mod
      end
    end
    package.loaded["lib.nvim.zz_probe_loaded"] = { stale = true }
    deps.use_lib(own)
    local first = vim.split(vim.o.runtimepath, ",", { plain = true })[1]
    local dropped = package.loaded["lib.nvim.zz_probe_loaded"] == nil
    vim.o.runtimepath = saved_rtp
    package.loaded["lib.nvim.zz_probe_loaded"] = nil
    for name, mod in pairs(saved) do
      package.loaded[name] = mod
    end
    ok(deps.same_dir(first, own), "use_lib: the checkout comes first on the runtimepath")
    ok(
      dropped,
      "use_lib: a lib module loaded before is dropped (the next require finds the new checkout)"
    )
  end

  -- ======================================================================== end to end
  -- a lib.nvim worktree whose spec asks which file `lib.nvim.cross.shell_quote.single` comes from (it is in both the
  -- worktree and the runner's lib.nvim), in this process and in a child of its own
  local probe = ([[
return function(H)
  local want = %q
  local f = require("lib.nvim.cross.shell_quote.single")
  local src = vim.fs.normalize(debug.getinfo(f, "S").source:sub(2))
  H.eq(src:lower():sub(1, #want) == want:lower(), true, "required from the worktree: " .. src)
  local hit = vim.api.nvim_get_runtime_file("lua/lib/nvim/cross/shell_quote/single.lua", false)[1] or ""
  hit = vim.fs.normalize(hit)
  H.eq(hit:lower():sub(1, #want) == want:lower(), true, "first on the runtimepath: " .. hit)
end
]]):format(own .. "/")
  write(own .. "/TESTS/probe_spec.lua", probe)
  local entry = deps.self_dir() .. "/scripts/testing.lua"
  for _, mode in ipairs({ "none", "file" }) do
    local res = vim
      .system({
        vim.v.progpath,
        "-n",
        "-i",
        "NONE",
        "--headless",
        "-u",
        "NONE",
        "-l",
        entry,
        own,
        "--guard",
        "fs=off",
        "--no-timings",
        "--no-cache",
        "--isolated",
        mode,
      }, { text = true, env = { TESTING_AGENT = "0", TESTING_TRUST = "1" } })
      :wait(120000)
    eq(
      res.code,
      0,
      ("--isolated %s: the worktree's spec loads the worktree's lib.nvim\n%s%s"):format(
        mode,
        res.stdout or "",
        res.stderr or ""
      )
    )
    has(
      res.stderr,
      "lib.nvim for the specs: the project itself",
      "--isolated " .. mode .. ": the note"
    )
  end

  for _, d in ipairs(made) do
    pcall(vim.fn.delete, d, "rf")
  end
end
