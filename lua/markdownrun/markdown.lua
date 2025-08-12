local M = {}

local function notify(message, level)
  local ok = pcall(vim.notify, "[markdownrun] " .. message, level or vim.log.levels.INFO)
  if not ok then
    print("[markdownrun] " .. message)
  end
end

local function is_shell_language(lang)
  if not lang or lang == "" then
    return true
  end
  lang = string.lower(lang)
  return lang == "sh" or lang == "bash"
end

local function strip_prefixes(line)
  -- Remove common Markdown structural prefixes (blockquote, list items)
  local s = line
  local changed = true
  while changed do
    changed = false
    s = s:gsub("^%s+", function(m)
      if #m > 0 then changed = true end
      return ""
    end)
    -- Blockquote '>'
    s = s:gsub("^>+%s*", function(m)
      if #m > 0 then changed = true end
      return ""
    end)
    -- Unordered list markers '-', '*', '+' (optionally repeating nesting)
    s = s:gsub("^[-*+]%s+", function(m)
      if #m > 0 then changed = true end
      return ""
    end)
    -- Ordered list markers like '1.' or '23)'
    s = s:gsub("^%d+[.)]%s+", function(m)
      if #m > 0 then changed = true end
      return ""
    end)
  end
  return s
end

local function parse_fence_header(header)
  -- header is text after structural prefixes
  -- Match ``` or ```lang
  local fence, lang = header:match("^(```+)%s*([%w_-]*)%s*$")
  if fence then
    return fence, lang
  end
  fence, lang = header:match("^(```+)%s*([%w_-]*)")
  if fence then
    return fence, lang
  end
  return nil, nil
end

local function is_fence_close(text, open_fence)
  -- Close is a line that starts with at least as many backticks
  local fence = text:match("^(```+)%s*$")
  if fence and #fence >= #open_fence then
    return true
  end
  return false
end

local function compute_hash(text)
  -- Use built-in Vim sha256 for stable hashing
  return vim.fn.sha256(text)
end

local function normalize_content(lines)
  -- Normalize line endings and trailing whitespace for stable content hash
  local normalized = {}
  for _, l in ipairs(lines) do
    table.insert(normalized, (l:gsub("%s+$", "")))
  end
  return table.concat(normalized, "\n") .. "\n"
end

-- Public: Return list of shell blocks in buffer
-- Each block: { start_line=number, end_line=number, lang=string|nil, content=string, content_hash=string, block_id=string }
function M.get_shell_blocks(bufnr)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}

  local i = 1 -- Lua 1-based for iterating over lines
  local open_fence = nil
  local open_lang = nil
  local block_start = nil

  while i <= #lines do
    local raw = lines[i]
    local text = strip_prefixes(raw)

    if not open_fence then
      local fence, lang = parse_fence_header(text)
      if fence then
        open_fence = fence
        open_lang = lang or ""
        block_start = i -- 1-based start fence line index
        -- If it's not a shell block, we still need to find the closing fence but won't record it
      end
    else
      local close_text = strip_prefixes(raw)
      if is_fence_close(close_text, open_fence) then
        local start_content = block_start + 1
        local end_content = i - 1
        if is_shell_language(open_lang) then
          local content_lines = {}
          if start_content <= end_content then
            for li = start_content, end_content do
              table.insert(content_lines, lines[li])
            end
          end
          local content = normalize_content(content_lines)
          local content_hash = compute_hash(content)
          -- block_id stable unless content changes
          local block_id = content_hash
          table.insert(blocks, {
            start_line = start_content - 1, -- 0-based for Neovim APIs
            end_line = end_content - 1,
            lang = open_lang ~= "" and open_lang or nil,
            content = content,
            content_hash = content_hash,
            block_id = block_id,
          })
        end
        -- Reset state after closing
        open_fence = nil
        open_lang = nil
        block_start = nil
      end
    end
    i = i + 1
  end

  return blocks
end

-- Public: Return the current shell block for cursor position
-- Returns block table or nil
function M.get_current_block(bufnr, cursor_line)
  bufnr = bufnr or 0
  local line = cursor_line
  if line == nil then
    local pos = vim.api.nvim_win_get_cursor(0) -- {line, col}, 1-based
    line = pos[1] - 1
  end
  local blocks = M.get_shell_blocks(bufnr)
  for _, b in ipairs(blocks) do
    if b.start_line <= line and line <= b.end_line then
      return b
    end
  end
  return nil
end

function M.notify_not_in_runnable_block()
  notify("Cursor is not within a runnable shell code block", vim.log.levels.WARN)
end

return M
