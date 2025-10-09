local Config = require("sidekick.config")

local M = {}

---@class sidekick.lsp.Status
---@field busy boolean
---@field kind "Normal" | "Error" | "Warning" | "Inactive"
---@field message? string

local status = {} ---@type table<integer, sidekick.lsp.Status>

local levels = {
  Normal = vim.log.levels.INFO,
  Warning = vim.log.levels.WARN,
  Error = vim.log.levels.ERROR,
  Inactive = vim.log.levels.WARN,
}

---@param res sidekick.lsp.Status
---@type lsp.Handler
function M.on_status(err, res, ctx)
  if err then
    return
  end
  status[ctx.client_id] = vim.deepcopy(res)
  local level = levels[res.kind or "Normal"] or vim.log.levels.INFO

  if res.message and level >= Config.copilot.status.level then
    local msg = "**Copilot:** " .. res.message
    if msg:find("not signed") then
      msg = msg .. "\nPlease use `:LspCopilotSignIn` to sign in."
    end
    require("sidekick.util").notify(msg, res.kind == "Error" and vim.log.levels.ERROR or vim.log.levels.WARN)
  end
end

---@param client vim.lsp.Client
function M.attach(client)
  client.handlers.didChangeStatus = M.on_status
end

---@param buf? integer
---@return sidekick.lsp.Status?
function M.get(buf)
  local client = Config.get_client(buf)
  return client and (status[client.id] or { busy = false, kind = "Normal" }) or nil
end

function M.setup()
  vim.api.nvim_create_autocmd("LspAttach", {
    group = Config.augroup,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if client and Config.is_copilot(client) then
        M.attach(client)
      end
    end,
  })
  for _, client in ipairs(Config.get_clients()) do
    M.attach(client)
  end
end

return M
