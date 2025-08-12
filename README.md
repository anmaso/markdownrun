# markdownrun.nvim - Neovim Plugin Foundation

A modern Neovim plugin foundation scaffold with standard layout, sensible defaults, and immediate loadability.

## Features

- Standard Neovim plugin directory structure (lua/, plugin/, doc/)
- Compatible with popular package managers (lazy.nvim, packer.nvim, etc.)
- Configurable options with sensible defaults
- Built-in command interface
- Basic help documentation

## Installation

### lazy.nvim

```lua
{
  "yourname/markdownrun.nvim",
  config = function()
    require("markdownrun").setup({
      debug = false, -- Enable debug mode
    })
  end,
}
```

### packer.nvim

```lua
use({
  "yourname/markdownrun.nvim",
  config = function()
    require("markdownrun").setup()
  end,
})
```

### Manual Installation

1. Place this repository on your runtimepath (e.g., in `~/.config/nvim/pack/plugins/start/markdownrun.nvim`)
2. Add the following to your `init.lua`:

```lua
require('markdownrun').setup()
```

## Configuration

markdownrun supports the following configuration options:

```lua
require('markdownrun').setup({
  debug = false,  -- Enable debug mode (default: false)
})
```

## Commands

- `:MarkdownRunInfo` - Show plugin information and version
- `:MarkdownRunDebug` - Show debug information including current configuration

## Requirements

- Neovim >= 0.8

## Directory Structure

```
markdownrun.nvim/
├── lua/
│   └── markdownrun/                  # Module namespace
│       ├── init.lua                  # Main plugin module
│       └── commands.lua              # Command definitions
├── plugin/
│   └── markdownrun.lua              # Plugin entry point
├── doc/
│   └── markdownrun.txt              # Help documentation
└── README.md                        # This file
```

## Development

- Main functionality in `lua/`
- Plugin initialization in `plugin/`
- Documentation in `doc/`

## Troubleshooting

### Plugin Not Loading

1. Ensure you have Neovim >= 0.8
2. Check that the plugin is properly installed in your package manager
3. Verify the setup function is called in your configuration
4. Enable debug mode to see initialization messages:

```lua
require('markdownrun').setup({ debug = true })
```

### Commands Not Available

1. Ensure the plugin has been properly loaded with `:MarkdownRunInfo`
2. Check for any error messages during plugin initialization
3. Verify your Neovim version meets requirements

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

Assisted-by: claude code
