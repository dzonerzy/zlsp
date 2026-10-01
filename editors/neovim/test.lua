-- The tiny server in a real Neovim (0.11+), set up as the README says, every
-- feature asked through Neovim's own LSP client.
--
--   ZLSP_PYTHON=$(which python) nvim --headless -u NONE -l editors/neovim/test.lua
--
-- Prints "ok - ..." / "not ok - ..." per check; exits 1 if any failed.

local python = os.getenv("ZLSP_PYTHON") or "python3"
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local server = vim.fn.fnamemodify(here .. "/../../examples/tiny/tiny.py", ":p")

-- The workspace
local ws = vim.fn.tempname()
vim.fn.mkdir(ws, "p")
local function write(name, text)
  local f = assert(io.open(ws .. "/" .. name, "w"))
  f:write(text)
  f:close()
end
write("main.tiny", table.concat({
  "# A program with mistakes",
  "fn fib(n) {",
  "    if n < 2 { return n; }",
  "    return fib(n - 1) + fib(n - 2);",
  "}",
  "",
  "let total = 0;",
  "let i = 0;",
  "while i < 10 {",
  "    total = total + fib(i);",
  "    i = i + 1;",
  "}",
  "print(total, missing);",
  "break;",
  "",
}, "\n"))
write("broken.tiny", "let y = ;\nprint(y);\n")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok - " .. name)
  else
    failures = failures + 1
    print("not ok - " .. name .. (detail and (": " .. vim.inspect(detail)) or ""))
  end
end

-- (-u NONE leaves filetype detection off; any real config has it on)
vim.cmd("filetype on")

-- The setup from the README
vim.filetype.add({ extension = { tiny = "tiny" } })
vim.lsp.config("tiny", {
  cmd = { python, server },
  filetypes = { "tiny" },
  root_dir = ws,
})
vim.lsp.enable("tiny")

vim.cmd.edit(ws .. "/main.tiny")
local buf = vim.api.nvim_get_current_buf()
check("the filetype", vim.bo[buf].filetype == "tiny")
check("the server attaches", vim.wait(20000, function()
  return #vim.lsp.get_clients({ bufnr = buf }) > 0
end))
local client = vim.lsp.get_clients({ bufnr = buf })[1]
if not client then
  os.exit(1)
end
local uri = vim.uri_from_bufnr(buf)

local function diag_codes(b)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(b)) do
    table.insert(out, d.lnum .. ":" .. tostring(d.code))
  end
  table.sort(out)
  return table.concat(out, ",")
end

local function at(line, character)
  return { textDocument = { uri = uri }, position = { line = line, character = character } }
end

local function request(method, params)
  local r = client:request_sync(method, params, 10000, buf)
  if not r or r.err then
    check(method .. " answered", false, r and r.err or "timeout")
    return nil
  end
  return r.result
end

-- Diagnostics
check("diagnostics", vim.wait(20000, function()
  return diag_codes(buf) == "12:undefined-name,13:break-outside-loop"
end), diag_codes(buf))
local first = vim.diagnostic.get(buf)[1]
check("a diagnostic's message and source", first and first.source == "tiny", first)

local broken = vim.fn.bufadd(ws .. "/broken.tiny")
check("files that aren't open are checked", vim.wait(10000, function()
  return diag_codes(broken) == "0:syntax"
end), diag_codes(broken))

-- Navigation
local def = request("textDocument/definition", at(9, 21))
def = def and (def[1] or def)
check("definition", def and def.range.start.line == 1 and def.range.start.character == 3, def)

local refs = request("textDocument/references", vim.tbl_extend("force", at(1, 4), { context = { includeDeclaration = true } }))
local lines = {}
for _, r in ipairs(refs or {}) do
  table.insert(lines, r.range.start.line)
end
table.sort(lines)
check("references", table.concat(lines, ",") == "1,3,3,9", lines)

local hover = request("textDocument/hover", at(9, 21))
check("hover", hover and hover.contents.value:find("function fib") ~= nil, hover)

local symbols = request("textDocument/documentSymbol", { textDocument = { uri = uri } })
local names = {}
for _, s in ipairs(symbols or {}) do
  table.insert(names, s.name)
end
check("outline", table.concat(names, ",") == "fib,total,i", names)

local completion = request("textDocument/completion", at(12, 6))
local labels = {}
for _, item in ipairs((completion or {}).items or {}) do
  labels[item.label] = true
end
check("completion", labels.fib and labels.total and labels.print and labels["while"], vim.tbl_keys(labels))

local folds = request("textDocument/foldingRange", { textDocument = { uri = uri } })
local spans = {}
for _, f in ipairs(folds or {}) do
  spans[f.startLine .. "-" .. f.endLine] = true
end
check("folding", spans["1-3"] and spans["8-10"], vim.tbl_keys(spans))

-- Semantic highlighting, as Neovim applies it
vim.wait(5000, function()
  return #vim.inspect_pos(buf, 1, 0).semantic_tokens > 0
end)
local function token_at(line, col)
  local types = {}
  for _, t in ipairs(vim.inspect_pos(buf, line, col).semantic_tokens) do
    table.insert(types, t.opts.hl_group)
  end
  return table.concat(types, " ")
end
check("highlighting: keyword", token_at(1, 0):find("@lsp.type.keyword") ~= nil, token_at(1, 0))
check("highlighting: function", token_at(1, 3):find("@lsp.type.function") ~= nil, token_at(1, 3))
check("highlighting: comment", token_at(0, 2):find("@lsp.type.comment") ~= nil, token_at(0, 2))

-- Rename, applied to the buffer
local edit = request("textDocument/rename", vim.tbl_extend("force", at(7, 4), { newName = "k" }))
if edit then
  vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
end
check("rename", vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1] == "let k = 0;"
  and vim.api.nvim_buf_get_lines(buf, 10, 11, false)[1] == "    k = k + 1;", vim.api.nvim_buf_get_lines(buf, 7, 11, false))

-- Edits: the diagnostics follow
vim.api.nvim_buf_set_lines(buf, 12, 12, false, { "let missing = 1;" })
check("diagnostics after an edit", vim.wait(10000, function()
  return diag_codes(buf) == "14:break-outside-loop"
end), diag_codes(buf))

client:stop()
vim.wait(5000, function()
  return client:is_stopped()
end)
print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
