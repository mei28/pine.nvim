# pine.nvim

**pin** + **pane** = **pine**. Not a colorscheme.

Freeze one part of a file on screen while you write in another part of the same
file, the way you freeze rows in a spreadsheet.

Writing long prose means constantly looking back: at a section you wrote an hour
ago, at an outline near the top, at a paragraph you are about to contradict.
With a single window you either scroll away from what you are writing, or you
type and lose the place you were reading. `pine.nvim` splits the current window
onto the same buffer and sizes the halves so that both stay usable:

```
┌──────────────────────────────────────┐
│▓ VIEW▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  ← a label bar marks each window
│ ## Chapter 1                         │
│ the passage you want to keep reading │  ← does not move while you type
│ ...                                  │
│▓ EDIT▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
│ ## Chapter 3                         │
│ what you are writing now             │
│ cursor█                              │  ← a fixed number of lines of context
└──────────────────────────────────────┘  ← is always kept around the cursor
```

Both windows show the *same buffer*, so edits appear in both immediately, while
their scroll positions stay independent.

## Install

lazy.nvim:

```lua
{
  'mei28/pine.nvim',
  keys = { '<Leader>p', '<Leader>P' },
  cmd = { 'PineToggle', 'PineOpen', 'PineClose', 'PineFocus', 'PineSwap' },
  config = function()
    require('pine').setup {}
  end,
}
```

## Usage

| Mapping / command | What it does |
| --- | --- |
| `<Leader>p` / `:PineToggle` | Open or close the reference window |
| `<Leader>P` / `:PineFocus` | Jump between the edit window and the reference window |
| `:PineOpen [lnum]` | Open with the reference window parked at a line |
| `:PineClose` | Close the reference window |
| `:PineSwap` | Trade roles: edit where you were referencing, and vice versa |

The typical loop is `<Leader>p` to split, which leaves you in the reference
window; navigate to whatever you want to keep in view, then `i` or `a` to start
writing — that lands in the edit window on its own. Everything after that
happens in the edit window and the reference view stays put.

## Focus follows the mode

By default the mode decides which window holds the cursor: **insert mode is for
writing, normal mode is for reading**.

- Opening leaves the cursor in the reference window, since you arrive in normal
  mode. Scroll around to park it on what you want to keep in view.
- Leaving insert mode parks the cursor in the reference window, so `Esc` is how
  you go look something up.
- `i` `a` `o` and friends pressed in the reference window jump to the edit
  window first and start insert there, so `Esc` … read … `a` is a complete
  round trip without a window command.

Neovim cannot move the cursor to another window while insert mode is starting,
so that second half is done by swapping a small set of normal-mode keys while
the reference window has the cursor. The same mechanism keeps the reference
window read-only in practice: `u`, `p` and `.` are replayed in the edit window
rather than firing where you parked your reading position, which is what would
otherwise scroll it away.

The catch is that plain normal-mode editing of your own text no longer happens
where you left off — after `Esc` the cursor is elsewhere. Press `<Leader>P` to
go back to the edit window in normal mode, or turn the behaviour off:

```lua
auto_focus = { on_open = false }          -- open leaves the cursor where it is
auto_focus = { on_insert_leave = false }  -- Esc keeps the cursor where it is
auto_focus = { bounce = false }           -- no key swapping at all
```

## Telling the two windows apart

Both windows show the same buffer in the same colours, so by default pine marks
them two ways. Neither is a real border: Neovim draws those around floating
windows only, and these are ordinary splits.

- A label bar across the top of each window, reading `EDIT` or `VIEW`.
  It also serves as the line between them.
- A shade of difference in the reference window's background, `ref.tint`
  percent away from the colourscheme's own. It needs an opaque `Normal`
  background; with a transparent one the label bar is what marks the window.

Three highlight groups drive that, all defined with `default` so a colourscheme
or your own `:highlight` wins:

| Group | Default | What it colours |
| --- | --- | --- |
| `PineEditBar` | `StatusLine` plus bold | the edit window's label bar |
| `PineRefBar` | `StatusLineNC` plus bold | the reference window's label bar |
| `PineRefNormal` | `Normal` shaded by `ref.tint` | the reference window's background |

Colourschemes keep the statusline colours quiet, which is the wrong weight for a
label whose job is to be noticed. If the bars still do not carry on yours, give
them a colour of their own:

