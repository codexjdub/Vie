; Vie's additions to Neovim's Markdown highlights (Vendor/nvim-treesitter), which come first.

; Code in a fenced block has its own language's colors, and the text color elsewhere.
(code_fence_content) @none

; Finished tasks are dimmed and struck through.
(list_item
  (task_list_marker_checked)
  (paragraph) @comment @markup.strikethrough)
