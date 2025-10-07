local Util = require("sidekick.util")

local M = {}

M._watches = {} ---@type table<string, {event: uv.uv_fs_event_t, timer: uv.uv_timer_t}>
M.enabled = false

function M.refresh()
  vim.cmd.checktime()
end

---@param path string
function M.start(path)
  if M._watches[path] ~= nil then
    return
  end
  Util.debug("Watching `" .. path .. "`")
  local handle = assert(vim.uv.new_fs_event())
  local timer = assert(vim.uv.new_timer())
  local ok, err = handle:start(path, {}, function(_, file)
    if not file then
      return
    end
    file = path .. "/" .. file
    timer:start(100, 0, function()
      Util.debug("changed `" .. file .. "`")
      vim.schedule(M.refresh)
    end)
  end)
  if not ok then
    Util.error("Failed to watch " .. path .. ": " .. err)
    if not handle:is_closing() then
      handle:close()
    end
    if not timer:is_closing() then
      timer:close()
    end
    return
  end
  M._watches[path] = { event = handle, timer = timer }
end

function M.update()
  local paths = {} ---@type table<string, boolean>
  for _, buf in pairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local fname = vim.api.nvim_buf_get_name(buf)
      if vim.uv.fs_stat(fname) ~= nil then
        local path = vim.fs.dirname(fname)
        if path ~= "" and not paths[path] then
          paths[path] = true
        end
      end
    end
  end
  for path in pairs(paths) do
    M.start(path)
  end
  for path in pairs(M._watches) do
    if not paths[path] then
      M.stop(path)
    end
  end
end

---@param path string
function M.stop(path)
  local w = M._watches[path]
  if w then
    Util.debug("Stopped watching `" .. path .. "`")
    if not w.event:is_closing() then
      w.event:close()
    end
    if not w.timer:is_closing() then
      w.timer:close()
    end
    M._watches[path] = nil
  end
end

-- Stop all watches
function M.disable()
  if not M.enabled then
    return
  end
  M.enabled = false
  pcall(vim.api.nvim_clear_autocmds, { group = "sidekick.watch" })
  pcall(vim.api.nvim_del_augroup_by_name, "sidekick.watch")
  for path in pairs(M._watches) do
    M.stop(path)
  end
end

function M.enable()
  if M.enabled then
    return
  end
  M.enabled = true
  vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("sidekick.watch", { clear = true }),
    callback = M.update,
  })
  M.update()
end

return M
