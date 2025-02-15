local util = require('vim.lsp.util')
local api = vim.api
local M = {}

--- bufnr → true|nil
--- to throttle refreshes to at most one at a time
local active_refreshes = {}

--- bufnr -> client_id -> lenses
local lens_cache_by_buf = setmetatable({}, {
  __index = function(t, b)
    local key = b > 0 and b or api.nvim_get_current_buf()
    return rawget(t, key)
  end
})

local namespaces = setmetatable({}, {
  __index = function(t, key)
    local value = api.nvim_create_namespace('vim_lsp_codelens:' .. key)
    rawset(t, key, value)
    return value
  end;
})

---@private
M.__namespaces = namespaces


---@private
local function execute_lens(lens, bufnr, client_id)
  local line = lens.range.start.line
  api.nvim_buf_clear_namespace(bufnr, namespaces[client_id], line, line + 1)

  -- Need to use the client that returned the lens → must not use buf_request
  local client = vim.lsp.get_client_by_id(client_id)
  assert(client, 'Client is required to execute lens, client_id=' .. client_id)
  client.request('workspace/executeCommand', lens.command, function(...)
    local result = vim.lsp.handlers['workspace/executeCommand'](...)
    M.refresh()
    return result
  end, bufnr)
end


--- Return all lenses for the given buffer
---
---@param bufnr number  Buffer number. 0 can be used for the current buffer.
---@return table (`CodeLens[]`)
function M.get(bufnr)
  local lenses_by_client = lens_cache_by_buf[bufnr or 0]
  if not lenses_by_client then return {} end
  local lenses = {}
  for _, client_lenses in pairs(lenses_by_client) do
    vim.list_extend(lenses, client_lenses)
  end
  return lenses
end


--- Run the code lens in the current line
---
function M.run()
  local line = api.nvim_win_get_cursor(0)[1]
  local bufnr = api.nvim_get_current_buf()
  local options = {}
  local lenses_by_client = lens_cache_by_buf[bufnr] or {}
  for client, lenses in pairs(lenses_by_client) do
    for _, lens in pairs(lenses) do
      if lens.range.start.line == (line - 1) then
        table.insert(options, {client=client, lens=lens})
      end
    end
  end
  if #options == 0 then
    vim.notify('No executable codelens found at current line')
  elseif #options == 1 then
    local option = options[1]
    execute_lens(option.lens, bufnr, option.client)
  else
    local options_strings = {"Code lenses:"}
    for i, option in ipairs(options) do
       table.insert(options_strings, string.format('%d. %s', i, option.lens.command.title))
    end
    local choice = vim.fn.inputlist(options_strings)
    if choice < 1 or choice > #options then
      return
    end
    local option = options[choice]
    execute_lens(option.lens, bufnr, option.client)
  end
end


--- Display the lenses using virtual text
---
---@param lenses table of lenses to display (`CodeLens[] | null`)
---@param bufnr number
---@param client_id number
function M.display(lenses, bufnr, client_id)
  if not lenses or not next(lenses) then
    return
  end
  local lenses_by_lnum = {}
  for _, lens in pairs(lenses) do
    local line_lenses = lenses_by_lnum[lens.range.start.line]
    if not line_lenses then
      line_lenses = {}
      lenses_by_lnum[lens.range.start.line] = line_lenses
    end
    table.insert(line_lenses, lens)
  end
  local ns = namespaces[client_id]
  local num_lines = api.nvim_buf_line_count(bufnr)
  for i = 0, num_lines do
    local line_lenses = lenses_by_lnum[i] or {}
    api.nvim_buf_clear_namespace(bufnr, ns, i, i + 1)
    local chunks = {}
    local num_line_lenses = #line_lenses
    for j, lens in ipairs(line_lenses) do
      local text = lens.command and lens.command.title or 'Unresolved lens ...'
      table.insert(chunks, {text, 'LspCodeLens' })
      if j < num_line_lenses then
        table.insert(chunks, {' | ', 'LspCodeLensSeparator' })
      end
    end
    if #chunks > 0 then
      api.nvim_buf_set_extmark(bufnr, ns, i, 0, { virt_text = chunks })
    end
  end
end


--- Store lenses for a specific buffer and client
---
---@param lenses table of lenses to store (`CodeLens[] | null`)
---@param bufnr number
---@param client_id number
function M.save(lenses, bufnr, client_id)
  local lenses_by_client = lens_cache_by_buf[bufnr]
  if not lenses_by_client then
    lenses_by_client = {}
    lens_cache_by_buf[bufnr] = lenses_by_client
    local ns = namespaces[client_id]
    api.nvim_buf_attach(bufnr, false, {
      on_detach = function(b) lens_cache_by_buf[b] = nil end,
      on_lines = function(_, b, _, first_lnum, last_lnum)
        api.nvim_buf_clear_namespace(b, ns, first_lnum, last_lnum)
      end
    })
  end
  lenses_by_client[client_id] = lenses
end


---@private
local function resolve_lenses(lenses, bufnr, client_id, callback)
  lenses = lenses or {}
  local num_lens = vim.tbl_count(lenses)
  if num_lens == 0 then
    callback()
    return
  end

  ---@private
  local function countdown()
    num_lens = num_lens - 1
    if num_lens == 0 then
      callback()
    end
  end
  local ns = namespaces[client_id]
  local client = vim.lsp.get_client_by_id(client_id)
  for _, lens in pairs(lenses or {}) do
    if lens.command then
      countdown()
    else
      client.request('codeLens/resolve', lens, function(_, _, result)
        if result and result.command then
          lens.command = result.command
          -- Eager display to have some sort of incremental feedback
          -- Once all lenses got resolved there will be a full redraw for all lenses
          -- So that multiple lens per line are properly displayed
          api.nvim_buf_set_extmark(
            bufnr,
            ns,
            lens.range.start.line,
            0,
            { virt_text = {{ lens.command.title, 'LspCodeLens' }} }
          )
        end
        countdown()
      end, bufnr)
    end
  end
end


--- |lsp-handler| for the method `textDocument/codeLens`
---
function M.on_codelens(err, _, result, client_id, bufnr)
  assert(not err, vim.inspect(err))

  M.save(result, bufnr, client_id)

  -- Eager display for any resolved (and unresolved) lenses and refresh them
  -- once resolved.
  M.display(result, bufnr, client_id)
  resolve_lenses(result, bufnr, client_id, function()
    M.display(result, bufnr, client_id)
    active_refreshes[bufnr] = nil
  end)
end


--- Refresh the codelens for the current buffer
---
--- It is recommended to trigger this using an autocmd or via keymap.
---
--- <pre>
---   autocmd BufEnter,CursorHold,InsertLeave <buffer> lua vim.lsp.codelens.refresh()
--- </pre>
---
function M.refresh()
  local params = {
    textDocument = util.make_text_document_params()
  }
  local bufnr = api.nvim_get_current_buf()
  if active_refreshes[bufnr] then
    return
  end
  active_refreshes[bufnr] = true
  vim.lsp.buf_request(0, 'textDocument/codeLens', params)
end


return M
