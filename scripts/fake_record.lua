-- scripts/fake_record.lua -- the stand-in that `testing.fake_redirect` starts on Windows instead of a `.cmd`:
-- `nvim -l fake_record.lua <dir> <name> <args...>`. It appends one record to `<dir>/calls.log` (each argument as a
-- JSON string, so `&`, `|`, `%`, quotes and line breaks arrive as given), prints the stand-in's stdout/stderr and
-- ends with its exit code (`<dir>/specs.json`, written by `testing.fake_programs.new`). Not a module: run by path.

local dir, name = arg[1], arg[2]
local function fail(msg)
  io.stderr:write("testing fake_record: ", msg, "\n")
  os.exit(127)
end
if not dir or not name then
  fail("usage: nvim -l fake_record.lua <dir> <name> <args...>")
end

local spec = {}
local sf = io.open(dir .. "/specs.json", "rb")
if sf then
  local ok, all = pcall(vim.json.decode, sf:read("*a"))
  sf:close()
  if ok and type(all) == "table" and type(all[name]) == "table" then
    spec = all[name]
  end
end

local lines = { "program=" .. name, "cwd=" .. (vim.uv.cwd() or "") }
for i = 3, #arg do
  lines[#lines + 1] = "argq=" .. vim.json.encode(arg[i])
end
if spec.stdin then
  local input = io.stdin:read("*a") or ""
  for l in input:gmatch("([^\n]*)\n?") do
    if l ~= "" then
      lines[#lines + 1] = "stdin=" .. l:gsub("\r$", "")
    end
  end
end
lines[#lines + 1] = "end"
local record = table.concat(lines, "\n") .. "\n"

-- one write per record, under the same lock folder as the POSIX stand-ins: an append of two processes at once is
-- not atomic on Windows (the C runtime seeks to the end, then writes); given up after about 20 s (a killed holder)
local lock = dir .. "/calls.log.lock"
local locked = false
for _ = 1, 2000 do
  if vim.uv.fs_mkdir(lock, 448) then
    locked = true
    break
  end
  vim.uv.sleep(10)
end
local written = false
for _ = 1, 200 do
  local fd = io.open(dir .. "/calls.log", "ab")
  if fd then
    fd:write(record)
    fd:close()
    written = true
    break
  end
  vim.uv.sleep(10)
end
if locked then
  vim.uv.fs_rmdir(lock)
end
if not written then
  fail("cannot append to " .. dir .. "/calls.log")
end

if type(spec.stdout) == "string" then
  io.stdout:write(spec.stdout)
end
if type(spec.stderr) == "string" then
  io.stderr:write(spec.stderr)
end
io.stdout:flush()
io.stderr:flush()
os.exit(tonumber(spec.exit_code) or 0)
