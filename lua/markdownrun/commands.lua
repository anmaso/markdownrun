local Commands = {}

local markdown = require('markdownrun.markdown')
local exec = require('markdownrun.execution')
local results = require('markdownrun.results')
local feedback = require('markdownrun.feedback')
local state = require('markdownrun.state')
local qf_entries = {}

local function notify(message, level)
  local ok = pcall(vim.notify, "[markdownrun] " .. message, level or vim.log.levels.INFO)
  if not ok then
    print("[markdownrun] " .. message)
  end
end

local function current_markdown_path(bufnr)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  return vim.fn.fnamemodify(name, ":p")
end

local function get_blocks_and_latest()
  local blocks = markdown.get_shell_blocks(0)
  local md_path = current_markdown_path(0)
  local latest = require('markdownrun.results').get_latest_by_block_id(md_path)
  return blocks, latest, md_path
end

local function get_block_at_or_near_cursor()
  local block = markdown.get_current_block(0)
  if block then return block end
  local blocks = markdown.get_shell_blocks(0)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, b in ipairs(blocks) do
    if cursor_line == (b.start_line - 1) or cursor_line == (b.end_line + 1) then
      return b
    end
  end
  return nil
end

--- Execute the current shell block under cursor and persist results
function Commands.run_current_block()
  local block = markdown.get_current_block(0)
  if not block then
    markdown.notify_not_in_runnable_block()
    return
  end
  local md_path = current_markdown_path(0)
  -- Prepare session: apply fast-path env/cwd updates prior to execution
  local session = state.get_session(0)
  state.parse_and_apply(block.content or '', session)
  pcall(function() feedback.set_indicator(0, block, 'running') end)
  exec.execute_block(block, {
    bufnr = 0,
    block_id = block.block_id,
    cwd = session.cwd,
    env = session.env,
    on_start = function()
      local label = string.sub(block.block_id, 1, 10)
      notify(string.format("Running block %s…", label))
    end,
    on_complete = function(res)
      vim.schedule(function()
        -- Reconcile cwd if execution reported changes (hybrid env capture)
        if res.reconciled_cwd and type(res.reconciled_cwd) == 'string' and #res.reconciled_cwd > 0 then
          local s = state.get_session(0)
          s.cwd = res.reconciled_cwd
        end
        -- Persist to results sidecar
        results.append_block_execution(md_path, block, res)
        local label = string.sub(block.block_id, 1, 10)
        if res.timed_out then
          notify(string.format("Block %s timed out after %dms", label, res.duration_ms), vim.log.levels.WARN)
          table.insert(qf_entries, { filename = md_path, lnum = block.start_line + 1, end_lnum = block.end_line + 1, text = string.format("[timeout] %s", (res.command or ''):gsub("\n", " "):sub(1, 120)) })
          pcall(function() feedback.set_indicator(0, block, 'err') end)
        elseif res.ok then
          notify(string.format("Block %s ok in %dms", label, res.duration_ms), vim.log.levels.INFO)
          pcall(function() feedback.set_indicator(0, block, 'ok') end)
        else
          notify(string.format("Block %s failed (%d) in %dms", label, res.code, res.duration_ms), vim.log.levels.WARN)
          pcall(function() feedback.set_indicator(0, block, 'err') end)
          local first_err = (res.stderr or ''):gsub("\r", ""):match("([^\n]*)") or ''
          table.insert(qf_entries, { filename = md_path, lnum = block.start_line + 1, end_lnum = block.end_line + 1, text = string.format("[exit %d] %s | %s", tonumber(res.code) or -1, (res.command or ''):gsub("\n", " "):sub(1, 80), first_err) })
        end
        -- Show popup with result summary
        pcall(function()
          feedback.popup_result(block, res)
        end)
      end)
    end,
  })
end

--- Show current session environment summary (and optional variable under cursor)
function Commands.show_env()
  local summary, sess = state.get_summary(0)
  local cursor_word = vim.fn.expand('<cword>')
  local lines = { 'MarkdownRun Session', string.rep('=', 20), summary, '' }
  if cursor_word and cursor_word ~= '' and sess.env[cursor_word] then
    table.insert(lines, string.format('%s=%s', cursor_word, sess.env[cursor_word]))
  else
    table.insert(lines, 'Tip: place cursor on a VAR to view its value')
  end
  pcall(function()
    feedback.popup_result(nil, { shell = '', cwd = sess.cwd, command = 'env', code = 0, duration_ms = 0, stdout = table.concat(lines, '\n'), stderr = '' })
  end)
end

--- Reset current buffer session state
function Commands.reset_session()
  state.reset_session(0)
end

--- Resynchronize results: keep only blocks present in current buffer
function Commands.resync_results()
  local bufnr = 0
  local blocks = markdown.get_shell_blocks(bufnr)
  if #blocks == 0 then
    notify('No shell blocks found to resync', vim.log.levels.INFO)
    return
  end
  local keep = {}
  for _, b in ipairs(blocks) do keep[b.block_id] = true end
  local md_path = current_markdown_path(bufnr)
  local removed, ok = require('markdownrun.results').prune_to_block_ids(md_path, keep)
  if ok then
    notify(string.format('Resynced results: removed %d stale entrie(s)', removed), vim.log.levels.INFO)
    -- Refresh indicators to reflect removals
    pcall(function() require('markdownrun.feedback').rehydrate_indicators(bufnr) end)
  end
