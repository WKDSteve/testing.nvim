-- TESTS/testing/machine_spec.lua -- `testing.machine`: on the workstation only the reading commands go on, everything
-- that builds or starts programs is refused (exit 2, nothing runs); a typo in the role is refused; the read-only token
-- of `ci remote` is the only one taken there. Each rule is red without its code.

---@diagnostic disable: need-check-nil, missing-fields, param-type-mismatch

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local machine = require("testing.machine")
  local cli = require("testing.cli")

  local function env_of(t)
    return function(name)
      return t[name]
    end
  end
  local WS = env_of({ NVIM_MACHINE_ROLE = "workstation" })

  -- ── the role ──
  eq(machine.role(env_of({})), "default", "no role: the private machine")
  eq(machine.role(env_of({ NVIM_MACHINE_ROLE = "default" })), "default", "default")
  eq(
    machine.role(env_of({ NVIM_MACHINE_ROLE = " Workstation " })),
    "workstation",
    "trimmed, case does not matter"
  )
  local role, problem = machine.role(env_of({ NVIM_MACHINE_ROLE = "workstaton" }))
  eq(role, nil, "a typo is no role")
  has(problem, "neither workstation nor default", "the typo is named")

  -- ── what is allowed there ──
  local allowed = {
    { "export", "--out", "x" },
    { "call", "fleet" },
    { "ci", "remote" },
    { "ci", "overview", "--no-remote" },
    { "ci", "verify", "--json" },
    { "lint" },
    { "--help" },
  }
  for _, argv in ipairs(allowed) do
    eq(machine.refusal(argv, WS), nil, "allowed on the workstation: " .. table.concat(argv, " "))
  end
  local refused = {
    { "run", "." },
    { "ci" },
    { "ci", "--profile=fast" },
    { "ci", "--repos" },
    { "ci", "verify" },
    { "ci", "trust", "x" },
    { "lint", "--fix" },
    { "sheets", "run", "--task", "a/b" },
    { "fast" },
    { "migrate", "apply" },
  }
  for _, argv in ipairs(refused) do
    local msg = machine.refusal(argv, WS)
    ok(msg ~= nil, "refused on the workstation: " .. table.concat(argv, " "))
    if msg then
      has(msg, "refused on the workstation", "the message says why: " .. table.concat(argv, " "))
    end
  end
  eq(machine.refusal({ "ci" }, env_of({})), nil, "the private machine runs everything")
  eq(
    machine.refusal(
      { "ci" },
      env_of({ NVIM_MACHINE_ROLE = "workstation", TESTING_ALLOW_WORKSTATION = "1" })
    ),
    nil,
    "TESTING_ALLOW_WORKSTATION=1 lifts it"
  )
  has(
    machine.refusal({ "export" }, env_of({ NVIM_MACHINE_ROLE = "wrkstn" })),
    "typo",
    "a typo refuses even a reading command"
  )
  has(machine.run_refusal("run", WS), "refused on the workstation", "the editor's run is refused")
  eq(machine.run_refusal("run", env_of({})), nil, "and allowed on the private machine")

  -- ── the command line: exit 2 and nothing started ──
  local errs = {}
  local started = false
  local code = cli.main({ "ci", "--profile=fast" }, {
    out = function() end,
    err = function(s)
      errs[#errs + 1] = s
    end,
    getenv = WS,
    inproc = {
      run = function()
        started = true
        error("must not run")
      end,
    },
  })
  eq(code, 2, "testing ci on the workstation: exit 2")
  eq(started, false, "nothing was started")
  has(table.concat(errs, "\n"), "refused on the workstation", "the message reaches stderr")

  -- ── the token of ci remote ──
  local remote = require("testing.ci.remote")
  local real_getenv = machine.getenv
  machine.getenv = WS
  local saved = vim.uv.os_getenv(remote.TOKEN_ENV)
  vim.uv.os_setenv(remote.TOKEN_ENV, "")
  local token, why = remote.deps.token()
  eq(token, nil, "workstation without the read-only token: none (gh auth token is not tried)")
  has(why, "read-only token", "and the reason says so")
  vim.uv.os_setenv(remote.TOKEN_ENV, "ro-token-1")
  token, why = remote.deps.token()
  eq(token, "ro-token-1", "the read-only token is taken")
  eq(why, "env:" .. remote.TOKEN_ENV, "its source")
  vim.uv.os_setenv(remote.TOKEN_ENV, saved or "")
  machine.getenv = real_getenv
end
