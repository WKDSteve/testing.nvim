-- TESTS/testing/suite_lock_spec.lua -- scripts/suite-lock.sh: a second full suite in the same checkout warns (two at
-- once make the process specs time out), a lock of a dead pid or an old one is taken over silently, the holder
-- releases its own lock and nobody else's, and the warning never stops a run.

return function(H)
  local ok = H.ok
  local this = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this)))
  local lib = repo .. "/scripts/suite-lock.sh"
  local bash = require("lib.nvim.cross.bash").find() or ""
  if bash == "" then
    ok(true, "no bash here: nothing to run")
    return
  end

  local base = vim.fs.normalize(vim.fn.tempname()) .. "-suitelock"
  vim.fn.mkdir(base, "p")
  local state = base .. "/state"

  -- The probe: `$1` the library, `$2` the state directory, `$3` the age of the planted lock in seconds (or "none"),
  -- `$4` "live" (the planted holder is a running process) or "dead". Prints what the second suite sees.
  local probe = [[
set -u
. "$1"
state="$2"; age="$3"; kind="$4"
mkdir -p "$state"
key=$(printf '%s' /some/checkout | cksum | cut -d' ' -f1)
lock="$state/suite-lock-$key"
rm -f "$lock"
if [ "$kind" = live ] || [ "$kind" = junk ]; then sleep 30 & hp=$!; else ( : ) & hp=$!; wait "$hp"; fi
if [ "$kind" = junk ]; then printf '%s junk
' "$hp" >"$lock"; elif [ "$age" != none ]; then printf '%s %s\n' "$hp" "$(( $(date +%s) - age ))" >"$lock"; fi
suite_lock_acquire "$state" /some/checkout
echo "owned=$SUITE_LOCK_OWNED"
suite_lock_release
if [ -f "$lock" ]; then echo kept; else echo removed; fi
kill "$hp" 2>/dev/null
]]

  ---@param age string
  ---@param kind string
  ---@return string
  local function run(age, kind)
    local r = vim
      .system({ bash, "-c", probe, "sh", lib, state, age, kind }, { text = true })
      :wait(60000)
    return (r.stdout or "") .. (r.stderr or "")
  end

  local out = run("none", "dead")
  ok(
    out:find("owned=1", 1, true) and not out:find("warning", 1, true),
    "no lock: owned, silent: " .. out
  )
  ok(out:find("removed", 1, true) ~= nil, "and the release removes it: " .. out)

  out = run("5", "live")
  ok(
    out:find("another full suite is running", 1, true) ~= nil,
    "a live holder is warned about: " .. out
  )
  ok(out:find("owned=0", 1, true) ~= nil, "the second suite does not own the lock: " .. out)
  ok(out:find("kept", 1, true) ~= nil, "and its release leaves the holder's lock alone: " .. out)

  out = run("5", "dead")
  ok(
    out:find("owned=1", 1, true) and not out:find("warning", 1, true),
    "a dead holder is taken over silently: " .. out
  )

  out = run("90000", "live")
  ok(
    out:find("owned=1", 1, true) and not out:find("warning", 1, true),
    "a lock older than 6 h is taken over: " .. out
  )

  out = run("5", "junk")
  ok(
    out:find("owned=1", 1, true) and not out:find("warning", 1, true),
    "a lock file with junk in it is taken over, not a crash under set -u: " .. out
  )

  vim.fn.delete(base, "rf")
end
