if vim.g.loaded_markdownrun then
  return
end
vim.g.loaded_markdownrun = true

local ok, md = pcall(require, "markdownrun")
if ok and type(md.setup) == "function" then
  -- Initialize with defaults to register basic commands
  md.setup()
end
