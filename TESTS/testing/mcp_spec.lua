-- TESTS/testing/mcp_spec.lua -- `testing.mcp`: the documents of `testing-export/1` as read-only MCP tools, through the
-- JSON-RPC dispatch of lib.nvim.mcp.server (no process, no network).

---@diagnostic disable: need-check-nil

return function(H)
  local ok, eq = H.ok, H.eq
  -- a repositories root that exists: one that does not would refuse every call before the call itself is judged
  local repos_root = vim.fn.tempname()
  vim.fn.mkdir(repos_root, "p")
  local server = require("testing.mcp").server({ repos_root = repos_root })

  local function send(msg)
    return vim.json.decode(server:dispatch(vim.json.encode(msg)))
  end

  local res = send({ jsonrpc = "2.0", id = 1, method = "tools/list" })
  local names = {}
  for _, t in ipairs(res.result.tools) do
    names[#names + 1] = t.name
  end
  eq(
    table.concat(names, ","),
    "testing_findings,testing_fleet,testing_hello,testing_repo",
    "four read tools, nothing that runs"
  )

  -- one call through the whole path: JSON-RPC in, the document of `testing call hello` out
  res = send({
    jsonrpc = "2.0",
    id = 2,
    method = "tools/call",
    params = { name = "testing_hello", arguments = vim.empty_dict() },
  })
  ok(not res.result.isError, "testing_hello answers")
  local doc = vim.json.decode(res.result.content[1].text)
  ok(type(doc) == "table" and doc.kind ~= nil, "the answer is a document of the contract")

  -- a refusal of `testing call` (exit 2) is an error result with its message
  res = send({
    jsonrpc = "2.0",
    id = 3,
    method = "tools/call",
    params = { name = "testing_repo", arguments = { dir = vim.fn.tempname() .. "/missing" } },
  })
  ok(res.result.isError, "a directory that is not there is an error result")
  ok(
    res.result.content[1].text:find("not a directory", 1, true),
    "with the message of testing call"
  )

  -- a `dir` that looks like an option stays a directory: `--remote` must not switch on the CI adapter (network,
  -- token), and the call of the server's own repository must not answer in its place
  for _, sneaky in ipairs({ "--remote", "--state-dir=" .. vim.fn.tempname() }) do
    res = send({
      jsonrpc = "2.0",
      id = 5,
      method = "tools/call",
      params = { name = "testing_repo", arguments = { dir = sneaky } },
    })
    ok(res.result.isError, "dir " .. sneaky .. " is not read as an option")
    ok(
      res.result.content[1].text:find("dir must not start with '-'", 1, true),
      "... it is refused before testing call: " .. res.result.content[1].text
    )
  end
  res = send({
    jsonrpc = "2.0",
    id = 6,
    method = "tools/call",
    params = { name = "testing_repo", arguments = { dir = 7 } },
  })
  ok(res.result.isError, "a dir that is no text is refused")

  res = send({
    jsonrpc = "2.0",
    id = 4,
    method = "tools/call",
    params = { name = "testing_findings", arguments = { fp = "../x" } },
  })
  ok(res.result.isError, "an fp that is no hex is refused before testing call")
  ok(res.result.content[1].text:find("fp must be hex", 1, true), "... with its own message")
  vim.fn.delete(repos_root, "rf")
end
