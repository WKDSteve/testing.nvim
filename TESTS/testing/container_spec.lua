-- TESTS/testing/container_spec.lua -- testing.container (Linux checks in a container): the argument vectors with a
-- fake runner and, where the engine and the image exist, one real container.
-- @cache-allow time processes

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local container = require("testing.container")

  -- 1. the argument vectors, with a fake runner ---------------------------------------------------------------------
  eq(
    container.argv({ "nvim", "--headless" }, {
      engine = "podman",
      image = "img:1",
      mounts = { ["/b"] = "/y", ["/a"] = "/x" },
      env = { Z = "1", A = "2" },
    }),
    {
      "podman",
      "run",
      "--rm",
      "--network",
      "none",
      "-v",
      "/a:/x:ro",
      "-v",
      "/b:/y:ro",
      "-e",
      "A=2",
      "-e",
      "Z=1",
      "img:1",
      "nvim",
      "--headless",
    },
    "no network, mounts read-only and sorted, environment sorted, then image and command"
  )

  local calls = {}
  local function fake(code, stderr)
    return function(argv)
      calls[#calls + 1] = argv
      return { code = code, stdout = "", stderr = stderr or "" }
    end
  end
  local good, name = container.available({ run = fake(0), image = "img:1" })
  ok(good and name == "img:1", "available when the image exists")
  eq(calls[1], { "podman", "image", "exists", "img:1" }, "the probe asks the engine for the image")
  calls = {}
  container.available({ run = fake(0), image = "img:1", engine = "docker" })
  eq(
    calls[1],
    { "docker", "image", "inspect", "img:1" },
    "docker asks with `image inspect`, it has no `image exists`"
  )
  local missing, reason = container.available({ run = fake(1), image = "img:1" })
  ok(
    not missing and reason:find("not built", 1, true) ~= nil,
    "exit 1 without a message = image not built"
  )
  local down, why = container.available({ run = fake(125, "cannot connect") })
  ok(not down and why:find("machine", 1, true) ~= nil, "any other failure = engine not usable")
  local none, absent = container.available({ run = fake(127) })
  ok(not none and absent:find("not installed", 1, true) ~= nil, "exit 127 = engine not installed")

  -- 2. a real container, where the image exists ---------------------------------------------------------------------
  local real_ok, real_reason = container.available({})
  if not real_ok then
    print("n/a  " .. real_reason .. ": the real container is skipped")
    return
  end
  local res = container.run({ "sh", "-c", "echo hello; echo oops >&2; exit 3" })
  eq(res.code, 3, "the exit code of the command comes back")
  ok(
    res.stdout:find("hello", 1, true) ~= nil and res.stderr:find("oops", 1, true) ~= nil,
    "both streams come back"
  )
  local net = container.run({ "sh", "-c", "wget -q -T 3 -O /dev/null http://example.com" })
  ok(net.code ~= 0, "the container has no network")
end
