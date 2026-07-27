vim.opt.runtimepath:prepend(vim.fn.expand '~/Documents/pine.nvim')
vim.o.scrolloff = 5 -- mirror the user's global setting

local ok_count = 0
local function check(got, want, what)
  if got ~= want then
    error(('FAIL %s: got %s, want %s'):format(what, vim.inspect(got), vim.inspect(want)), 2)
  end
  ok_count = ok_count + 1
  print(('ok  %s = %s'):format(what, vim.inspect(got)))
end

local function localopt(win, name)
  return vim.api.nvim_get_option_value(name, { win = win, scope = 'local' })
end

local function topline(win)
  return vim.api.nvim_win_call(win, function() return vim.fn.line 'w0' end)
end

local function other_win(win)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= win then return w end
  end
end

local pine = require 'pine'
pine.setup {}

local lines = {}
for i = 1, 300 do lines[i] = ('line %d'):format(i) end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 150, 0 })

-- 1. open with the reference window parked at line 20
pine.open(20)
local wins = vim.api.nvim_tabpage_list_wins(0)
check(#wins, 2, 'window count')
check(vim.api.nvim_win_get_buf(wins[1]), vim.api.nvim_win_get_buf(wins[2]), 'both windows share a buffer')

local ref = vim.api.nvim_get_current_win()
local edit = other_win(ref)
check(localopt(ref, 'winfixbuf'), true, 'opening parks the cursor in the reference window')

check(vim.api.nvim_win_get_height(edit), 14, 'edit height (6+6+1, plus the winbar row)')
check(vim.fn.winheight(edit), 13, 'edit text rows (6+6+1) survive the winbar')
check(localopt(edit, 'scrolloff'), 6, 'edit scrolloff')
check(localopt(edit, 'winfixheight'), true, 'edit winfixheight')
check(localopt(ref, 'winfixbuf'), true, 'ref winfixbuf')
check(localopt(ref, 'scrolloff'), 0, 'ref scrolloff')

-- markers: a label bar on each window, a tint on the reference one
check(localopt(edit, 'winbar'), ' EDIT', 'edit winbar')
check(localopt(ref, 'winbar'), ' VIEW', 'ref winbar')
check(localopt(edit, 'winhighlight'), 'WinBar:PineEditBar,WinBarNC:PineEditBar', 'edit winhighlight')
check(localopt(ref, 'winhighlight'):find 'PineRefBar' ~= nil, true, 'ref winhighlight labels the bar')
check(localopt(ref, 'winhighlight'):find 'PineRefNormal' ~= nil, true, 'ref winhighlight tints Normal')
check(vim.api.nvim_win_get_cursor(edit)[1], 150, "the edit window's own cursor did not move")
check(topline(ref), 20, 'ref topline')

-- 2. moving and typing in the edit window must not move the reference view
vim.api.nvim_set_current_win(edit)
vim.api.nvim_win_set_cursor(edit, { 250, 0 })
vim.cmd 'normal! ohello'
check(topline(ref), 20, 'ref topline after editing below it')

-- 3. inserting ABOVE the reference region keeps it anchored to the same text
vim.api.nvim_buf_set_lines(0, 4, 4, false, { 'inserted A', 'inserted B' })
check(topline(ref), 22, 'ref topline shifted by the insertion above')
check(vim.api.nvim_buf_get_lines(0, topline(ref) - 1, topline(ref), false)[1], 'line 20', 'ref still shows the same text')

-- 4. reserved context: the cursor cannot get closer than 6 lines to either edge
vim.api.nvim_set_current_win(edit)
vim.api.nvim_win_set_cursor(edit, { 100, 0 })
vim.cmd 'normal! zt'
local cursor_row = vim.fn.line '.' - topline(edit)
check(cursor_row >= 6, true, ('lines above cursor (%d) >= 6'):format(cursor_row))
local below = topline(edit) + vim.api.nvim_win_get_height(edit) - 1 - vim.fn.line '.'
check(below >= 6, true, ('lines below cursor (%d) >= 6'):format(below))

-- 5. swap trades the roles
pine.swap()
check(vim.api.nvim_get_current_win(), ref, 'swap moved the cursor into the old ref window')
check(localopt(ref, 'winfixheight'), true, 'old ref window is now the edit window')
check(localopt(edit, 'winfixbuf'), true, 'old edit window is now the ref window')
check(vim.api.nvim_win_get_height(ref), 14, 'new edit height')
check(localopt(ref, 'winbar'), ' EDIT', 'the labels swapped too')
check(localopt(edit, 'winbar'), ' VIEW', 'the labels swapped too (other way)')
pine.swap()
check(vim.api.nvim_get_current_win(), edit, 'swap back')

-- 6. a foreign split must not steal the edit window's height.
-- Sized small on purpose: the headless screen is 24 rows, and 'winfixheight'
-- only holds while the layout still fits.
vim.cmd 'copen 3'
check(vim.api.nvim_win_get_height(edit), 14, 'edit height survives :copen')
check(vim.api.nvim_win_get_height(ref) < 8, true, 'the reference window absorbed the space instead')
vim.cmd 'cclose'

-- 7. close restores the edit window
pine.close()
check(#vim.api.nvim_tabpage_list_wins(0), 1, 'window count after close')
check(localopt(edit, 'scrolloff'), -1, 'scrolloff reset to the global value')
check(localopt(edit, 'winfixheight'), false, 'winfixheight restored')
check(localopt(edit, 'winbar'), '', 'winbar restored')
check(localopt(edit, 'winhighlight'), '', 'winhighlight restored')
check(vim.api.nvim_get_option_value('scrolloff', { win = edit }), 5, 'effective scrolloff is the global 5')

-- 8. closing the reference window by hand also restores the edit window
pine.open()
check(pine.is_open(), true, 'reopened')
-- open parks the cursor in the reference window, so that is the one to close
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), false)
check(pine.is_open(), false, 'state cleared after a manual close')
check(localopt(edit, 'scrolloff'), -1, 'scrolloff restored after a manual close')
check(localopt(edit, 'winfixheight'), false, 'winfixheight restored after a manual close')

