-- TESTS/testing/ci_on_spec.lua -- `testing ci --on=host,linux,devcontainer` (testing.ci.on): the targets one after the
-- other, a table with a column per target, the worst exit; a container run with the repository and every dependency
-- READ-ONLY, one writable output folder, no network unless `ci.container.network = true`, the name
-- `testing-ci-<repo>-<target>`; its document comes back with the target, the image id and this checkout's tree, kept
-- as `ci.<target>.json` and `ci-<profile>.<target>.json`, and `testing ci verify --on=<target>` reads that proof;
-- without the engine or the image exit 3 with what to do; a devcontainer's image from devcontainer.json (comments
-- allowed). The engine is a stand-in here; where Podman and the image are there, a spec that is red only on Linux is
-- red with --on=linux (the falsification), whatever it is on this host.
-- @cache-allow spawn
-- (it starts git for the fixture repositories and editors for the host run; where installed, podman)
---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields
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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local on = require("testing.ci.on")
  local cli = require("testing.cli")
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-on"
  local state_dir = tmp .. "/state"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local t = f:read("*a")
    f:close()
    return t
  end
  local function git(root, ...)
    local res = vim
      .system({ "git", "-c", "core.autocrlf=false", ... }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
    return vim.trim(res.stdout or "")
  end
  local function project(name, files)
    local root = tmp .. "/" .. name
    write(
      root .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, ci = { profiles = { full = { 'suite' } } } }\n"
    )
    write(root .. "/lua/proj/init.lua", "return {}\n")
    for rel, text in pairs(files or {}) do
      write(root .. "/" .. rel, text)
    end
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end

  -- ---------------------------------------------------------------- the targets
  eq({ on.parse("host,linux,host") }, { { "host", "linux" } }, "targets in order, once each")
  local none, bad = on.parse("linux,mars")
  eq(none, nil, "an unknown target")
  has(bad, "unknown target mars", "... is named")
  eq(on.container_name("My.Plugin", "linux"), "testing-ci-my-plugin-linux", "the container name")
  eq(
    on._inner_options({
      "--on=host,linux",
      "--profile=full",
      "--json",
      "x.json",
      "--root=r",
      "--",
      "--jobs",
      "2",
    }),
    { "--profile=full", "--", "--jobs", "2" },
    "the inner run gets the options without the places of this machine"
  )
  eq(
    vim.json.decode(
      on._strip_jsonc('{ // a comment\n "image": "a/b:1", /* more */ "x": "//not, }", }')
    ),
    { image = "a/b:1", x = "//not, }" },
    "devcontainer.json: comments and a trailing comma, never inside a string"
  )

  -- ---------------------------------------------------------------- a stand-in engine
  local root =
    project("on", { ["TESTS/a_spec.lua"] = 'return function(H) H.ok(true, "fine") end\n' })
  local repo = vim.fs.basename(root)
  local calls = {}
  ---@param o { image_exists?: integer, id?: string, verdict?: string, exit?: integer, on_run?: function, run_code?: integer, run_stderr?: string }
  local function engine(o)
    calls = {}
    return {
      engine = "podman",
      run = function(argv)
        calls[#calls + 1] = argv
        if argv[2] == "image" and argv[3] == "exists" then
          return { code = o.image_exists or 0, stdout = "", stderr = "" }
        elseif argv[2] == "image" and argv[3] == "inspect" then
          return { code = 0, stdout = (o.id or "sha256:aaaa") .. "\n", stderr = "" }
        elseif argv[2] == "rm" then
          return { code = 0, stdout = "", stderr = "" }
        elseif argv[2] == "run" then
          if o.on_run then
            o.on_run(argv)
          end
          if o.run_code then
            return { code = o.run_code, stdout = "", stderr = o.run_stderr or "" }
          end
          local out_dir
          for i, a in ipairs(argv) do
            local host = argv[i - 1] == "-v" and a:match("^(.*):/out:rw$")
            out_dir = out_dir or host
          end
          write(
            out_dir .. "/ci.json",
            vim.json.encode({
              schema = "testing-ci/1",
              repo = "repo",
              profile = "full",
              partial = false,
              verdict = o.verdict or "red",
              exit = o.exit or 1,
              time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
              -- the inner run resolves the same pipeline: its hash
              pipeline_sha = vim.fn.sha256(
                require("lib.nvim.json.canonical").encode(
                  require("testing.ci.schema").load(root).digest_input
                )
              ),
              os = "linux",
              steps = { { name = "suite", state = o.verdict == "green" and "green" or "red" } },
            })
          )
          return { code = o.exit or 1, stdout = "inner output\nTESTING_CI_OK\n", stderr = "" }
        end
        return { code = 1, stdout = "", stderr = "unexpected" }
      end,
    }
  end
  local function run(container, ...)
    local out, err = {}, {}
    local code = cli.main(vim.list_extend({ "ci", "--root=" .. root }, { ... }), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      color = false,
      container = container,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  local function run_argv()
    for _, c in ipairs(calls) do
      if c[2] == "run" then
        return c
      end
    end
    return {}
  end

  do
    local res = run(engine({ verdict = "red", exit = 1 }), "--on=host,linux", "--no-agent")
    eq(res.code, 1, "the worst target decides: red in the container (" .. res.err .. ")")
    has(res.out, "== on host", "the host ran")
    has(res.out, "[linux] inner output", "the container's output is shown, marked")
    has(res.out, "step     host           linux", "a column per target")
    has(res.out, "suite    green          red", "a row per step")
    has(res.out, "verdict  green          red", "and the verdicts")
    ok(not res.out:find("TESTING_CI_OK", 1, true), "no sentinel when one target is not green")
    local argv = table.concat(run_argv(), " ")
    has(argv, "--network none", "no network by default")
    has(argv, "--name " .. on.container_name(repo, "linux"), "the container's name")
    has(argv, root .. ":/src/repo:ro", "the repository read-only")
    has(argv, ":/src/deps/lib.nvim:ro", "lib.nvim read-only")
    has(argv, ":/out:rw", "one writable output folder")
    has(argv, "TESTING_CI_TARGET=linux", "the inner run knows its target")
    has(argv, "LIB_NVIM_DIR=/tmp/ci/deps/lib.nvim", "and where lib.nvim is: its copy")
    -- the run works on a copy in the container (a lookup through the mount of a Windows drive costs milliseconds)
    has(argv, "/src/repo /tmp/ci/repo", "the repository is copied before the run")
    -- with what every image has: the darwin-like one (Chimera) has no tar, and a copy that fails ends the container
    ok(not on.COPY_SCRIPT:find("tar", 1, true), "the copy needs no tar")
    has(on.COPY_SCRIPT, "exit 3", "a failed copy is infrastructure")
    has(argv, "/src/deps/lib.nvim /tmp/ci/deps/lib.nvim", "and lib.nvim")
    has(argv, "localhost/testing-ci:2", "the image of containers/ci")
    -- not root, as on a hosted runner: the user of this machine is the user in there (the output folder is its own)
    has(argv, "--userns keep-id", "the run is not root")
    ok(not argv:find("--user ", 1, true), "no --user that would make it root: " .. argv)
    has(
      argv,
      "ci --root=/tmp/ci/repo --state-dir=/out/state --json=/out/ci.json",
      "the same pipeline again in there"
    )
    local dir = require("testing.state").dir(root, { state_dir = state_dir })
    local kept = vim.json.decode(read(dir .. "/ci.linux.json") or "{}")
    eq(
      { kept.target, kept.image },
      { "linux", "sha256:aaaa" },
      "the document comes back with target and image id"
    )
    eq(kept.tree, git(root, "rev-parse", "HEAD^{tree}"), "and this checkout's tree")
    ok(
      read(dir .. "/ci-full.linux.json") ~= nil,
      "a complete run is the profile's proof of the target"
    )
    local host = vim.json.decode(read(dir .. "/ci.json") or "{}")
    eq(
      host.targets and host.targets.linux and host.targets.linux.verdict,
      "red",
      "the host's document carries it"
    )
  end

  do
    write(
      root .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, ci = { profiles = { full = { 'suite' } }, container = { network = true, image = 'example.org/my-ci:2' } } }\n"
    )
    git(root, "commit", "-q", "-am", "network")
    local res = run(engine({ verdict = "green", exit = 0, id = "sha256:bbbb" }), "--on=linux")
    eq(res.code, 0, "a green container run (" .. res.err .. ")")
    local argv = table.concat(run_argv(), " ")
    ok(not argv:find("--network none", 1, true), "ci.container.network = true: the network")
    has(argv, "example.org/my-ci:2", "ci.container.image replaces the image")
    has(res.out, "TESTING_CI_OK", "every target green: the sentinel")

    -- verify --on=linux: the proof of the target, with the image id of now
    local function verify(container)
      local out = {}
      local code = cli.main({ "ci", "verify", "--root=" .. root, "--on=linux" }, {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          out[#out + 1] = s
        end,
        state_dir = state_dir,
        color = false,
        container = container,
      })
      return code, table.concat(out, "\n")
    end
    local code, text = verify(engine({ id = "sha256:bbbb" }))
    eq(code, 0, "verify --on=linux: verified (" .. text .. ")")
    code, text = verify(engine({ id = "sha256:cccc" }))
    eq(code, 1, "another image: not verified")
    has(text, "image: proof in sha256:bbbb, now sha256:cccc", "... and it says so")
    local hcode = verify(nil)
    ok(hcode ~= nil, "verify without --on reads the host's proof, not the target's")
  end

  -- without the engine or the image: exit 3 and what to do; the targets before it have run
  do
    local res = run(engine({ image_exists = 1 }), "--on=linux")
    eq(res.code, 3, "no image: infrastructure")
    has(res.err, "is not built", "the reason")
    local res2 = run({
      engine = "podman",
      -- what the runner of testing.container answers when the program cannot be started
      run = function()
        return { code = 127, stdout = "", stderr = "ENOENT" }
      end,
    }, "--on=linux")
    eq(res2.code, 3, "no engine: infrastructure")
    has(res2.err, "is not installed", "the reason")
  end

  -- darwin-like: the image of containers/darwin-like, and how to build it when it is missing
  do
    -- what the image builds from the network is checked against a sum the builder names (fail closed)
    local here = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
    local cf = assert(io.open(here .. "/containers/darwin-like/Containerfile", "rb"))
    local file = cf:read("*a")
    cf:close()
    ok(
      file:find("ARG BASH_SHA256=" .. string.rep("%x", 64) .. "\n") ~= nil,
      "the sum of the bash sources is fixed"
    )
    for from in file:gmatch("\nFROM (%S+)") do
      ok(from:find("@sha256:%x+$") ~= nil, "a base image is pinned by digest: " .. from)
    end
    -- a linked worktree as the root: refused before a container starts (git could not follow its .git file in there)
    local wt = vim.fs.normalize(vim.fn.tempname()) .. "-linked"
    vim.fn.mkdir(wt, "p")
    local gf = assert(io.open(wt .. "/.git", "wb"))
    gf:write("gitdir: C:/somewhere/.git/worktrees/x\n")
    gf:close()
    local wcode, _, wproblems = on.run_target("darwin-like", {}, wt, {}, { container = {} })
    eq(wcode, 3, "a linked worktree: infrastructure")
    has(wproblems[1], "is a linked worktree", "and why")
    vim.fn.delete(wt, "rf")
    ok(file:find("sha256sum -c -", 1, true) ~= nil, "the download is checked against it")
    ok(
      not file:find("| tar", 1, true),
      "nothing from the network is unpacked straight from the pipe"
    )
    eq({ on.parse("darwin-like,linux") }, { { "darwin-like", "linux" } }, "darwin-like is a target")
    local res = run(engine({ image_exists = 1 }), "--on=darwin-like")
    eq(res.code, 3, "darwin-like without its image: infrastructure")
    has(
      res.err,
      "podman build --tag localhost/testing-darwin-like:2 containers/darwin-like",
      "the build line of its own Containerfile"
    )
    ok(not res.err:find("ci.container.image", 1, true), "ci.container.image is the linux target's")
    local res2 = run(engine({ verdict = "green", exit = 0 }), "--on=darwin-like")
    eq(res2.code, 0, "the darwin-like target (" .. res2.err .. ")")
    has(
      table.concat(run_argv(), " "),
      "localhost/testing-darwin-like:2",
      "runs in the darwin-like image"
    )
    ok(
      vim.tbl_contains(run_argv(), "--init"),
      "with an init as PID 1 that reaps orphans: " .. table.concat(run_argv(), " ")
    )
    has(res2.out, "darwin-like", "the report names the target")
  end

  -- linux: what containers/ci builds from the network is checked against a sum fixed in the file (fail closed)
  do
    local here = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
    local cf = assert(io.open(here .. "/containers/ci/Containerfile", "rb"))
    local file = cf:read("*a")
    cf:close()
    local downloads = 0
    for _ in file:gmatch("curl %-fsSLo ") do
      downloads = downloads + 1
    end
    eq(downloads, 3, "nvim, stylua and luacheck are downloaded to files")
    for _, tool in ipairs({ "NVIM", "STYLUA", "LUACHECK" }) do
      ok(
        file:find("ARG " .. tool .. "_SHA256=" .. string.rep("%x", 64) .. "\n") ~= nil,
        "the sum of " .. tool .. " is fixed"
      )
      ok(file:find('"${' .. tool .. '_SHA256}"', 1, true) ~= nil, "and checked: " .. tool)
    end
    eq(
      file:match("ARG LUACHECK_SHA256=(%x+)"),
      require("testing.ci.workflow").SHA256.luacheck,
      "luacheck: the sum the hosted legs check"
    )
    ok(file:find("sha256sum -c -", 1, true) ~= nil, "the downloads are checked")
    ok(
      file:find("sha256sum -c -", 1, true) < file:find("tar -x", 1, true)
        and file:find("sha256sum -c -", 1, true) < file:find("unzip ", 1, true),
      "before anything is unpacked"
    )
    ok(not file:find("| tar", 1, true), "nothing is unpacked straight from the pipe")
    ok(not file:find("luarocks", 1, true), "no unpinned rocks")
    local froms = 0
    for from in file:gmatch("\nFROM (%S+)") do
      froms = froms + 1
      ok(from:find("@sha256:%x+$") ~= nil, "the base image is pinned by digest: " .. from)
    end
    eq(froms, 1, "one base image")
  end

  -- a devcontainer: its image, from a devcontainer.json with comments
  do
    local res = run(engine({ verdict = "green", exit = 0 }), "--on=devcontainer")
    eq(res.code, 2, "no devcontainer.json: a usage problem of the repository")
    has(res.err, "no .devcontainer/devcontainer.json", "... named")
    write(
      root .. "/.devcontainer/devcontainer.json",
      '{\n  // the image\n  "image": "example.org/dev:3",\n}\n'
    )
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "devcontainer")
    local res2 = run(engine({ verdict = "green", exit = 0 }), "--on=devcontainer")
    eq(res2.code, 0, "the devcontainer target (" .. res2.err .. ")")
    has(table.concat(run_argv(), " "), "example.org/dev:3", "runs in the devcontainer's image")
  end

  -- the review of 9ba2442: what a container run may claim, and what it must not do
  do
    local dir = require("testing.state").dir(root, { state_dir = state_dir })
    local name = on.container_name(repo, "linux")
    -- the inner sentinel is not this run's, the engine ends the container itself, a running one is never forced away
    local res = run(engine({ verdict = "red", exit = 1 }), "--on=linux")
    ok(
      not res.out:find("[linux] TESTING_CI_OK", 1, true),
      "the inner sentinel is not shown as this run's"
    )
    has(
      table.concat(run_argv(), " "),
      "--timeout ",
      "the engine ends the container after the deadline"
    )
    for _, c in ipairs(calls) do
      ok(
        not (c[2] == "rm" and vim.tbl_contains(c, "--force")),
        "a container of this name is never forced away first"
      )
    end

    -- the checkout changes while the container runs (another session's edit): no proof for it
    os.remove(dir .. "/ci-full.linux.json")
    local changed = run(
      engine({
        verdict = "green",
        exit = 0,
        on_run = function()
          write(root .. "/late.txt", "written while the container ran\n")
        end,
      }),
      "--on=linux"
    )
    local kept = vim.json.decode(read(dir .. "/ci.linux.json") or "{}")
    eq(
      { kept.tree_changed, kept.verdict },
      { true, "green-partial" },
      "the document says the tree changed"
    )
    eq(read(dir .. "/ci-full.linux.json"), nil, "and it is no proof")
    ok(not changed.out:find("TESTING_CI_OK", 1, true), "no sentinel for a partial run")
    os.remove(root .. "/late.txt")

    -- a usage error of `testing ci` is refused before any target runs (never an old document as this run's)
    local refused = run(engine({ verdict = "green", exit = 0 }), "--on=host,linux", "--rev=HEAD")
    eq(refused.code, 2, "--rev without --snapshot: a usage error")
    eq(#calls, 0, "and no container was asked for")

    -- the client gave up (its deadline): the container is ours and goes
    local timed = run(engine({ run_code = 124 }), "--on=linux")
    eq(timed.code, 3, "no document: infrastructure")
    local forced = false
    for _, c in ipairs(calls) do
      forced = forced
        or (c[2] == "rm" and vim.tbl_contains(c, "--force") and vim.tbl_contains(c, name))
    end
    ok(forced, "after the client's deadline the container is removed")

    -- another run of this repository holds the name: said, not stopped
    local busy = run(
      engine({
        run_code = 125,
        run_stderr = 'the container name "' .. name .. '" is already in use',
      }),
      "--on=linux"
    )
    eq(busy.code, 3, "a busy name: infrastructure")
    has(busy.err, "another run of " .. repo, "... says who has it")

    -- verify reads: a devcontainer image that is not built is not built by verify
    write(
      root .. "/.devcontainer/devcontainer.json",
      '{ "build": { "dockerfile": "Dockerfile" } }\n'
    )
    write(root .. "/.devcontainer/Dockerfile", "FROM scratch\n")
    local vcalls = engine({ image_exists = 1 })
    local vcode = cli.main({ "ci", "verify", "--root=" .. root, "--on=devcontainer" }, {
      out = function() end,
      err = function() end,
      state_dir = state_dir,
      color = false,
      container = vcalls,
    })
    eq(vcode, 1, "verify --on=devcontainer without its image: not proven")
    for _, c in ipairs(calls) do
      ok(c[2] ~= "build", "and nothing was built")
    end
    -- an image name from devcontainer.json is a name, never an option of the engine
    write(root .. "/.devcontainer/devcontainer.json", '{ "image": "--privileged" }\n')
    local evil = run(engine({ verdict = "green", exit = 0 }), "--on=devcontainer")
    eq(evil.code, 2, "an image that is not an image name: refused")
    vim.fn.delete(root .. "/.devcontainer", "rf")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "no devcontainer")
  end

  -- lib.nvim checking itself: the dependency IS the repository, the mount of the repository stays
  do
    local lib = project("libself", { ["lua/lib/nvim/init.lua"] = "return {}\n" })
    local saved = vim.env.LIB_NVIM_DIR
    vim.env.LIB_NVIM_DIR = lib
    local was = root
    root = lib
    local res = run(engine({ verdict = "green", exit = 0 }), "--on=linux")
    root = was
    vim.env.LIB_NVIM_DIR = saved
    eq(res.code, 0, "the run of lib.nvim itself (" .. res.err .. ")")
    local argv = table.concat(run_argv(), " ")
    has(argv, lib .. ":/src/repo:ro", "the repository is mounted")
    has(argv, "LIB_NVIM_DIR=/tmp/ci/repo", "and lib.nvim is the repository")
    ok(not argv:find(":/src/deps/lib.nvim:ro", 1, true), "no second mount of it")
  end

  -- the network is part of the pipeline's hash where it is set (a proof without it is not one with it)
  do
    local schema = require("testing.ci.schema")
    local a = schema.resolve({ profiles = { full = { "suite" } } })
    local b = schema.resolve({ profiles = { full = { "suite" } }, container = { network = true } })
    ok(a.digest_input.container == nil, "without ci.container the hash is the old one")
    eq(b.digest_input.container, { network = true }, "with it, it is part of the hash")
  end

  -- the falsification on a real engine: a spec that is red only on Linux is red with --on=linux
  local available = require("testing.container").available({ image = on.DEFAULT_IMAGE })
  if not available then
    print(
      "ci_on_spec: podman or the image localhost/testing-ci:2 is not there: the real container run is not tried"
    )
  else
    local linux = project("only-linux", {
      ["TESTS/os_spec.lua"] = 'return function(H) H.ok(vim.fn.has("linux") == 0, "this is not Linux") end\n',
    })
    root = linux
    local res = run(nil, "--on=host,linux", "--no-agent")
    local host_red = vim.fn.has("linux") == 1
    has(
      res.out,
      ("verdict  %s"):format(host_red and "red  " or "green"),
      "the host: as this system is"
    )
    has(res.out, "red", "Linux: red")
    eq(res.code, 1, "the run is red (" .. res.err .. ")")
    local kept = vim.json.decode(
      read(require("testing.state").dir(linux, { state_dir = state_dir }) .. "/ci.linux.json")
        or "{}"
    )
    eq(
      { kept.target, kept.verdict, kept.os },
      { "linux", "red", "linux" },
      "the container ran Linux and found it red"
    )
  end
  vim.fn.delete(tmp, "rf")
end
