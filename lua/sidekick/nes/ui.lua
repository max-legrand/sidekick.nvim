local Config = require("sidekick.config")
local Nes = require("sidekick.nes")
local Util = require("sidekick.util")

local M = {}

---@param edit sidekick.NesEdit
function M.render(edit)
  vim.b[edit.buf].sidekick_nes_ui = true
  local diff = require("sidekick.nes.diff").diff(edit)

  local from, to = edit.from, edit.to

  local signs = Config.signs.enabled

  -- Add the sign at the first position
  Util.set_extmark(edit.buf, Config.ns, from[1], 0, {
    sign_text = signs and Config.signs.icon or nil,
    sign_hl_group = signs and "SidekickSign" or nil,
  })
  local rows = {} ---@type table<number, true>
  for _, hunk in ipairs(diff.hunks) do
    if not hunk.inline then
      for r = hunk.pos[1], hunk.pos[1] + hunk.cover - 1 do
        rows[r] = true
      end
    end
    for _, extmark in ipairs(hunk.extmarks) do
      local opts = vim.tbl_extend("force", {}, extmark) ---@type sidekick.Extmark
      opts.row, opts.col = nil, nil
      Util.set_extmark(edit.buf, Config.ns, extmark.row, extmark.col, opts)
    end
  end

  -- Only add the context bg for lines not yet touched by the rest including inline
  -- This is to fix an issue with extmarks otherwise not displayig correctly
  -- Additionally line_hl_group seems broken in some cases, so don't use that.
  for r = from[1], math.min(vim.api.nvim_buf_line_count(edit.buf) - 1, to[1]) do
    if not rows[r] then
      Util.set_extmark(edit.buf, Config.ns, r, 0, {
        end_row = r + 1,
        hl_group = "SidekickDiffContext",
        hl_eol = true,
      })
    end
  end
end

---@param buf number
function M._hide(buf)
  if vim.b[buf].sidekick_nes_ui then
    vim.b[buf].sidekick_nes_ui = nil
    vim.api.nvim_buf_clear_namespace(buf, Config.ns, 0, -1)
  end
end

function M.update()
  local edits = Nes.get()
  M.hide()
  vim.tbl_map(M.render, edits)

  vim.schedule(function()
    Util.emit("SidekickNes" .. (#edits == 0 and "Hide" or "Show"))
  end)
end

function M.hide()
  vim.tbl_map(M._hide, vim.api.nvim_list_bufs())
end

return M