-- 9. toggle is idempotent
pine.toggle()
check(#vim.api.nvim_tabpage_list_wins(0), 2, 'toggle opened')
pine.toggle()
check(#vim.api.nvim_tabpage_list_wins(0), 1, 'toggle closed')

-- 10. vertical layout
package.loaded['pine'] = nil
local pine_v = require 'pine'
pine_v.setup { position = 'right', ref = { size = 0.4 } }
pine_v.open()
check(#vim.api.nvim_tabpage_list_wins(0), 2, 'vertical window count')
local vref = vim.api.nvim_get_current_win()
local vedit = other_win(vref)
check(vim.api.nvim_win_get_width(vref), math.floor(vim.o.columns * 0.4), 'ref width = 40% of columns')
check(localopt(vedit, 'winfixheight'), false, 'height untouched for a vertical split')
check(localopt(vedit, 'scrolloff'), -1, 'scrolloff untouched for a vertical split')
pine_v.close()

-- 11. auto_focus: insert mode writes, normal mode reads
local function keys(s)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), 'x', false)
end

package.loaded['pine'] = nil
local pf = require 'pine'
pf.setup {}
vim.cmd 'only'
vim.cmd 'enew!'
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 50, 0 })
-- a user mapping the bounce mappings must hand back afterwards
vim.keymap.set('n', 'p', 'USER_P_MARKER')

pf.open(10)
local r = vim.api.nvim_get_current_win()
local e = other_win(r)
check(vim.fn.maparg('p', 'n') ~= 'USER_P_MARKER', true, 'opening handed the p mapping to the reference window')

-- typing in the edit window: Esc hands the cursor back to the reference window
vim.api.nvim_set_current_win(e)
keys 'iAAA<Esc>'
check(vim.api.nvim_get_current_win(), r, 'leaving insert parks the cursor in the reference window')
check(vim.api.nvim_buf_get_lines(0, 49, 50, false)[1], 'AAAline 50', 'the text landed in the edit window')

