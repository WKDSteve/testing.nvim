-- TESTS/testing/child_winproc_foreign_cdef_spec.lua -- `testing.child.winproc` in a Neovim where another plugin declared
-- OpenProcess, GetProcessTimes, TerminateProcess, WaitForSingleObject and CloseHandle first, with types of its own (as
-- lib.nvim's cross.detached did before lib.nvim@e393884): LuaJIT's C declarations are one namespace per process, so
-- winproc must reach the real symbols under names of its own (asm redirection). A child Neovim makes the foreign
-- declarations come first, whatever this suite loaded before. Windows only (the module is nil elsewhere).
-- @cache-allow spawn
-- (it starts a child editor)
return function(H)
  local ok = H.ok
  if vim.fn.has("win32") == 0 then
    print("n/a  testing.child.winproc exists on Windows only")
    return
  end
  local here = debug.getinfo(1, "S").source:sub(2)
  local repo =
    vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(here, ":p")))))
  local probe = vim.fn.tempname() .. "_winproc_foreign.lua"
  local f = assert(io.open(probe, "wb"))
  f:write(table.concat({
    'local ffi = require("ffi")',
    'pcall(ffi.cdef, "struct spec_foreign_ft { uint32_t a; uint32_t b; };")',
    'pcall(ffi.cdef, "void *OpenProcess(uint32_t a, int i, uint32_t p);")',
    'pcall(ffi.cdef, "int GetProcessTimes(void *h, struct spec_foreign_ft *c, struct spec_foreign_ft *e,'
      .. ' struct spec_foreign_ft *k, struct spec_foreign_ft *u);")',
    'pcall(ffi.cdef, "int TerminateProcess(void *h, int code);")',
    'pcall(ffi.cdef, "int WaitForSingleObject(void *h, int ms);")',
    'pcall(ffi.cdef, "int CloseHandle(void *h);")',
    "vim.opt.rtp:prepend(" .. string.format("%q", repo) .. ")",
    'local w = require("testing.child.winproc").load()',
    "local p = w and w.open(vim.uv.os_getpid())",
    'io.stdout:write(tostring(w ~= nil), " ", tostring(p and p.created), "\\n")',
    "if p then w.close(p) end",
  }, "\n"))
  f:close()
  local res = vim
    .system(
      { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", probe },
      { text = true }
    )
    :wait(30000)
  vim.fn.delete(probe)
  local loaded, created = (res.stdout or ""):match("(%S+) (%S+)")
  local shown = vim.inspect({ code = res.code, stdout = res.stdout, stderr = res.stderr })
  ok(
    loaded == "true",
    "winproc loads although the functions were declared elsewhere first: " .. shown
  )
  ok(
    created ~= nil and created ~= "nil",
    "and open() reads the creation time of a process: " .. shown
  )
end
