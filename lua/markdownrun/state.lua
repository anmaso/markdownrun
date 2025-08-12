local State = {}

local function notify(message, level)
  local ok = pcall(vim.notify, "[markdownrun] " .. message, level or vim.log.levels.INFO)
  if not ok then
    print("[markdownrun] " .. message)
  end
end

local sessions_by_file = {}

local function deepcopy(tbl)
  return vim.deepcopy(tbl)
end

local function get_buf_path(bufnr)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == '' then return nil end
  return vim.fn.fnamemodify(name, ":p")
end

local function dirname(path)
  return vim.fn.fnamemodify(path, ":p:h")
end

local function is_abs(path)
  local sep = package.config:sub(1,1)
  if sep == '\\' then
    return path:match('^%a:[\\/]') or path:match('^[\\/]')
  else
    return path:sub(1,1) == '/'
  end
end

local function join_paths(a, b)
  if not a or a == '' then return b end
  if not b or b == '' then return a end
  local sep = package.config:sub(1,1)
  if a:sub(-1) == sep then return a .. b end
  return a .. sep .. b
end

local function expand_home(path)
  if not path or path == '' then return path end
  if path:sub(1,1) == '~' then
    return vim.fn.expand(path)
  end
  return path
end

local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function initial_env()
  local env = {}
  local e = vim.fn.environ()
  for k, v in pairs(e) do env[k] = v end
  return env
end

local function ensure_session_for_file(file_path)
  local s = sessions_by_file[file_path]
  if s then return s end
  s = {
    file = file_path,
    cwd = dirname(file_path),
    env = initial_env(),
  }
  sessions_by_file[file_path] = s
  return s
end

function State.get_session(bufnr)
  local file_path = get_buf_path(bufnr)
  if not file_path then
    -- Fallback to current working dir; use a synthetic key
    local key = vim.loop.cwd() .. '::nofile'
    if not sessions_by_file[key] then
      sessions_by_file[key] = { file = key, cwd = vim.loop.cwd(), env = initial_env() }
    end
    return sessions_by_file[key]
  end
  return ensure_session_for_file(file_path)
end

function State.reset_session(bufnr)
  local file_path = get_buf_path(bufnr)
  if not file_path then
    -- reset synthetic
    local key = vim.loop.cwd() .. '::nofile'
    sessions_by_file[key] = { file = key, cwd = vim.loop.cwd(), env = initial_env() }
    notify("Session reset (nofile)")
    return
  end
  sessions_by_file[file_path] = { file = file_path, cwd = dirname(file_path), env = initial_env() }
  notify("Session reset for " .. vim.fn.fnamemodify(file_path, ":t"))
end

local function substitute_env_vars(value, env)
  local out = value or ''
  out = out:gsub("%${([%w_]+)}", function(name)
    return env[name] or ''
  end)
  out = out:gsub("%$([%w_]+)", function(name)
    return env[name] or ''
  end)
  return out
end

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function unquote(s)
  if (s:sub(1,1) == '"' and s:sub(-1) == '"') or (s:sub(1,1) == "'" and s:sub(-1) == "'") then
    return s:sub(2, -2)
  end
  return s
end

--- Parse the block content and apply environment and cwd changes to the session (fast path)
-- Recognizes leading assignments, export statements, and cd commands at line starts
function State.parse_and_apply(block_content, session)
  if not session then return end
  local env = session.env
  for line in (block_content or ''):gmatch("(.-)\n") do
    local l = trim(line)
    if l ~= '' and not l:match('^#') then
      -- cd commands
      local cd_arg = l:match('^cd%s+([^;|&]+)')
      if cd_arg then
        cd_arg = trim(cd_arg)
        cd_arg = unquote(cd_arg)
        cd_arg = expand_home(cd_arg)
        local new_cwd = is_abs(cd_arg) and cd_arg or join_paths(session.cwd, cd_arg)
        session.cwd = normalize_path(new_cwd)
      end

      -- export VAR=VALUE
      local export_k, export_v = l:match('^export%s+([A-Za-z_][A-Za-z0-9_]*)=(.+)$')
      if export_k and export_v then
        export_v = trim(unquote(export_v))
        export_v = substitute_env_vars(export_v, env)
        env[export_k] = export_v
      end

      -- bare assignment VAR=VALUE
      local k, v = l:match('^([A-Za-z_][A-Za-z0-9_]*)=(.+)$')
      if k and v then
        v = trim(unquote(v))
        v = substitute_env_vars(v, env)
        env[k] = v
      end
    end
  end
end

function State.get_summary(bufnr)
  local s = State.get_session(bufnr)
  local env_count = 0
  for _ in pairs(s.env) do env_count = env_count + 1 end
  return string.format("CWD: %s | %d env vars", tostring(s.cwd), env_count), deepcopy(s)
end

return State