-- typing from the reference window bounces into the edit window
keys 'iBBB<Esc>'
check(vim.api.nvim_buf_get_lines(0, 9, 10, false)[1], 'line 10', 'the reference line is untouched')
check(vim.api.nvim_buf_get_lines(0, 49, 50, false)[1]:find 'BBB' ~= nil, true, 'the bounced text landed in the edit window')
check(vim.api.nvim_get_current_win(), r, 'and Esc parked us back in the reference window')

-- undo bounces too, so it cannot scroll the reference window away.
-- Reset to a known state with an explicit undo boundary so 'u' rolls back
-- exactly one small change near line 50.
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.cmd 'let &undolevels = &undolevels'
vim.api.nvim_set_current_win(e)
vim.api.nvim_win_set_cursor(e, { 50, 0 })
keys 'ixyz<Esc>'
vim.cmd 'let &undolevels = &undolevels'
check(vim.api.nvim_buf_get_lines(0, 49, 50, false)[1], 'xyzline 50', 'staged a one-line change')
local ref_top = topline(r)
keys 'u'
check(vim.api.nvim_buf_get_lines(0, 49, 50, false)[1], 'line 50', 'undo rolled the change back')
check(topline(r), ref_top, 'undo did not move the reference view')
check(vim.api.nvim_get_current_win(), e, 'undo ran in the edit window')
check(vim.fn.maparg('p', 'n'), 'USER_P_MARKER', 'the user mapping for p came back')

pf.close()
check(vim.fn.maparg('p', 'n'), 'USER_P_MARKER', 'the user mapping survives closing')

-- 12. auto_focus can be turned off per direction
package.loaded['pine'] = nil
local pn = require 'pine'
pn.setup { auto_focus = { on_insert_leave = false } }
pn.open(10)
local e2 = other_win(vim.api.nvim_get_current_win())
vim.api.nvim_set_current_win(e2)
keys 'iCCC<Esc>'
check(vim.api.nvim_get_current_win(), e2, 'on_insert_leave = false keeps the cursor in the edit window')
pn.close()

package.loaded['pine'] = nil
local po = require 'pine'
po.setup { auto_focus = { on_open = false } }
po.open(10)
check(localopt(vim.api.nvim_get_current_win(), 'winfixheight'), true,
  'on_open = false leaves the cursor in the edit window')
po.close()
vim.keymap.del('n', 'p')

-- 13. markers can be turned off, and then nothing is written to either option
package.loaded['pine'] = nil
local pm = require 'pine'
pm.setup { edit = { winbar = false }, ref = { winbar = false, tint = false } }
vim.cmd 'only'
vim.api.nvim_set_option_value('winbar', 'USER_BAR', { win = 0, scope = 'local' })
pm.open(10)
local r3 = vim.api.nvim_get_current_win()
local e3 = other_win(r3)
check(vim.api.nvim_win_get_height(e3), 13, 'no winbar row to reserve')
check(localopt(e3, 'winbar'), 'USER_BAR', "the user's own winbar is left alone")
-- The split inherits window-local options, so the user's winbar comes along;
-- what matters is that pine did not put a label of its own there.
check(localopt(r3, 'winbar'), 'USER_BAR', 'no label of our own on the reference window')
check(localopt(r3, 'winhighlight'), '', 'no winhighlight when nothing asks for one')
pm.close()
vim.api.nvim_set_option_value('winbar', '', { win = 0, scope = 'local' })

-- 14. invalid config fails loudly
package.loaded['pine'] = nil
local ok = pcall(function() require('pine').setup { position = 'sideways' } end)
check(ok, false, 'invalid position raises')
package.loaded['pine'] = nil
local ok_tint = pcall(function() require('pine').setup { ref = { tint = 'lots' } } end)
check(ok_tint, false, 'invalid ref.tint raises')

print(('\nall %d checks passed'):format(ok_count))
