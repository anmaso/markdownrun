local Execution = {}

-- Local configuration defaults. Users can override via require('markdownrun').setup({ execution = { ... } }) later.
local DEFAULTS = {
  shell = "/bin/sh",
  timeout_ms = 30000,
}

local function get_config()
  local ok, core = pcall(require, "markdownrun")
  if ok and type(core._config) == "table" then
    local user_exec = (core._config.execution or {})
    -- Merge user overrides over module defaults
    return vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), user_exec)
  end
  return vim.deepcopy(DEFAULTS)
end

local function notify(message, level)
  local ok = pcall(vim.notify, "[markdownrun] " .. message, level or vim.log.levels.INFO)
  if not ok then
    print("[markdownrun] " .. message)
  end
end

local function resolve_cwd(bufnr)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name and name ~= "" then
    local dir = vim.fn.fnamemodify(name, ":p:h")
    return dir
  end
  return vim.loop.cwd()
end

local function get_env_capture_config()
  local ok, core = pcall(require, "markdownrun")
  if ok and type(core._config) == "table" then
    local c = core._config.env_capture or {}
    return {
      strategy = c.strategy or 'hybrid',
    }
  end
  return { strategy = 'hybrid' }
end

local function sh_quote(s)
  s = s or ""
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function fs_read_all(path)
  local uv = vim.loop
  local fd = uv.fs_open(path, "r", 420)
  if not fd then return nil end
  local stat = uv.fs_fstat(fd)
  local data = ""
  if stat and stat.size and stat.size > 0 then
    data = uv.fs_read(fd, stat.size, 0) or ""
  end
  uv.fs_close(fd)
  return data
end

