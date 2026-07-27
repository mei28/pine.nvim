-- pine.nvim -- pin + pane.
--
-- Keeps a second, motionless view of the current buffer so you can reference
-- one part of a file while writing in another, like freezing panes in a
-- spreadsheet. Both windows show the same buffer, so edits appear in both
-- immediately while their scroll positions stay independent.

local M = {}

local POSITIONS = {
  above = { cmd = 'aboveleft split', vertical = false },
  below = { cmd = 'belowright split', vertical = false },
  left = { cmd = 'aboveleft vsplit', vertical = true },
  right = { cmd = 'belowright vsplit', vertical = true },
}

-- Window-local options this plugin overwrites. Saved on open, restored on close.
local MANAGED_OPTS = { 'scrolloff', 'winfixheight', 'winfixbuf', 'number', 'winbar', 'winhighlight' }

local config = {
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
    -- A label line at the top of the window ('winbar'), so the two windows are
    -- tellable apart at a glance; the bar doubles as the border between them.
    -- The height above is reserved on top of it. false leaves 'winbar' alone.
    -- The text is a statusline expression, so '%f' and friends work.
    winbar = ' EDIT',
  },

  ref = {
    -- Width for vertical splits. Integer = columns, 0 < x < 1 = ratio of
    -- 'columns', nil = let Neovim split evenly. Ignored for horizontal splits.
    size = nil,
    -- 0 lets the reference window show the very top and bottom of the buffer.
    scrolloff = 0,
    -- winfixbuf: stop pickers and jumps from hijacking the reference window.
    fix_buf = true,
    -- Where the reference window points right after opening.
    start = 'cursor', -- 'cursor' | 'last_jump'
    number = nil, -- nil inherits from the edit window
    winbar = ' VIEW',
    -- Shade the reference window's background by this percentage, away from
    -- the colourscheme's own background. false or 0 leaves it alone. A
    -- transparent 'Normal' background has nothing to shade, so on those the
    -- label bar is what marks the window.
    tint = 6,
    winhl = nil, -- e.g. 'Normal:NormalNC' to dim the reference window
  },

  -- Let the mode decide which window holds the cursor: insert mode is for
  -- writing, normal mode is for reading.
  auto_focus = {
    -- Opening leaves the cursor in the reference window: you arrive in normal
    -- mode, and normal mode is for reading.
    on_open = true,
    -- Leaving insert mode parks the cursor in the reference window.
    on_insert_leave = true,
    -- Neovim cannot move the cursor to another window while insert mode is
    -- starting, so the reverse trip is done by swapping keys instead: while the
    -- reference window holds the cursor, these are re-issued in the edit window.
    -- That also keeps the reference window read-only in practice -- 'u' or 'p'
    -- there would scroll it off whatever you parked it on.
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

-- Per-tabpage state: { edit_win, ref_win, saved = { edit = {...}, ref = {...} } }
local state = {}

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == 'table' and type(dst[k]) == 'table' then
      merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

local function save_opts(win)
  local saved = {}
  for _, name in ipairs(MANAGED_OPTS) do
    saved[name] = vim.api.nvim_get_option_value(name, { win = win, scope = 'local' })
  end
  return saved
end

local function restore_opts(win, saved)
  if not saved or not vim.api.nvim_win_is_valid(win) then return end
  for _, name in ipairs(MANAGED_OPTS) do
    -- 'scrolloff' is global-local; a saved value of -1 resets it to the global one.
    vim.api.nvim_set_option_value(name, saved[name], { win = win, scope = 'local' })
  end
end

-- Returns the state for the current tabpage, dropping it if either window died.
local function current_state()
  local tab = vim.api.nvim_get_current_tabpage()
  local st = state[tab]
  if not st then return nil end
  if vim.api.nvim_win_is_valid(st.edit_win) and vim.api.nvim_win_is_valid(st.ref_win) then
    return st
  end
  state[tab] = nil
  return nil
end

local function set_opt(win, name, value)
  vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' })
end

local function tinting() return config.ref.tint and config.ref.tint > 0 end

-- Nudge a colour toward white or black, whichever it is farther from, so one
-- percentage reads as a tint on dark and light colourschemes alike.
local function shade(rgb, percent)
  local r, g, b = math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
  local target = (r * 299 + g * 587 + b * 114) / 1000 < 128 and 255 or 0
  local function mix(c) return math.floor(c + (target - c) * percent / 100 + 0.5) end
  return mix(r) * 65536 + mix(g) * 256 + mix(b)
end

-- Whether PineRefNormal exists. Remapping 'Normal' to a group that was never
-- defined would drop the foreground colour along with the background.
local tint_ready = false

-- Copy a statusline group and add bold, rather than link to it: colourschemes
-- keep those colours deliberately quiet, which is the wrong weight for a label
-- whose whole job is to be noticed. Linking would rule out the added attribute.
local function define_bar(name, source)
  local hl = vim.api.nvim_get_hl(0, { name = source, link = false })
  hl.bold = true
  hl.default = true
  vim.api.nvim_set_hl(0, name, hl)
end

-- Re-run whenever the colourscheme changes, which wipes every highlight group.
-- 'default' means a colourscheme or the user's own definition wins.
local function define_highlights()
  define_bar('PineEditBar', 'StatusLine')
  define_bar('PineRefBar', 'StatusLineNC')

  tint_ready = false
  if not tinting() then return end
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  if not normal.bg then return end
  vim.api.nvim_set_hl(0, 'PineRefNormal', {
    fg = normal.fg,
    bg = shade(normal.bg, config.ref.tint),
    default = true,
  })
  tint_ready = true
end

-- 'winhighlight' for a role, combining the label bar, the reference tint and
-- whatever the user asked for in ref.winhl. Empty means leave the option alone.
local function winhl_for(role)
  local parts = {}
  if config[role].winbar then
    local group = role == 'edit' and 'PineEditBar' or 'PineRefBar'
    parts[#parts + 1] = ('WinBar:%s,WinBarNC:%s'):format(group, group)
  end
  if role == 'ref' then
    if tint_ready then parts[#parts + 1] = 'Normal:PineRefNormal,NormalNC:PineRefNormal' end
    if config.ref.winhl then parts[#parts + 1] = config.ref.winhl end
  end
  return table.concat(parts, ',')
end

-- Nothing is written when a marker is off, so a winbar or a 'winhighlight' the
-- user set up elsewhere survives.
local function apply_marker(win, role)
  if config[role].winbar then set_opt(win, 'winbar', config[role].winbar) end
  local winhl = winhl_for(role)
  if winhl ~= '' then set_opt(win, 'winhighlight', winhl) end
end

local function apply_ref_opts(win)
  local ref = config.ref
  set_opt(win, 'scrolloff', ref.scrolloff)
  set_opt(win, 'winfixbuf', ref.fix_buf)
  if ref.number ~= nil then set_opt(win, 'number', ref.number) end
  apply_marker(win, 'ref')
end

local function apply_ref_size(win)
  local size = config.ref.size
  if not size then return end
  local width = size < 1 and math.floor(vim.o.columns * size) or math.floor(size)
  vim.api.nvim_win_set_width(win, width)
end

local function apply_edit_opts(win, vertical)
  local edit = config.edit
  apply_marker(win, 'edit')
  -- A vertical split does not divide height, so the reserved lines do not apply.
  if vertical then return end
  -- The height asked for here includes the winbar, so add a row for it to keep
  -- the reserved lines of text.
  local bar = edit.winbar and 1 or 0
  vim.api.nvim_win_set_height(win, edit.lines_above + edit.lines_below + 1 + bar)
  set_opt(win, 'scrolloff', edit.scrolloff or math.min(edit.lines_above, edit.lines_below))
  set_opt(win, 'winfixheight', edit.fix_height)
end

-- Normal-mode mappings that are live only while the reference window holds the
-- cursor. The user's own mappings for those keys are put back on removal.
local bounce_saved = nil

local function remove_bounce()
  if not bounce_saved then return end
  for key, saved in pairs(bounce_saved) do
    pcall(vim.keymap.del, 'n', key)
    if not vim.tbl_isempty(saved) then vim.fn.mapset('n', false, saved) end
  end
  bounce_saved = nil
end

local function install_bounce()
  if bounce_saved then return end
  bounce_saved = {}
  for _, key in ipairs(config.auto_focus.keys) do
    bounce_saved[key] = vim.fn.maparg(key, 'n', false, true)
    vim.keymap.set('n', key, function()
      local st = current_state()
      -- Uninstall before replaying so the replayed key cannot re-enter here.
      remove_bounce()
      if st then vim.api.nvim_set_current_win(st.edit_win) end
      local count = vim.v.count > 0 and tostring(vim.v.count) or ''
      -- 'i' puts the key at the front of the typeahead, so the rest of the
      -- keystroke lands in the edit window as well. Remapping stays on so the
      -- user's own mapping for the key still applies.
      vim.api.nvim_feedkeys(count .. vim.keycode(key), 'ti', false)
    end, { desc = 'pine: replay in the edit window' })
  end
end

-- Keep the bounce mappings alive exactly while the reference window is current.
local function sync_bounce()
  if not config.auto_focus.bounce then return end
  local st = current_state()
  if st and vim.api.nvim_get_current_win() == st.ref_win then
    install_bounce()
  else
    remove_bounce()
  end
end

local function point_at(win, lnum)
  if lnum then
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    vim.api.nvim_win_set_cursor(win, { math.min(lnum, last), 0 })
    vim.api.nvim_win_call(win, function() vim.cmd 'normal! zt' end)
  elseif config.ref.start == 'last_jump' then
    -- The '' mark is missing in a fresh buffer; leaving the cursor put is correct there.
    vim.api.nvim_win_call(win, function() pcall(vim.cmd, [[normal! '']]) end)
  end
end

-- Splitting and resizing both move the surviving window's view, and 'splitkeep'
-- decides how. Rather than depend on that global, snapshot the edit window's
-- view and put it back once the layout has settled.
local function with_view_kept(win, fn)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  fn()
  vim.api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
end

function M.is_open() return current_state() ~= nil end

--- Split the current window and turn the new one into a motionless reference view.
---@param lnum integer|nil line the reference window should show at its top
function M.open(lnum)
  if current_state() then return end
  if lnum and lnum < 1 then error(('pine: line number must be >= 1, got %d'):format(lnum)) end

  local pos = POSITIONS[config.position]
  local edit_win = vim.api.nvim_get_current_win()
  local saved_edit = save_opts(edit_win)

  local ref_win, saved_ref
  with_view_kept(edit_win, function()
    vim.cmd(pos.cmd)
    ref_win = vim.api.nvim_get_current_win()
    saved_ref = save_opts(ref_win)

    apply_ref_opts(ref_win)
    -- Width changes reflow wrapped text, so size the reference window before
    -- the edit window's view is put back.
    if pos.vertical then apply_ref_size(ref_win) end

    vim.api.nvim_set_current_win(edit_win)
    apply_edit_opts(edit_win, pos.vertical)
  end)

  -- Scrolling the reference window last keeps it from disturbing the layout
  -- the edit window just settled into.
  point_at(ref_win, lnum)

  state[vim.api.nvim_get_current_tabpage()] = {
    edit_win = edit_win,
    ref_win = ref_win,
    saved = { edit = saved_edit, ref = saved_ref },
  }

  if config.auto_focus.on_open then
    vim.api.nvim_set_current_win(ref_win)
    -- WinEnter does not fire when open() is called from an autocmd.
    sync_bounce()
  end
end

function M.close()
  local st = current_state()
  if not st then return end
  -- WinClosed restores the edit window's options and clears the state.
  with_view_kept(st.edit_win, function() vim.api.nvim_win_close(st.ref_win, false) end)
end

function M.toggle()
  if current_state() then
    M.close()
  else
    M.open()
  end
end

--- Jump between the edit window and the reference window.
function M.focus()
  local st = current_state()
  if not st then
    vim.notify('pine: no reference window is open', vim.log.levels.WARN)
    return
  end
  local target = vim.api.nvim_get_current_win() == st.ref_win and st.edit_win or st.ref_win
  vim.api.nvim_set_current_win(target)
end

--- Trade roles: edit where you were referencing, reference where you were editing.
function M.swap()
  local st = current_state()
  if not st then
    vim.notify('pine: no reference window is open', vim.log.levels.WARN)
    return
  end

  restore_opts(st.edit_win, st.saved.edit)
  restore_opts(st.ref_win, st.saved.ref)

  st.edit_win, st.ref_win = st.ref_win, st.edit_win
  st.saved = { edit = save_opts(st.edit_win), ref = save_opts(st.ref_win) }

  local vertical = POSITIONS[config.position].vertical
  with_view_kept(st.edit_win, function()
    apply_ref_opts(st.ref_win)
    if vertical then apply_ref_size(st.ref_win) end
    apply_edit_opts(st.edit_win, vertical)
  end)
  vim.api.nvim_set_current_win(st.edit_win)
end

local function on_insert_leave()
  if not config.auto_focus.on_insert_leave then return end
  local st = current_state()
  if st and vim.api.nvim_get_current_win() == st.edit_win then
    vim.api.nvim_set_current_win(st.ref_win)
    -- WinEnter does not fire for a window change made inside an autocmd.
    sync_bounce()
  end
end

local function on_win_closed(win)
  for tab, st in pairs(state) do
    if st.ref_win == win then
      remove_bounce()
      restore_opts(st.edit_win, st.saved.edit)
      -- Reached by :q on the reference window too, where nobody kept the view.
      local edit_win, view = st.edit_win, vim.api.nvim_win_call(st.edit_win, vim.fn.winsaveview)
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(edit_win) then
          vim.api.nvim_win_call(edit_win, function() vim.fn.winrestview(view) end)
        end
      end)
      state[tab] = nil
    elseif st.edit_win == win then
      remove_bounce()
      restore_opts(st.ref_win, st.saved.ref)
      state[tab] = nil
    end
  end
end

function M.setup(opts)
  merge(config, opts or {})

  if not POSITIONS[config.position] then
    error(('pine: unknown position %q (expected above/below/left/right)'):format(tostring(config.position)))
  end
  if config.ref.start ~= 'cursor' and config.ref.start ~= 'last_jump' then
    error(('pine: unknown ref.start %q (expected cursor/last_jump)'):format(tostring(config.ref.start)))
  end
  if config.ref.size and config.ref.size <= 0 then
    error(('pine: ref.size must be positive, got %s'):format(tostring(config.ref.size)))
  end
  local tint = config.ref.tint
  if tint ~= false and (type(tint) ~= 'number' or tint < 0 or tint > 100) then
    error(('pine: ref.tint must be false or a percentage 0-100, got %s'):format(tostring(tint)))
  end

  if config.splitkeep then vim.o.splitkeep = config.splitkeep end

  define_highlights()

  local group = vim.api.nvim_create_augroup('pine', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = define_highlights })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(ev) on_win_closed(tonumber(ev.match)) end,
  })
  vim.api.nvim_create_autocmd('WinEnter', { group = group, callback = sync_bounce })
  vim.api.nvim_create_autocmd('InsertLeave', { group = group, callback = on_insert_leave })

  vim.api.nvim_create_user_command('PineToggle', function() M.toggle() end, {})
  vim.api.nvim_create_user_command('PineClose', function() M.close() end, {})
  vim.api.nvim_create_user_command('PineFocus', function() M.focus() end, {})
  vim.api.nvim_create_user_command('PineSwap', function() M.swap() end, {})
  vim.api.nvim_create_user_command('PineOpen', function(a)
    local lnum
    if a.args ~= '' then
      lnum = tonumber(a.args)
      if not lnum then error(('pine: PineOpen expects a line number, got %q'):format(a.args)) end
    end
    M.open(lnum)
  end, { nargs = '?' })

  local km = config.keymaps
  if km.toggle then
    vim.keymap.set('n', km.toggle, M.toggle, { desc = 'pine: toggle the reference window' })
  end
  if km.focus then
    vim.keymap.set('n', km.focus, M.focus, { desc = 'pine: jump between edit and reference window' })
  end
  if km.swap then
    vim.keymap.set('n', km.swap, M.swap, { desc = 'pine: swap edit and reference window' })
  end
end

return M
