local M = {}

local default_config = {
  debug = false,
  execution = {
    shell = "/bin/sh",
    timeout_ms = 30000,
  },
  results = {
    inline_limit_lines = 100,
    base_dir = nil,
  },
}

M._config = vim.deepcopy(default_config)
M._version = "0.1.0"

local function notify(message, level)
  local ok = pcall(vim.notify, "[markdownrun] " .. message, level or vim.log.levels.INFO)
  if not ok then
    -- Fallback in very minimal environments
    print("[markdownrun] " .. message)
  end
end

local function define_commands()
  -- Avoid redefining commands if setup is called more than once
  local existing = vim.api.nvim_get_commands and vim.api.nvim_get_commands({ builtin = false }) or {}
  local has_info = existing["MarkdownRunInfo"] ~= nil
  local has_debug = existing["MarkdownRunDebug"] ~= nil
  local has_run = existing["MarkdownRun"] ~= nil
  local has_env = existing["MarkdownRunEnv"] ~= nil
  local has_reset = existing["MarkdownRunReset"] ~= nil
  local has_toggle = existing["MarkdownRunToggleIndicators"] ~= nil
  local has_next = existing["MarkdownRunNext"] ~= nil
  local has_all = existing["MarkdownRunAll"] ~= nil
  local has_qf = existing["MarkdownRunQuickfix"] ~= nil
  local has_open_res = existing["MarkdownRunOpenResult"] ~= nil
  local has_open_res_alias = existing["MarkdownRunOpenResults"] ~= nil
  local has_resync = existing["MarkdownRunResync"] ~= nil

  if not has_info then
    vim.api.nvim_create_user_command(
      "MarkdownRunInfo",
      function()
        notify(string.format("Loaded v%s | debug=%s", M._version, tostring(M._config.debug)))
      end,
      { desc = "Show MarkdownRun plugin information" }
    )
  end

  if not has_debug then
    vim.api.nvim_create_user_command(
      "MarkdownRunDebug",
      function()
        local cfg = vim.inspect(M._config)
        notify("Current configuration:\n" .. cfg)
      end,
      { desc = "Show MarkdownRun debug information" }
    )
  end

  if not has_run then
    vim.api.nvim_create_user_command(
      "MarkdownRun",
      function()
        require('markdownrun.commands').run_current_block()
      end,
      { desc = "Execute current markdown shell block" }
    )
  end

  if not has_env then
    vim.api.nvim_create_user_command(
      "MarkdownRunEnv",
      function()
        require('markdownrun.commands').show_env()
      end,
      { desc = "Show current MarkdownRun session environment" }
    )
  end

  if not has_reset then
    vim.api.nvim_create_user_command(
      "MarkdownRunReset",
      function()
        require('markdownrun.commands').reset_session()
      end,
      { desc = "Reset current MarkdownRun session" }
    )
  end

  if not has_toggle then
    vim.api.nvim_create_user_command(
      "MarkdownRunToggleIndicators",
      function()
        local ok, fb = pcall(require, 'markdownrun.feedback')
        if ok and fb.toggle_indicators then
          local enabled = fb.toggle_indicators()
          notify("Indicators " .. (enabled and "enabled" or "disabled"))
        end
      end,
      { desc = "Toggle MarkdownRun virtual text indicators" }
    )
  end

  if not has_next then
    vim.api.nvim_create_user_command(
      "MarkdownRunNext",
      function(opts)
        require('markdownrun.commands').run_next_block({ force = opts.bang })
      end,
      { desc = "Execute the next unexecuted shell block", bang = true }
    )
  end

  if not has_all then
    vim.api.nvim_create_user_command(
      "MarkdownRunAll",
      function(opts)
        local stop_on_error = not opts.bang
        require('markdownrun.commands').run_all({ stop_on_error = stop_on_error })
      end,
      { desc = "Execute all shell blocks sequentially (! to not stop on error)", bang = true }
    )
  end

  if not has_qf then
    vim.api.nvim_create_user_command(
      "MarkdownRunQuickfix",
      function()
        require('markdownrun.commands').open_quickfix()
      end,
      { desc = "Open quickfix populated by recent MarkdownRun errors" }
    )
  end

  if not has_open_res then
    vim.api.nvim_create_user_command(
      "MarkdownRunOpenResult",
      function()
        require('markdownrun.commands').open_result_popup()
      end,
      { desc = "Open popup with latest result for current block" }
    )
  end

  if not has_open_res_alias then
    vim.api.nvim_create_user_command(
      "MarkdownRunOpenResults",
      function()
        require('markdownrun.commands').open_result_popup()
      end,
      { desc = "Alias: Open popup with latest result for current block" }
    )
  end

  if not has_resync then
    vim.api.nvim_create_user_command(
      "MarkdownRunResync",
      function()
        require('markdownrun.commands').resync_results()
      end,
      { desc = "Resynchronize results sidecar with current buffer blocks" }
    )
  end
end

function M.setup(user_config)
  user_config = user_config or {}
  -- Seed defaults then merge user config
  M._config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user_config)
  define_commands()

  if M._config.debug then
    notify("Setup complete")
  end

  -- Default keymap for manual run
  -- Users can override or remove this in their own config
  pcall(vim.keymap.set, 'n', '<leader>rm', '<cmd>MarkdownRun<CR>', { desc = 'MarkdownRun: execute current block', silent = true })

  -- Rehydrate indicators on Markdown buffer read
  vim.api.nvim_create_augroup('MarkdownRunHydrate', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWinEnter' }, {
    group = 'MarkdownRunHydrate',
    pattern = { '*.md', '*.markdown' },
    callback = function(args)
      local ok, fb = pcall(require, 'markdownrun.feedback')
      if ok and fb.rehydrate_indicators then
        fb.rehydrate_indicators(args.buf)
      end
    end,
  })

  -- Buffer-local keymaps for markdown buffers
  vim.api.nvim_create_augroup('MarkdownRunKeymaps', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = 'MarkdownRunKeymaps',
    pattern = { 'markdown' },
    callback = function(args)
      local buf = args.buf
      local ok_set = pcall(vim.keymap.set, 'n', '<leader>rn', '<cmd>MarkdownRunNext<CR>', { buffer = buf, desc = 'MarkdownRun: next block', silent = true })
      ok_set = pcall(vim.keymap.set, 'n', '<leader>ra', '<cmd>MarkdownRunAll<CR>', { buffer = buf, desc = 'MarkdownRun: run all blocks', silent = true }) and ok_set
      ok_set = pcall(vim.keymap.set, 'n', '<leader>re', '<cmd>MarkdownRunEnv<CR>', { buffer = buf, desc = 'MarkdownRun: show env', silent = true }) and ok_set
      ok_set = pcall(vim.keymap.set, 'n', '<leader>rr', '<cmd>MarkdownRunReset<CR>', { buffer = buf, desc = 'MarkdownRun: reset session', silent = true }) and ok_set
      ok_set = pcall(vim.keymap.set, 'n', '<leader>ri', '<cmd>MarkdownRunToggleIndicators<CR>', { buffer = buf, desc = 'MarkdownRun: toggle indicators', silent = true }) and ok_set
      ok_set = pcall(vim.keymap.set, 'n', '<leader>rq', '<cmd>MarkdownRunQuickfix<CR>', { buffer = buf, desc = 'MarkdownRun: open quickfix', silent = true }) and ok_set
      ok_set = pcall(vim.keymap.set, 'n', '<leader>ro', '<cmd>MarkdownRunOpenResult<CR>', { buffer = buf, desc = 'MarkdownRun: open last result', silent = true }) and ok_set
    end,
  })
end

return M