```lua
vim.api.nvim_set_hl(0, 'PineEditBar', { fg = '#1a1b26', bg = '#7aa2f7', bold = true })
vim.api.nvim_set_hl(0, 'PineRefBar', { fg = '#1a1b26', bg = '#565f89', bold = true })
```

Turn either marker off, or both:

```lua
edit = { winbar = false },              -- no label bars, and the edit window
ref = { winbar = false, tint = false }, -- goes back to lines_above+lines_below+1
```

The label text is a statusline expression, so `winbar = ' %f'` and friends work.

## Configuration

Defaults:

```lua
require('pine').setup {
  -- Where the reference window goes: 'above' | 'below' | 'left' | 'right'.
  position = 'above',

  edit = {
    -- Screen lines kept visible around the cursor in the edit window.
    -- With 'wrap' on these count wrapped screen lines, not buffer lines.
    lines_above = 6,
    lines_below = 6,
    -- nil means min(lines_above, lines_below), which is what actually
    -- guarantees the reserved lines stay on screen while moving the cursor.
    scrolloff = nil,
    -- Keep the edit window's height when other windows open (quickfix, etc).
    fix_height = true,
    -- A label line at the top of the window ('winbar'). The height above is
    -- reserved on top of it. false leaves 'winbar' alone.
    winbar = ' EDIT',
  },

  ref = {
    -- Width for vertical splits. Integer = columns, 0 < x < 1 = ratio of
    -- 'columns', nil = let Neovim split evenly. Ignored for horizontal splits.
    size = nil,
    -- 0 lets the reference window show the very top and bottom of the buffer.
    scrolloff = 0,
    -- Stop pickers and jumps from hijacking the reference window ('winfixbuf').
    fix_buf = true,
    -- Where the reference window points right after opening.
    start = 'cursor', -- 'cursor' | 'last_jump'
    number = nil,     -- nil inherits from the edit window
    winbar = ' VIEW',
    -- Shade the reference window's background by this percentage, away from
    -- the colourscheme's own background. false or 0 leaves it alone.
    tint = 6,
    winhl = nil,      -- e.g. 'Normal:NormalNC' to dim the reference window
  },

  auto_focus = {
    -- Opening leaves the cursor in the reference window: you arrive in normal
    -- mode, and normal mode is for reading.
    on_open = true,
    -- Leaving insert mode parks the cursor in the reference window.
    on_insert_leave = true,
    -- Replay insert-starting and buffer-changing keys in the edit window when
    -- they are pressed in the reference window.
    bounce = true,
    -- Deliberately no operators ('c', 'd', 'y'): mapping those would make
    -- multi-key mappings like 'dw' wait for 'timeoutlen' on every press.
    keys = { 'i', 'I', 'a', 'A', 'o', 'O', 'gi', 's', 'S', 'R', 'p', 'P', 'u', '<C-r>', '.' },
  },

  keymaps = {
    toggle = '<Leader>p',
    focus = '<Leader>P',
    swap = nil,
  },

  -- Passed straight to the global 'splitkeep'. nil leaves it alone, which is
  -- the default: pine restores the edit window's view itself, so it has no
  -- reason to change a global that affects every other split.
  splitkeep = nil,
}
```

### Sizing

For a horizontal split (`above` / `below`), the edit window holds
`lines_above + lines_below + 1` lines of text and the reference window takes the
rest. `'scrolloff'` is set to `min(lines_above, lines_below)` in the edit window,
which is what actually keeps those lines on screen as the cursor moves. With
`edit.winbar` on the window is one row taller than that, since the label bar
takes a row of its own.

For a vertical split (`left` / `right`), height is not divided, so
`lines_above` / `lines_below` do nothing. Use `ref.size` to set the width.

`edit.fix_height` sets `'winfixheight'`, so opening a quickfix list or a
terminal takes space from the reference window instead of the edit window.
Neovim only honours that while the layout still fits; on a very short screen
every window gets squeezed, edit window included.

### Reading a different file in the reference window

`ref.fix_buf = true` pins the reference window to the current buffer, which is
the point for same-file reference. Set it to `false` if you also want to pull
other files into that window.

## Requirements

Neovim 0.10+ (`'winfixbuf'`).

## Tests

```sh
nvim -u NONE --headless -l test/run.lua
```

## License

MIT
