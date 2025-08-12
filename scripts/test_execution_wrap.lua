local exec = require('markdownrun.execution')

local function run_block(text)
  local done = false
  local result
  exec.execute_command(text, {
    bufnr = 0,
    on_complete = function(res)
      result = res
      done = true
    end,
  })
  vim.wait(2000, function() return done end, 50)
  return result
end

local tests = {
  { name = 'simple echo', text = 'echo hello', expect_ok = true },
  { name = 'multiline with comment', text = '# comment\nexport VAR=1\necho $VAR', expect_ok = true },
  { name = 'cd change', text = 'cd /\npwd', expect_ok = true },
}

local failed = 0
for _, t in ipairs(tests) do
  local res = run_block(t.text)
  if not res then
    print('FAIL: no result for ' .. t.name)
    failed = failed + 1
  else
    local ok = res.ok and not res.timed_out
    if ok ~= t.expect_ok then
      print('FAIL: ' .. t.name .. ' exit=' .. tostring(res.code) .. ' stderr=' .. tostring(res.stderr))
      failed = failed + 1
    else
      print('OK: ' .. t.name .. ' exit=' .. tostring(res.code))
    end
  end
end

if failed > 0 then
  os.exit(1)
else
  print('All tests passed')
end
