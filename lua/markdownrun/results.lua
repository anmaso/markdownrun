local Results = {}

-- Internal utilities
local uv = vim.loop

local function notify(message, level)
  local ok = pcall(vim.notify, "[markdownrun] " .. message, level or vim.log.levels.INFO)
  if not ok then
    print("[markdownrun] " .. message)
  end
end

local function get_config()
  local ok, core = pcall(require, "markdownrun")
  if ok and type(core._config) == "table" then
    local user_cfg = (core._config.results or {})
    local defaults = {
      inline_limit_lines = 100,
      base_dir = nil,
      retention = { max_days = nil, max_entries = nil },
    }
    return vim.tbl_deep_extend("force", defaults, user_cfg)
  end
  return { inline_limit_lines = 100, base_dir = nil, retention = { max_days = nil, max_entries = nil } }
end

local function path_dirname(path)
  return vim.fn.fnamemodify(path, ":p:h")
end

local function path_basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function join_paths(a, b)
  if not a or a == "" then return b end
  if not b or b == "" then return a end
  local sep = package.config:sub(1,1)
  if a:sub(-1) == sep then
    return a .. b
  else
    return a .. sep .. b
  end
end

local function ensure_dir(path)
  local ok = uv.fs_mkdir(path, 493) -- 0755
  if ok or (not ok and string.match(tostring(ok or ""), "EEXIST")) then
    return true
  end
  -- Some luv builds return nil, err, name; try second arg
  local _, err = uv.fs_mkdir(path, 493)
  if err and err:match("EEXIST") then return true end
  return not err
end

local function read_file(path)
  local fd, err = uv.fs_open(path, "r", 420)
  if not fd then return nil, err end
  local stat = uv.fs_fstat(fd)
  local data = ""
  if stat and stat.size and stat.size > 0 then
    data = uv.fs_read(fd, stat.size, 0) or ""
  end
  uv.fs_close(fd)
  return data, nil
end

local function write_file_atomic(target_path, data)
  local dir = path_dirname(target_path)
  ensure_dir(dir)
  local tmp = string.format("%s.tmp.%d.%d", target_path, uv.getpid(), uv.hrtime())
  local fd, err = uv.fs_open(tmp, "w", 420) -- 0644
  if not fd then return false, err or "open tmp failed" end
  local ok_write, errw = uv.fs_write(fd, data, 0)
  if not ok_write then
    uv.fs_close(fd)
    uv.fs_unlink(tmp)
    return false, errw or "write failed"
  end
  uv.fs_close(fd)
  local ok_ren, errm = uv.fs_rename(tmp, target_path)
  if not ok_ren then
    uv.fs_unlink(tmp)
    return false, errm or "rename failed"
  end
  return true, nil
end

local function json_encode(value)
  -- Step 1: compact JSON
  local compact
  if vim.json and vim.json.encode then
    local ok, s = pcall(vim.json.encode, value)
    if ok and s then compact = s end
  end
  if not compact then
    local ok2, s2 = pcall(vim.fn.json_encode, value)
    if ok2 and s2 then compact = s2 end
  end
  if not compact then return tostring(value) end

  -- Step 2: pretty via jq if available
  local ok_exe, is_exec = pcall(vim.fn.executable, "jq")
  if ok_exe and tonumber(is_exec) == 1 then
    local pretty = vim.fn.system({ "jq", "." }, compact)
    if vim.v.shell_error == 0 and type(pretty) == "string" and #pretty > 0 then
      return pretty
    end
  end
  -- Fallback: compact JSON
  return compact
end

local function json_decode(text)
  if vim.json and vim.json.decode then
    local ok, val = pcall(vim.json.decode, text)
    if ok then return val end
  end
  local ok2, val2 = pcall(vim.fn.json_decode, text)
  if ok2 then return val2 end
  return nil
end

local function iso8601_utc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function sha256(text)
  return vim.fn.sha256(text or "")
end

