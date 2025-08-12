local Feedback = {}

local function notify(message, level)
  local ok = pcall(vim.notify, "[markdownrun] " .. message, level or vim.log.levels.INFO)
  if not ok then
    print("[markdownrun] " .. message)
  end
end

local function create_scratch_buf(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  if filetype then
    pcall(vim.api.nvim_buf_set_option, buf, 'filetype', filetype)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Indicator state via extmarks
local ns = vim.api.nvim_create_namespace('markdownrun')
local indicator_enabled = true
local blockid_to_extmark = {}

local function get_config()
  local ok, core = pcall(require, 'markdownrun')
  if ok and type(core._config) == 'table' then
    return core._config
  end
  return { indicator = { enabled = true, symbols = { idle = '○', running = '…', ok = '✓', err = '✗' }, hl = { idle = 'Comment', running = 'WarningMsg', ok = 'DiagnosticOk', err = 'DiagnosticError' } } }
end

local function indicator_symbols()
  local cfg = get_config()
  local ind = (cfg.indicator or {})
  return ind.symbols or { idle = '○', running = '…', ok = '✓', err = '✗' }, ind.hl or { idle = 'Comment', running = 'WarningMsg', ok = 'DiagnosticOk', err = 'DiagnosticError' }
end

function Feedback.toggle_indicators()
  indicator_enabled = not indicator_enabled
  if not indicator_enabled then
    -- clear all extmarks for current buffer
    pcall(vim.api.nvim_buf_clear_namespace, 0, ns, 0, -1)
  end
  return indicator_enabled
end

function Feedback.set_indicator(bufnr, block, state)
  if indicator_enabled ~= true then return end
  if not block or not block.start_line then return end
  local symbols, hls = indicator_symbols()
  local text, hl = symbols[state] or '?', hls[state] or 'Comment'
  local ext_id = blockid_to_extmark[block.block_id]
  local virt = { { ' ' .. text .. ' ', hl } }
  if ext_id and ext_id > 0 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, block.start_line, 0, { id = ext_id, virt_text = virt, virt_text_pos = 'eol', hl_mode = 'combine' })
  else
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns, block.start_line, 0, { virt_text = virt, virt_text_pos = 'eol', hl_mode = 'combine' })
    blockid_to_extmark[block.block_id] = id
  end
end

--- Rehydrate indicators from results on buffer read
function Feedback.rehydrate_indicators(bufnr)
  bufnr = bufnr or 0
  if indicator_enabled ~= true then return end
  local md_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':p')
  if md_path == '' then return end
  local ok_res, res = pcall(require, 'markdownrun.results')
  if not ok_res then return end
  local blocks = require('markdownrun.markdown').get_shell_blocks(bufnr)
  local latest = res.get_latest_by_block_id(md_path)
  for _, b in ipairs(blocks) do
    local e = latest[b.block_id]
    local state = 'idle'
    if e then
      state = (tonumber(e.exit_code) == 0) and 'ok' or 'err'
    end
    Feedback.set_indicator(bufnr, b, state)
  end
end

local function compute_dimensions(lines)
  local width = 0
  for _, l in ipairs(lines) do
    if #l > width then width = #l end
  end
  width = math.min(math.max(40, width + 2), math.floor(vim.o.columns * 0.9))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  return width, height
end

local function open_floating_window(lines, opts)
  opts = opts or {}
  local buf = create_scratch_buf(lines, opts.filetype or 'markdown')
  local width, height = compute_dimensions(lines)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = opts.border or 'rounded',
    zindex = 200,
    noautocmd = true,
  })

  -- Close interactions
  vim.keymap.set('n', 'q', function() if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', function() if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end end, { buffer = buf, nowait = true, silent = true })

  -- Auto-close on cursor move or buffer leave
  local aug = vim.api.nvim_create_augroup('MarkdownRunPopup', { clear = false })
  -- Close when the popup buffer is left/hidden; avoid CursorMoved to prevent instant close
  vim.api.nvim_create_autocmd({ 'BufHidden', 'BufLeave' }, {
    group = aug,
    buffer = buf,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    end,
  })

  return win, buf
end

--- Public helper to open a simple popup with custom lines
function Feedback.popup_lines(lines, opts)
  open_floating_window(lines, opts)
end

local function truncate_lines(lines, max_lines)
  if #lines <= max_lines then return lines end
  local truncated = {}
  for i = 1, max_lines do truncated[i] = lines[i] end
  truncated[#truncated + 1] = string.format('… (%d more lines)', #lines - max_lines)
  return truncated
end

local function split_lines(s)
  local out = {}
  s = s or ''
  for line in (s .. "\n"):gmatch("(.-)\n") do
    -- strip trailing CR if present (Windows line endings)
    line = line:gsub("\r$", "")
    table.insert(out, line)
  end
  return out
end

--- Show a popup with execution result summary
-- block: table from markdown.get_current_block
-- result: table from execution.execute_block on_complete
function Feedback.popup_result(block, result)
  if not result then return end
  local title = string.format("Result %s", block and string.sub(block.block_id or '', 1, 8) or '')

  local ok_label
  if result.timed_out then
    ok_label = string.format("Timed out after %dms", tonumber(result.duration_ms) or 0)
  else
    ok_label = string.format("Exit %d in %dms", tonumber(result.code) or 0, tonumber(result.duration_ms) or 0)
  end

  local max_preview = 50
  local out_lines = split_lines(result.stdout)
  local err_lines = split_lines(result.stderr)
  out_lines = truncate_lines(out_lines, max_preview)
  err_lines = truncate_lines(err_lines, max_preview)

  local lines = {}
  table.insert(lines, title)
  table.insert(lines, string.rep('=', #title))
  -- Show stdout first
  table.insert(lines, "Stdout:")
  if #out_lines == 0 then table.insert(lines, "<empty>") else for _, l in ipairs(out_lines) do table.insert(lines, l) end end
  table.insert(lines, "")
  table.insert(lines, "Stderr:")
  if #err_lines == 0 then table.insert(lines, "<empty>") else for _, l in ipairs(err_lines) do table.insert(lines, l) end end
  table.insert(lines, "")
  -- Then other details
  table.insert(lines, "Command:")
  local cmd_lines = split_lines(result.command or '')
  if #cmd_lines == 0 then table.insert(lines, "<empty>") else for _, l in ipairs(cmd_lines) do table.insert(lines, l) end end
  table.insert(lines, "")
  table.insert(lines, string.format("Shell: %s", tostring(result.shell or '')))
  table.insert(lines, string.format("CWD:   %s", tostring(result.cwd or '')))
  table.insert(lines, string.format("%s", ok_label))
  if result.artifacts and (result.artifacts.stdout_file or result.artifacts.stderr_file) then
    table.insert(lines, string.format("Artifacts: %s %s",
      result.artifacts.stdout_file or '', result.artifacts.stderr_file or ''))
  end
  table.insert(lines, "")
  table.insert(lines, "Press q or <Esc> to close")

  open_floating_window(lines, { filetype = 'markdown' })
end

return Feedback
