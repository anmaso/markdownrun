local markdown = require('markdownrun.markdown')

local function create_buf_with_lines(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function assert_true(cond, msg)
  if not cond then
    error(msg or 'assert failed')
  end
end

local function test_basic_blocks()
  local lines = {
    "# Title",
    "",
    "```sh",
    "echo one",
    "```",
    "",
    "Some text",
    "",
    "```bash",
    "echo two",
    "```",
    "",
    "```",
    "echo three",
    "```",
  }
  local buf = create_buf_with_lines(lines)
  local blocks = markdown.get_shell_blocks(buf)
  assert_true(#blocks == 3, 'expected 3 blocks, got ' .. #blocks)
  assert_true(blocks[1].content:match('echo one'), 'block1 content')
  assert_true(blocks[2].content:match('echo two'), 'block2 content')
  assert_true(blocks[3].content:match('echo three'), 'block3 content')

  -- Cursor inside second block
  local current = markdown.get_current_block(buf, 10 - 1) -- line 10 (1-based), index 9 (0-based)
  assert_true(current and current.content:match('echo two'), 'current block detection failed')

  -- IDs should be hashes and stable for same content
  assert_true(#blocks[1].content_hash > 0 and blocks[1].content_hash == blocks[1].block_id, 'hash/id expectations')
end

local function test_nested_blocks()
  local lines = {
    "- list item",
    "  - nested",
    "    ```sh",
    "    echo nested",
    "    ```",
    "> quote",
    "> ```",
    "> echo quoted",
    "> ```",
  }
  local buf = create_buf_with_lines(lines)
  local blocks = markdown.get_shell_blocks(buf)
  assert_true(#blocks == 2, 'expected 2 nested/quoted blocks, got ' .. #blocks)
  assert_true(blocks[1].content:match('nested'), 'nested content')
  assert_true(blocks[2].content:match('quoted'), 'quoted content')
end

local ok, err = pcall(function()
  test_basic_blocks()
  test_nested_blocks()
end)

if not ok then
  print('FAIL: ' .. tostring(err))
  os.exit(1)
else
  print('OK: markdown tests passed')
end