local function random_hex(n)
  local t = {}
  for _ = 1, n do
    t[#t+1] = string.format("%x", math.random(0, 15))
  end
  return table.concat(t)
end

local function short_id(block_id)
  if type(block_id) == "string" and #block_id >= 8 then
    return string.sub(block_id, 1, 8)
  end
  return random_hex(8)
end

local function contains_nul(s)
  return s and s:find("%z") ~= nil
end

local function split_lines(s)
  local lines = {}
  s = s or ""
  for line in (s .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  return lines
end

local function sidecar_paths(markdown_path)
  local cfg = get_config()
  local dir = path_dirname(markdown_path)
  local base = markdown_path
  if cfg.base_dir and cfg.base_dir ~= "" then
    -- mirror flat into base_dir using file basename
    ensure_dir(cfg.base_dir)
    base = join_paths(cfg.base_dir, path_basename(markdown_path))
  end
  return base .. ".result.json", base .. ".result.json.lock", base .. ".results"
end

local function acquire_lock(lock_path, timeout_ms)
  timeout_ms = timeout_ms or 2000
  local start = uv.hrtime()
  local backoff = 20
  while true do
    local fd = uv.fs_open(lock_path, "wx", 420) -- exclusive create
    if fd then
      uv.fs_close(fd)
      return true
    end
    local elapsed_ms = math.floor((uv.hrtime() - start) / 1e6)
    if elapsed_ms >= timeout_ms then
      return false, "timeout"
    end
    uv.sleep(backoff)
    if backoff < 200 then backoff = math.min(200, math.floor(backoff * 1.5)) end
  end
end

local function release_lock(lock_path)
  uv.fs_unlink(lock_path)
end

local function load_existing_results(results_path, markdown_path)
  local content = nil
  local ok_read, err = pcall(function()
    local data = read_file(results_path)
    content = data
  end)
  if not ok_read or not content or content == "" then
    return { version = 1, file = markdown_path, executions = {} }
  end
  local decoded = json_decode(content)
  if type(decoded) ~= "table" then
    return { version = 1, file = markdown_path, executions = {} }
  end
  -- Ensure required root fields
  decoded.version = decoded.version or 1
  decoded.file = decoded.file or markdown_path
  decoded.executions = decoded.executions or {}
  return decoded
end

local function write_artifact(artifact_dir, ts, block_short, kind, data)
  ensure_dir(artifact_dir)
  local ext = kind == "stdout" and "out" or (kind == "stderr" and "err" or "bin")
  local filename = string.format("%s_%s.%s", ts:gsub("[:TZ-]", ""), block_short, ext)
  local path = join_paths(artifact_dir, filename)
  local ok, err = write_file_atomic(path, data or "")
  if not ok then
    notify("Failed to write artifact: " .. tostring(err), vim.log.levels.WARN)
    return nil
  end
  return path
end

--- Public: return sidecar paths for a given markdown file
-- @return results_path, lock_path, artifacts_dir
function Results.get_sidecar_paths(markdown_path)
  return sidecar_paths(markdown_path)
end

--- Public: read results document for a markdown file
function Results.read_doc(markdown_path)
  local results_path = sidecar_paths(markdown_path)
  if type(results_path) == 'table' then results_path = results_path[1] end
  return load_existing_results(results_path, markdown_path)
end

--- Public: return latest execution entry per block_id
function Results.get_latest_by_block_id(markdown_path)
  local doc = Results.read_doc(markdown_path)
  local map = {}
  for _, e in pairs(doc.executions or {}) do
    if e.block_id then map[e.block_id] = e end
  end
  return map
end

--- Append an execution result to the sidecar results file for the given markdown.
-- markdown_path: absolute path to markdown file
-- block: table with fields block_id, start_line, end_line, lang, content_hash (optional)
-- result: table with fields command, code, duration_ms, stdout, stderr, cwd, timed_out, shell
function Results.append_block_execution(markdown_path, block, result)
  if not markdown_path or markdown_path == "" then
    notify("append_block_execution called without markdown_path", vim.log.levels.WARN)
    return false
  end

  local results_path, lock_path, artifacts_dir = sidecar_paths(markdown_path)

  local ts = iso8601_utc()
  local block_short = short_id(block and block.block_id)

  -- Decide inline vs artifact
  local cfg = get_config()
  local out_lines = split_lines(result.stdout or "")
  local err_lines = split_lines(result.stderr or "")

  local out_is_binary = contains_nul(result.stdout)
  local err_is_binary = contains_nul(result.stderr)

  local stdout_repr
  local stderr_repr
  local artifacts = { stdout_file = nil, stderr_file = nil, binary_files = {} }

  if out_is_binary or (#out_lines > cfg.inline_limit_lines) then
    local p = write_artifact(artifacts_dir, ts, block_short, out_is_binary and "bin" or "stdout", result.stdout or "")
    stdout_repr = { type = "file", path = p }
    if out_is_binary and p then table.insert(artifacts.binary_files, p) end
    artifacts.stdout_file = p
  else
    stdout_repr = { type = "inline", value = out_lines }
  end

  if err_is_binary or (#err_lines > cfg.inline_limit_lines) then
    local p = write_artifact(artifacts_dir, ts, block_short, err_is_binary and "bin" or "stderr", result.stderr or "")
    stderr_repr = { type = "file", path = p }
    if err_is_binary and p then table.insert(artifacts.binary_files, p) end
    artifacts.stderr_file = p
  else
    stderr_repr = { type = "inline", value = err_lines }
  end

  local entry = {
    id = string.format("%s-%s", ts:gsub("[:TZ-]", ""), random_hex(6)),
    timestamp = ts,
    block_id = block and block.block_id or nil,
    start_line = block and block.start_line or nil,
    end_line = block and block.end_line or nil,
    lang = block and block.lang or nil,
    command = result.command,
    exit_code = tonumber(result.code) or (result.ok and 0 or -1),
    duration_ms = tonumber(result.duration_ms) or nil,
    cwd = result.cwd,
    env_delta = {},
    stdout = stdout_repr,
    stderr = stderr_repr,
    artifacts = artifacts,
    content_hash = block and block.content_hash or nil,
  }

  local ok_lock, err_lock = acquire_lock(lock_path, 2000)
  if not ok_lock then
    notify("Could not acquire results lock: " .. tostring(err_lock), vim.log.levels.WARN)
    return false
  end

  local ok, err = pcall(function()
    local doc = load_existing_results(results_path, markdown_path)

    -- Executions stored as object keyed by block_id
    doc.executions = doc.executions or {}
    local key = block and block.block_id or sha256(result.command or "")
    doc.executions[key] = entry

    -- Retention policy: drop older entries and delete their artifacts
    local cfg = get_config()
    local max_entries = cfg.retention and tonumber(cfg.retention.max_entries) or nil
    local max_days = cfg.retention and tonumber(cfg.retention.max_days) or nil

    local function should_keep(e, now)
      if max_days and max_days > 0 then
        -- Compare ISO timestamps; convert to epoch by parsing (rough: os.time may not parse ISOZ). Fallback to keep.
        -- Expect format YYYY-MM-DDTHH:MM:SSZ
        local y, m, d, H, M, S = e.timestamp:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
        if y then
          local epoch = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(H), min = tonumber(M), sec = tonumber(S), isdst = false })
          local age_days = (now - epoch) / (24*60*60)
          if age_days > max_days then return false end
        end
      end
      return true
    end

    local now = os.time()
    -- Retention policy for map: sort by timestamp and keep newest
    local values = {}
    for k, e in pairs(doc.executions) do
      if should_keep(e, now) then
        table.insert(values, { key = k, entry = e })
      end
    end
    table.sort(values, function(a, b)
      return tostring(a.entry.timestamp) < tostring(b.entry.timestamp)
    end)
    if max_entries and max_entries > 0 and #values > max_entries then
      local to_delete = {}
      for i = 1, #values - max_entries do table.insert(to_delete, values[i]) end
      for _, item in ipairs(to_delete) do
        local e = item.entry
        if e.stdout and e.stdout.type == 'file' and e.stdout.path then pcall(uv.fs_unlink, e.stdout.path) end
        if e.stderr and e.stderr.type == 'file' and e.stderr.path then pcall(uv.fs_unlink, e.stderr.path) end
        if e.artifacts and e.artifacts.binary_files then
          for _, p in ipairs(e.artifacts.binary_files) do pcall(uv.fs_unlink, p) end
        end
        doc.executions[item.key] = nil
      end
    end

    local json_text = json_encode(doc)
    local okw, errw = write_file_atomic(results_path, json_text)
    if not okw then error(errw or "write failed") end
  end)

  release_lock(lock_path)

  if not ok then
    notify("Failed to persist results: " .. tostring(err), vim.log.levels.WARN)
    return false
  end

  return true
end

--- Prune results to only include current block_ids; delete artifacts for removed entries
-- keep_ids: table as set where keep_ids[block_id] = true
function Results.prune_to_block_ids(markdown_path, keep_ids)
  local results_path, lock_path = sidecar_paths(markdown_path)
  local removed = 0
  local ok_lock = acquire_lock(lock_path, 2000)
  if not ok_lock then
    notify("Could not acquire results lock for prune", vim.log.levels.WARN)
    return 0, false
  end

  local ok, err = pcall(function()
    local doc = load_existing_results(results_path, markdown_path)
    doc.executions = doc.executions or {}
    for key, e in pairs(vim.deepcopy(doc.executions)) do
      if not keep_ids[key] then
        -- delete artifacts if any
        if e.stdout and e.stdout.type == 'file' and e.stdout.path then pcall(uv.fs_unlink, e.stdout.path) end
        if e.stderr and e.stderr.type == 'file' and e.stderr.path then pcall(uv.fs_unlink, e.stderr.path) end
        if e.artifacts and e.artifacts.binary_files then
          for _, p in ipairs(e.artifacts.binary_files) do pcall(uv.fs_unlink, p) end
        end
        doc.executions[key] = nil
        removed = removed + 1
      end
    end
    local json_text = json_encode(doc)
    local okw, errw = write_file_atomic(results_path, json_text)
    if not okw then error(errw or "write failed") end
  end)

  release_lock(lock_path)

  if not ok then
    notify("Failed to prune results: " .. tostring(err), vim.log.levels.WARN)
    return 0, false
  end

  return removed, true
end

--- Public: read artifact file content (helper for commands)
function Results.read_artifact(path)
  local data, err = read_file(path)
  if not data then return nil, err end
  return data, nil
end

--- Public: get latest entry for a given block id
function Results.get_latest_entry(markdown_path, block_id)
  local doc = Results.read_doc(markdown_path)
  if not doc.executions then return nil end
  return doc.executions[block_id]
end

return Results
