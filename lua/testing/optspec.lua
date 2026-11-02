---@module 'testing.optspec'
---@brief A small table-driven option parser for the commands that have their own arguments (`surface`, ...).
---@description
--- A command lists its options as a table (`--name` -> what to do with it) and a function for what is not an
--- option; this module does the walking: `--name value`, `--name=value`, the "needs a value" error, the unknown
--- option error, a path that is given twice. The hand-written `while` / `elseif` chains it replaces repeated that
--- handling in every branch.
---
---   local specs = {
---     ["--json"] = { flag = function(a) a.format = "json" end },
---     ["--from"] = { value = function(a, v) a.from[#a.from + 1] = v end },
---   }
---   optspec.parse(argv, result, specs, function(a, arg) ... end)
---
--- A `value` handler returns an error text, or nothing. A flag ignores an `=value` that was attached to it.

local M = {}

---@class Testing.OptSpec
---@field flag? fun(a: table) The option takes no value.
---@field value? fun(a: table, v: string, name: string): string|nil The option takes the next argument (or `=value`); returns an error text.

---@alias Testing.OptSpecs table<string, Testing.OptSpec>

---Text with control characters made visible and cut: an argument can be anything.
---@param s string
---@return string
function M.show(s)
  return (s:sub(1, 60):gsub("%c", "?"))
end

---Walk `argv` along `specs`. What is no listed option goes to `positional(a, arg, index)`, which returns an error
---text or nothing; the default treats a word starting with `-` as an unknown option and anything else as an error.
---@param argv string[]
---@param a table The result, filled in.
---@param specs Testing.OptSpecs
---@param positional? fun(a: table, arg: string, index: integer): string|nil
---@return table|nil a
---@return string|nil err
function M.parse(argv, a, specs, positional)
  local i = 1
  while i <= #argv do
    local arg = argv[i]
    local name, inline = arg:match("^(%-%-[%w%-]+)=(.*)$")
    name = name or arg
    local spec = specs[name]
    if spec and spec.flag then
      spec.flag(a)
    elseif spec and spec.value then
      local v = inline
      if not v then
        i = i + 1
        v = argv[i]
        if v == nil then
          return nil, name .. " needs a value"
        end
      end
      local err = spec.value(a, v, name)
      if err then
        return nil, err
      end
    elseif positional then
      local err = positional(a, arg, i)
      if err then
        return nil, err
      end
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
      return nil, ("unknown option %s"):format(M.show(arg))
    else
      return nil, ("unexpected argument %s"):format(M.show(arg))
    end
    i = i + 1
  end
  return a
end

return M
