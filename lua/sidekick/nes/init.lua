local Config = require("sidekick.config")
local Util = require("sidekick.util")

local M = {}

---@alias sidekick.Pos {[1]:integer, [2]:integer}

---@class sidekick.lsp.NesEdit
---@field command lsp.Command
---@field range lsp.Range
---@field text string
---@field textDocument {uri: string, version: integer}

---@class sidekick.NesEdit: sidekick.lsp.NesEdit
---@field buf integer
---@field from sidekick.Pos
---@field to sidekick.Pos
---@field diff? sidekick.Diff

M._edits = {} ---@type sidekick.NesEdit[]
M._requests = {} ---@type table<number, number>
M.enabled = false
M.did_setup = false

-- Copilot requires the custom didFocus notification
local function did_focus()
  if not M.enabled then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local client = Config.get_client(buf)
  ---@diagnostic disable-next-line: param-type-mismatch
  return client and client:notify("textDocument/didFocus", { textDocument = { uri = vim.uri_from_bufnr(buf) } }) or nil
end

---@param enable? boolean
function M.enable(enable)
  enable = enable ~= false
  if M.enabled == enable then
    return
  end
  M.enabled = enable ~= false
  if M.enabled then
    Config.nes.enabled = Config.nes.enabled == false and true or Config.nes.enabled
    M.setup()
    did_focus()
    M.update()
  else
    M.clear()
  end
end

function M.toggle()
  M.enable(not M.enabled)
end

function M.disable()
  M.enable(false)
end

---@private
function M.setup()
  if M.did_setup then
    return
  end
  M.did_setup = true
  ---@param events string[]
  ---@param fn fun()
  local function on(events, fn)
    for _, event in ipairs(events) do
      local name, pattern = event:match("^(%S+)%s*(.*)$") --[[@as string, string]]
      vim.api.nvim_create_autocmd(name, {
        pattern = pattern ~= "" and pattern or nil,
        group = Config.augroup,
        callback = fn,
      })
    end
  end

  on(Config.nes.clear.events, M.clear)
  on(Config.nes.trigger.events, Util.debounce(M.update, Config.nes.debounce))
  on({ "BufEnter", "WinEnter" }, Util.debounce(did_focus, 10))

  if Config.nes.clear.esc then
    local ESC = vim.keycode("<Esc>")
    vim.on_key(function(_, typed)
      if typed == ESC then
        M.clear()
      end
    end, nil)
  end
end

---@param buf? integer
---@return boolean
local function is_enabled(buf)
  local enabled = M.enabled and Config.nes.enabled or false
  buf = buf or vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return false
  end
  if type(enabled) == "function" then
    return enabled(buf) or false
  end
  return enabled ~= false
end

-- Request new edits from the LSP server (if any)
function M.update()
  local buf = vim.api.nvim_get_current_buf()
  M.clear()

  if not is_enabled(buf) then
    return
  end

  local client = Config.get_client(buf)
  if not client then
    return
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  ---@diagnostic disable-next-line: inject-field
  params.textDocument.version = vim.lsp.util.buf_versions[buf]

  ---@diagnostic disable-next-line: param-type-mismatch
  local ok, request_id = client:request("textDocument/copilotInlineEdit", params, M._handler)
  if ok and request_id then
    M._requests[client.id] = request_id
  end
end

---@private
---@param buf? number
function M.get(buf)
  ---@param edit sidekick.NesEdit
  return vim.tbl_filter(function(edit)
    if not vim.api.nvim_buf_is_valid(edit.buf) then
      return false
    end
    if edit.textDocument.version ~= vim.lsp.util.buf_versions[edit.buf] then
      return false
    end
    if not is_enabled(edit.buf) then
      return false
    end
    return buf == nil or edit.buf == buf
  end, M._edits)
end

-- Clear all active edits
function M.clear()
  M.cancel()
  M._edits = {}
  require("sidekick.nes.ui").update()
end

--- Cancel pending requests
---@private
function M.cancel()
  for client_id, request_id in pairs(M._requests) do
    M._requests[client_id] = nil
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      client:cancel_request(request_id)
    end
  end
end