end

--- Execute the next unexecuted block from cursor
function Commands.run_next_block(opts)
  opts = opts or {}
  local blocks, latest, md_path = get_blocks_and_latest()
  local pos = vim.api.nvim_win_get_cursor(0)
  local cursor_line = pos[1] - 1
  local target = nil
  for _, b in ipairs(blocks) do
    if b.start_line > cursor_line then
      local executed = latest[b.block_id] ~= nil
      if (not executed) or opts.force == true then
        target = b
        break
      end
    end
  end
  if not target then
    notify("No next block to execute", vim.log.levels.INFO)
    return
  end

  -- Move cursor to target block start
  pcall(vim.api.nvim_win_set_cursor, 0, { target.start_line + 1, 0 })
  -- Run as current block
  Commands.run_current_block()
end

--- Execute all shell blocks sequentially; stop on error unless force
function Commands.run_all(opts)
  opts = opts or {}
  local blocks, _, md_path = get_blocks_and_latest()
  local ok_count, fail_count = 0, 0
  for _, b in ipairs(blocks) do
    local session = state.get_session(0)
    state.parse_and_apply(b.content or '', session)
    pcall(function() feedback.set_indicator(0, b, 'running') end)
    local done = vim.loop.new_async(function() end)
    local completed = false
    exec.execute_block(b, {
      bufnr = 0,
      block_id = b.block_id,
      cwd = session.cwd,
      env = session.env,
      on_complete = function(res)
        vim.schedule(function()
          if res.reconciled_cwd and type(res.reconciled_cwd) == 'string' and #res.reconciled_cwd > 0 then
            local s = state.get_session(0)
            s.cwd = res.reconciled_cwd
          end
          results.append_block_execution(md_path, b, res)
          if res.ok and not res.timed_out then
            ok_count = ok_count + 1
            pcall(function() feedback.set_indicator(0, b, 'ok') end)
          else
            fail_count = fail_count + 1
            pcall(function() feedback.set_indicator(0, b, 'err') end)
            local first_err = (res.stderr or ''):gsub("\r", ""):match("([^\n]*)") or ''
            local text
            if res.timed_out then
              text = string.format("[timeout] %s", (res.command or ''):gsub("\n", " "):sub(1, 120))
            else
              text = string.format("[exit %d] %s | %s", tonumber(res.code) or -1, (res.command or ''):gsub("\n", " "):sub(1, 80), first_err)
            end
            table.insert(qf_entries, { filename = md_path, lnum = b.start_line + 1, end_lnum = b.end_line + 1, text = text })
          end
          completed = true
        end)
      end,
    })
    -- Simple wait loop for completion; in real plugin, better orchestration.
    vim.wait(1000 * 60, function() return completed end, 50, false)
    if fail_count > 0 and (opts.stop_on_error ~= false) then
      break
    end
  end
  feedback.popup_lines({ string.format("Run all complete: %d ok, %d failed", ok_count, fail_count) })
  if #qf_entries > 0 then
    pcall(vim.fn.setqflist, {}, ' ', { title = 'MarkdownRun Errors', items = qf_entries })
    notify(string.format("%d error(s) added to quickfix", #qf_entries), vim.log.levels.WARN)
  end
end

--- Open quickfix with last errors
function Commands.open_quickfix()
  if #qf_entries == 0 then
    notify("No recent errors", vim.log.levels.INFO)
    return
  end
  pcall(vim.cmd, 'copen')
end

--- Open popup with the latest result for the current block
function Commands.open_result_popup()
  local block = get_block_at_or_near_cursor()
  if not block then
    markdown.notify_not_in_runnable_block()
    return
  end
  local md_path = current_markdown_path(0)
  local latest = require('markdownrun.results').get_latest_entry(md_path, block.block_id)
  if not latest then
    notify('No results found for this block', vim.log.levels.INFO)
    return
  end
  local stdout = ''
  local stderr = ''
  if latest.stdout and latest.stdout.type == 'inline' then
    stdout = table.concat(latest.stdout.value or {}, '\n')
  elseif latest.stdout and latest.stdout.type == 'file' and latest.stdout.path then
    local data = require('markdownrun.results').read_artifact(latest.stdout.path)
    stdout = type(data) == 'string' and data or ''
  end
  if latest.stderr and latest.stderr.type == 'inline' then
    stderr = table.concat(latest.stderr.value or {}, '\n')
  elseif latest.stderr and latest.stderr.type == 'file' and latest.stderr.path then
    local data = require('markdownrun.results').read_artifact(latest.stderr.path)
    stderr = type(data) == 'string' and data or ''
  end
  feedback.popup_result(block, {
    shell = '', cwd = latest.cwd, command = latest.command, code = latest.exit_code,
    duration_ms = latest.duration_ms, stdout = stdout, stderr = stderr, artifacts = latest.artifacts or {}
  })
  notify('Opened popup with last result for current block', vim.log.levels.INFO)
end

return Commands
