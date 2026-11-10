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
      on._strip_jsonc('{ // a comment\n "image": "a/b:1", /* more */ "x": "//not", }')
    ),
    { image = "a/b:1", x = "//not" },
    "devcontainer.json: comments and a trailing comma"
  )

  -- ---------------------------------------------------------------- a stand-in engine
  local root =
    project("on", { ["TESTS/a_spec.lua"] = 'return function(H) H.ok(true, "fine") end\n' })
  local repo = vim.fs.basename(root)
  local calls = {}
  ---@param o { image_exists?: integer, id?: string, verdict?: string, exit?: integer }
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
          return { code = o.exit or 1, stdout = "inner output\n", stderr = "" }
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
    has(argv, root .. ":/repo:ro", "the repository read-only")
    has(argv, ":/deps/lib.nvim:ro", "lib.nvim read-only")
    has(argv, ":/out:rw", "one writable output folder")
    has(argv, "TESTING_CI_TARGET=linux", "the inner run knows its target")
    has(argv, "LIB_NVIM_DIR=/deps/lib.nvim", "and where lib.nvim is")
    has(argv, "localhost/testing-ci:1", "the image of containers/ci")
    has(
      argv,
      "ci --root=/repo --state-dir=/out/state --json=/out/ci.json",
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

  -- the falsification on a real engine: a spec that is red only on Linux is red with --on=linux
  local available = require("testing.container").available({ image = on.DEFAULT_IMAGE })
  if not available then
    print(
      "ci_on_spec: podman or the image localhost/testing-ci:1 is not there: the real container run is not tried"
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