---@param res {edits: sidekick.lsp.NesEdit[]}
---@type lsp.Handler
function M._handler(err, res, ctx)
  M._requests[ctx.client_id] = nil

  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if err or not client then
    return
  end

  M._edits = {}

  res = res or { edits = {} }

  ---@param buf number
  ---@param p lsp.Position
  ---@return sidekick.Pos
  local function pos(buf, p)
    local line = vim.api.nvim_buf_get_lines(buf, p.line, p.line + 1, false)[1] or ""
    return { p.line, vim.str_byteindex(line, client.offset_encoding, p.character, false) }
  end

  for _, edit in ipairs(res.edits or {}) do
    local fname = vim.uri_to_fname(edit.textDocument.uri)
    local buf = vim.fn.bufnr(fname, false)
    if
      buf
      and vim.api.nvim_buf_is_valid(buf)
      and is_enabled(buf)
      and edit.textDocument.version == vim.lsp.util.buf_versions[buf]
    then
      ---@cast edit sidekick.NesEdit
      edit.buf = buf
      edit.from, edit.to = pos(buf, edit.range.start), pos(buf, edit.range["end"])
      edit.to = M.fix_pos(buf, edit.to)
      table.insert(M._edits, edit)
    end
  end

  require("sidekick.nes.ui").update()
end

---@param buf number
---@param pos sidekick.Pos
---@private
function M.fix_pos(buf, pos)
  local last_line = vim.api.nvim_buf_line_count(buf) - 1
  if pos[1] > last_line then
    return { last_line, #(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or "") }
  end
  return pos
end

--- Jump to the start of the active edit
---@return boolean jumped
function M.jump()
  local buf = vim.api.nvim_get_current_buf()
  if not is_enabled(buf) then
    return false
  end
  local edit = M.get(buf)[1]

  if not edit then
    return false
  end

  local diff = require("sidekick.nes.diff").diff(edit)
  local hunk = vim.deepcopy(diff.hunks[1])
  local pos = hunk.pos

  return M._jump(pos)
end

---@param pos sidekick.Pos
function M._jump(pos)
  pos = vim.deepcopy(pos)
  pos = M.fix_pos(0, pos)

  local win = vim.api.nvim_get_current_win()

  -- check if we need to jump
  pos[1] = pos[1] + 1
  local cursor = vim.api.nvim_win_get_cursor(win)
  if cursor[1] == pos[1] and cursor[2] == pos[2] then
    return false
  end

  -- schedule jump
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    -- add to jump list
    if Config.jump.jumplist then
      vim.cmd("normal! m'")
    end
    vim.api.nvim_win_set_cursor(win, pos)
  end)
  return true
end

-- Check if any edits are active in the current buffer
function M.have()
  local buf = vim.api.nvim_get_current_buf()
  if not is_enabled(buf) then
    return false
  end
  return #M.get(buf) > 0
end

--- Apply active text edits
---@return boolean applied
function M.apply()
  local buf = vim.api.nvim_get_current_buf()
  if not is_enabled(buf) then
    M.clear()
    return false
  end
  local client = Config.get_client(buf)
  local edits = M.get(buf)
  if not client or #edits == 0 then
    return false
  end
  ---@param edit sidekick.NesEdit
  local text_edits = vim.tbl_map(function(edit)
    return {
      range = edit.range,
      newText = edit.text,
    }
  end, edits) --[[@as lsp.TextEdit[] ]]
  vim.schedule(function()
    local last = edits[#edits]
    local diff = require("sidekick.nes.diff").diff(last)

    -- apply the edits
    vim.lsp.util.apply_text_edits(text_edits, buf, client.offset_encoding)

    -- let the LSP server know
    for _, edit in ipairs(edits) do
      if edit.command then
        client:exec_cmd(edit.command, { bufnr = buf })
      end
    end

    -- jump to end of last edit
    local pos = vim.deepcopy(last.from)
    if #diff.to.lines >= 1 then
      pos[1] = pos[1] + (#diff.to.lines - 1)
      pos[2] = pos[2] + #diff.to.text
    end
    M._jump(pos)

    Util.emit("SidekickNesDone", { client_id = client.id, buffer = buf })
  end)
  M.clear()
  return true
end

return M
