-- TESTS/testing/sheet_native_host_spec.lua -- `native_host = { name, path }` in a browser sheet with an extension
-- (`testing.sheet.native_host`): the field is checked; before a run a foreign host of that name refuses it and the
-- leftover of a crashed run goes; after the run the key of this run goes, a foreign one stays (a registry in memory).
-- Where node, playwright-core and Chromium exist, the real thing: the fixture extension (fixtures/sheet_native_host)
-- asks the fixture host, which Chromium starts through the key or the profile of this run, and nothing stays.
-- @cache-allow time processes
-- @cache-inputs TESTS/testing/fixtures/sheet_native_host/
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch

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
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local browser = require("testing.sheet.browser")
  local nh = require("testing.sheet.native_host")
  local windows = require("testing.platform").is_windows()
  local here =
    vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
  local repo = vim.fs.dirname(vim.fs.dirname(here))
  -- the id Chromium derives from the `key` of the fixture's manifest (the same key as fixtures/sheet_extension)
  local ID = "jnkemndpamljmeokialekifcnbnobgph"
  local NAME = "testing.nvim_spec.host"
  local HOST = windows and "ext/host.cmd" or "ext/host.sh"

  local function sheet_of(fields)
    return vim.tbl_extend("force", {
      id = "ext.host",
      title = "native host",
      engine = "browser",
      extension = "ext",
      native_host = { name = NAME, path = HOST },
      steps = { { open = "chrome-extension://" .. ID .. "/page.html" } },
    }, fields)
  end

  -- 1. the form ---------------------------------------------------------------------------------------------------------
  ok(sheet.validate(sheet_of({})) ~= nil, "a host for the extension")
  local function refused(fields, needle, msg)
    local s, err = sheet.validate(sheet_of(fields))
    ok(s == nil, msg .. ": refused")
    has(err, needle, msg)
  end
  refused({ native_host = { name = "Io.X", path = "h" } }, "native_host.name", "upper case")
  refused({ native_host = { name = "io..x", path = "h" } }, "native_host.name", "an empty part")
  refused({ native_host = { name = "io.x-y", path = "h" } }, "native_host.name", "a dash")
  refused(
    { native_host = { name = "io.x", path = "../h" } },
    "relative to the project root",
    "above the root"
  )
  refused(
    { native_host = { name = "io.x", path = "C:/h.exe" } },
    "relative to the project root",
    "a drive"
  )
  refused(
    { native_host = { name = "io.x", path = "/h" } },
    "relative to the project root",
    "absolute"
  )
  refused(
    { native_host = { name = "io.x", path = "h", args = {} } },
    "unknown field args",
    "another field"
  )
  refused({ native_host = "io.x" }, "native_host must be a table", "not a table")
  refused(
    { native_host = { name = "io.x", path = "h", env = { ["A-B"] = "x" } } },
    "no variable name",
    "an env name with a dash"
  )
  refused(
    { native_host = { name = "io.x", path = "h", env = { NVIM_LOG = "x" } } },
    "no variable name",
    "an NVIM variable"
  )
  refused(
    { native_host = { name = "io.x", path = "h", env = { A = 1 } } },
    "native_host.env.A must be text",
    "a value that is no text"
  )
  local no_ext = sheet_of({})
  no_ext.extension = nil
  local s_no_ext, e_no_ext = sheet.validate(no_ext)
  ok(s_no_ext == nil, "without an extension: refused")
  has(e_no_ext, "native_host belongs to a browser sheet with an extension", "... says why")
  ok(
    nh.valid_name("io.github.wkdsteve.streamtap") and nh.valid_name("a_1"),
    "a name of Chromium's rule"
  )

  -- 2. before and after a run, with a registry in memory ---------------------------------------------------------------
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-host"
  vim.fn.mkdir(root .. "/ext", "p")
  for _, name in ipairs({
    "manifest.json",
    "page.html",
    "page.js",
    "host.mjs",
    "host.cmd",
    "host.sh",
  }) do
    vim.uv.fs_copyfile(here .. "/fixtures/sheet_native_host/" .. name, root .. "/ext/" .. name)
  end
  if not windows then
    vim.uv.fs_chmod(root .. "/ext/host.sh", tonumber("755", 8))
  end
  local store, calls = {}, {}
  local function fake(args)
    calls[#calls + 1] = table.concat(args, " ")
    local key = args[2]
    if args[1] == "query" then
      if store[key] then
        return {
          code = 0,
          stdout = "\r\n" .. key .. "\r\n    (Standard)    REG_SZ    " .. store[key] .. "\r\n",
        }
      end
      return { code = 1, stdout = "" }
    elseif args[1] == "delete" then
      store[key] = nil
      return { code = 0, stdout = "" }
    end
    return { code = 1, stdout = "" }
  end
  local hopts = { run = fake, windows = true }
  local key = nh.KEY .. "\\" .. NAME

  local host, err = nh.prepare(root, { name = NAME, path = "ext/host.cmd" }, hopts)
  ok(host ~= nil, "no key yet: ready: " .. tostring(err))
  ok(
    host.path:find("\\ext\\host.cmd$") ~= nil,
    "the host's path in Windows form: " .. tostring(host.path)
  )
  ok(
    vim.fn.isdirectory(host.dir) == 1 and host.dir:find(nh.MARK, 1, true),
    "a folder of the run, marked"
  )
  -- the runner registers it there; afterwards it goes, and the folder with it
  store[key] = host.dir:gsub("/", "\\") .. "\\" .. NAME .. ".json"
  nh.cleanup(host, hopts)
  eq(store[key], nil, "after the run the key of the run goes")
  eq(vim.fn.isdirectory(host.dir), 0, "... and its folder")

  store[key] = [[C:\Program Files\streamtap\host.json]]
  local none, why = nh.prepare(root, { name = NAME, path = "ext/host.cmd" }, hopts)
  eq(none, nil, "a host of that name from somebody else: no run")
  has(why, "registered for Chromium already", "... says so")
  has(why, [[C:\Program Files\streamtap\host.json]], "... and where it points")
  eq(store[key], [[C:\Program Files\streamtap\host.json]], "... and leaves it alone")
  -- a foreign key that came during the run is not this run's to remove
  local mine = assert(nh.prepare(root, { name = "other.name", path = "ext/host.cmd" }, hopts))
  store[nh.KEY .. "\\other.name"] = [[D:\elsewhere\x.json]]
  nh.cleanup(mine, hopts)
  eq(
    store[nh.KEY .. "\\other.name"],
    [[D:\elsewhere\x.json]],
    "cleanup keeps a key that is not of this run"
  )

  store[key] = [[C:\Temp\nvim.0\abc\7-testing-native-host\testing.nvim_spec.host.json]]
  host = nh.prepare(root, { name = NAME, path = "ext/host.cmd" }, hopts)
  ok(host ~= nil, "the leftover of a crashed run of this engine goes")
  eq(store[key], nil, "... its key is removed")
  nh.cleanup(host, hopts)

  -- env: filled in from the sheet's app as a step is; ${...} without an app is an error
  local base = { name = NAME, path = "x", dir = "d" }
  local filled = nh.with_env(
    base,
    { env = { STREAMTAP_APP_DIR = "${temp}/app", PLAIN = "p" } },
    { temp = "T" }
  )
  eq(
    filled and filled.env,
    { STREAMTAP_APP_DIR = "T/app", PLAIN = "p" },
    "env takes the app's ${temp}"
  )
  local _, enoapp = nh.with_env(base, { env = { A = "${temp}" } }, nil)
  has(enoapp, "needs the sheet's app", "${...} without an app")
  local _, eunknown = nh.with_env(base, { env = { A = "${nope}" } }, { temp = "T" })
  has(eunknown, "native_host.env.A", "an unknown ${...} names the variable")

  local missing, merr = nh.prepare(root, { name = NAME, path = "ext/nope.exe" }, hopts)
  eq(missing, nil, "a host that is not built: no run")
  has(merr, "build the host first", "... says so")

  -- the plan carries the host to the runner, and a refusal before the run is red, not a skip
  local s = assert(sheet.validate(sheet_of({})))
  local planned
  local res = browser.run(s, {
    root = root,
    node = "node",
    playwright_dir = root,
    native_host_opts = hopts,
    run = function(argv)
      planned = vim.json.decode(table.concat(vim.fn.readfile(argv[#argv]), "\n"))
      return { code = 0, stdout = '{"failures":[],"shots":[]}', stderr = "" }
    end,
  })
  eq(res.status, "pass", "a run with a host")
  eq(planned and planned.native_host and planned.native_host.name, NAME, "the plan names the host")
  eq(
    vim.fn.isdirectory(planned and planned.native_host.dir or ""),
    0,
    "the folder of the run is gone afterwards"
  )
  store[key] = [[C:\Program Files\streamtap\host.json]]
  res = browser.run(s, {
    root = root,
    node = "node",
    playwright_dir = root,
    native_host_opts = hopts,
    run = function()
      error("the runner must not start")
    end,
  })
  eq(res.status, "fail", "a foreign host refuses the run: red")
  has(res.failures[1], "registered for Chromium already", "... with the reason")
  store[key] = nil

  -- 3. the real Chromium, where node, playwright-core and Chromium exist ----------------------------------------------
  local real_steps = {
    { open = "chrome-extension://" .. ID .. "/page.html" },
    {
      wait = "document.title !== 'waiting'",
      timeout = 20000,
      note = "the page asked the host",
    },
    { expect = "document.title === 'reply host'" },
  }
  local real = assert(sheet.validate(sheet_of({ steps = real_steps })))
  -- the host's environment comes through Chromium: the host answers with it
  local real_env = assert(sheet.validate(sheet_of({
    native_host = { name = NAME, path = HOST, env = { SHEET_HOST_SAYS = "env" } },
    steps = {
      real_steps[1],
      real_steps[2],
      { expect = "document.title === 'reply env'" },
    },
  })))
  local pw_dir = browser.playwright_dir(repo)
  local got = sheet.run(real, { root = root, playwright_dir = pw_dir })
  if got.status == "skip" then
    print("n/a  " .. tostring(got.skipped) .. ": the real host is skipped")
  else
    ok(got.ok, "Chromium started the host of the run: " .. table.concat(got.failures, "; "))
    local with_env = sheet.run(real_env, { root = root, playwright_dir = pw_dir })
    ok(with_env.ok, "the host got native_host.env: " .. table.concat(with_env.failures, "; "))
    if windows then
      eq(nh.registered(NAME), nil, "no key of the run is left")
    end
    -- without the field there is no host: the page says so
    local without = vim.deepcopy(real)
    without.native_host = nil
    local red = sheet.run(without, { root = root, playwright_dir = pw_dir })
    ok(not red.ok, "without native_host the extension finds no host")
  end
  vim.fn.delete(root, "rf")
end