--- Execute a shell command asynchronously.
-- opts = {
--   bufnr: number, -- buffer to derive cwd from; defaults to current
--   cwd: string, -- working directory; overrides bufnr-derived cwd if provided
--   env: table<string, string>, -- environment vars
--   timeout_ms: number, -- defaults to config
--   shell: string, -- defaults to config
--   on_start: function(ctx),
--   on_complete: function(result),
--   block_id: string, -- optional identifier for status/result correlation
-- }
function Execution.execute_command(command_text, opts)
  opts = opts or {}
  local config = get_config()
  local shell_path = opts.shell or config.shell
  local timeout_ms = opts.timeout_ms or config.timeout_ms
  local cwd = opts.cwd or resolve_cwd(opts.bufnr)
  local env_kv = opts.env or {}

  local start_time = vim.loop.hrtime()

  local context = {
    cwd = cwd,
    shell = shell_path,
    timeout_ms = timeout_ms,
    block_id = opts.block_id,
    command = command_text,
  }

  if opts.on_start then
    pcall(opts.on_start, context)
  else
    local label = opts.block_id and ("block " .. string.sub(opts.block_id, 1, 12)) or "command"
    notify(string.format("Starting %s in %s", label, cwd))
  end

  -- Normalize env into list for libuv when needed
  local env_list = nil
  if next(env_kv) ~= nil then
    env_list = {}
    for k, v in pairs(env_kv) do
      table.insert(env_list, string.format("%s=%s", k, v))
    end
  end

  local result_acc = {
    stdout = {},
    stderr = {},
  }

  local function finalize(ok, code, signal, timed_out_flag)
    local duration_ms = math.floor((vim.loop.hrtime() - start_time) / 1e6)
    local result = {
      ok = ok,
      code = code or 0,
      signal = signal or 0,
      timed_out = timed_out_flag or false,
      stdout = table.concat(result_acc.stdout),
      stderr = table.concat(result_acc.stderr),
      duration_ms = duration_ms,
      cwd = cwd,
      command = command_text,
      block_id = opts.block_id,
      shell = shell_path,
    }

    if opts.on_complete then
      pcall(opts.on_complete, result)
    else
      local label = opts.block_id and ("block " .. string.sub(opts.block_id, 1, 12)) or "command"
      if result.timed_out then
        notify(string.format("Timed out after %dms running %s", duration_ms, label), vim.log.levels.WARN)
      elseif result.ok then
        notify(string.format("Completed %s in %dms", label, duration_ms), vim.log.levels.INFO)
      else
        notify(string.format("Failed (%d) %s in %dms", result.code, label, duration_ms), vim.log.levels.WARN)
      end
    end

    return result
  end

  -- Prefer vim.system when available (Neovim 0.10+), fallback to uv.spawn
  if type(vim.system) == "function" then
    local capture_cfg = get_env_capture_config()
    local state_file = nil
    local command_to_run = command_text
    if capture_cfg.strategy ~= 'parse' then
      state_file = vim.fn.tempname()
      local q = sh_quote(state_file)
      -- Wrap the user command robustly inside a group and append trailer without a leading semicolon
      local trailer = "status=$?; printf '__MR_PWD__=%s\\n' \"$PWD\" > " .. q ..
        "; /usr/bin/env -0 >> " .. q .. "; exit $status )"
      command_to_run = table.concat({
        "set -a; (",
        "{",
        command_text,
        "}",
        trailer,
      }, "\n")
    end
    local finished = false
    local timer = vim.loop.new_timer()
    local function stop_timer()
      if timer and not timer:is_closing() then
        pcall(function() timer:stop() end)
        pcall(function() timer:close() end)
      end
    end

    local sys = vim.system({ shell_path, "-c", command_to_run }, {
      text = true,
      cwd = cwd,
      env = env_kv,
    }, function(obj)
      -- Called on exit. Depending on Neovim version, obj may be a result table or a process handle.
      if finished then return end
      stop_timer()

      local code, signal = 0, 0
      local out, err = nil, nil

      if type(obj) == "table" and (obj.code ~= nil or obj.signal ~= nil or obj.stdout ~= nil or obj.stderr ~= nil) then
        -- Newer API: obj is a result table when text=true
        code = tonumber(obj.code) or 0
        signal = tonumber(obj.signal) or 0
        out = obj.stdout
        err = obj.stderr
      elseif type(obj) == "table" and type(obj.wait) == "function" then
        -- Older API: obj is a process handle; wait and then read
        local res = obj:wait()
        code = tonumber(res.code) or 0
        signal = tonumber(res.signal) or 0
        if type(obj.read_stdout) == "function" then out = obj:read_stdout() end
        if type(obj.read_stderr) == "function" then err = obj:read_stderr() end
      elseif type(obj) == "number" then
        -- Fallback: some versions pass (code, signal) as separate args; try to read from sys
        code = obj
        signal = 0
      end

      if out and #out > 0 then table.insert(result_acc.stdout, out) end
      if err and #err > 0 then table.insert(result_acc.stderr, err) end
      local reconciled_cwd = nil
      if state_file then
        local data = fs_read_all(state_file)
        if data and #data > 0 then
          local pwd_line = data:match("__MR_PWD__=([^\n]*)")
          if pwd_line and #pwd_line > 0 then
            reconciled_cwd = pwd_line
          end
        end
        pcall(vim.loop.fs_unlink, state_file)
      end
      finished = true
      local res = finalize(code == 0, code, signal, false)
      if reconciled_cwd then res.reconciled_cwd = reconciled_cwd end
    end)

    -- Enforce timeout with a timer that kills the process
    timer:start(timeout_ms, 0, function()
      if finished then return end
      -- Kill the process if still running
      pcall(function()
        sys:kill("sigterm")
      end)
      -- Give a short grace period, then force kill if needed
      vim.defer_fn(function()
        pcall(function()
          sys:kill("sigkill")
        end)
      end, 500)
      -- Report timeout immediately; guard double finalize
      if not finished then
        finished = true
        finalize(false, -1, 0, true)
      end
    end)

    return {
      stop = function()
        pcall(function()
          sys:kill("sigterm")
        end)
        stop_timer()
      end,
    }
  else
    -- libuv implementation
    local stdout_pipe = vim.loop.new_pipe(false)
    local stderr_pipe = vim.loop.new_pipe(false)

    local handle
    local exited = false

    local function close_handles()
      if stdout_pipe and not stdout_pipe:is_closing() then stdout_pipe:close() end
      if stderr_pipe and not stderr_pipe:is_closing() then stderr_pipe:close() end
      if handle and not handle:is_closing() then handle:close() end
    end

    handle = vim.loop.spawn(shell_path, {
      args = { "-c", command_text },
      stdio = { nil, stdout_pipe, stderr_pipe },
      cwd = cwd,
      env = env_list,
    }, function(code, signal)
      exited = true
      close_handles()
      finalize(code == 0, code, signal, false)
    end)

    if not handle then
      finalize(false, -1, 0, false)
      return { stop = function() end }
    end

    stdout_pipe:read_start(function(err, data)
      if err then return end
      if data then table.insert(result_acc.stdout, data) end
    end)

    stderr_pipe:read_start(function(err, data)
      if err then return end
      if data then table.insert(result_acc.stderr, data) end
    end)

    local timer = vim.loop.new_timer()
    timer:start(timeout_ms, 0, function()
      if handle and not exited then
        pcall(function() handle:kill("sigterm") end)
        vim.defer_fn(function()
          if handle and not exited then
            pcall(function() handle:kill("sigkill") end)
          end
        end, 500)
        finalize(false, -1, 0, true)
      end
    end)

    return {
      stop = function()
        if handle and not exited then
          pcall(function() handle:kill("sigterm") end)
        end
      end,
    }
  end
end

--- Execute a parsed markdown shell block as produced by markdown module
-- block = { content: string, block_id: string, ... }
function Execution.execute_block(block, opts)
  opts = opts or {}
  opts.block_id = opts.block_id or (block and block.block_id)
  local content = (block and block.content) or ""
  return Execution.execute_command(content, opts)
end

return Execution
