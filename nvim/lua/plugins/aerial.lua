-- Override AstroNvim's snapshot pin (aerial.nvim ^2.2), which is incompatible
-- with Neovim 0.12 (TSNode:start() removed -> "attempt to call method 'start'").
-- Latest aerial (v4+) uses node:range() and requires nvim >= 0.12.
return {
  "stevearc/aerial.nvim",
  version = false,
}
