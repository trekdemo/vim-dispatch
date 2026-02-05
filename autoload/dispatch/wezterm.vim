" dispatch.vim wezterm strategy
"
" This handler requires running inside wezterm terminal.
" See https://wezterm.org/cli/cli/index.html

if exists('g:autoloaded_dispatch_wezterm')
  finish
endif
let g:autoloaded_dispatch_wezterm = 1

let s:waiting = {}

" -----------------------------------------------------------------------------
" Public handler interface

function! dispatch#wezterm#handle(request) abort
  if empty($WEZTERM_PANE) || !executable('wezterm')
    return 0
  endif

  if a:request.action ==# 'make'
    return s:make(a:request)
  elseif a:request.action ==# 'start'
    return s:start(a:request)
  endif
endfunction

function! dispatch#wezterm#activate(pid) abort
  let pane_id = s:find_pane_by_pid(a:pid)
  if !empty(pane_id)
    call system('wezterm cli activate-pane --pane-id ' . pane_id)
    return !v:shell_error
  endif
  return 0
endfunction

" -----------------------------------------------------------------------------
" Private implementation of the "wezterm" handler

" Handle: :Start, :Spawn
function! s:start(request) abort
  let cmd = s:wezterm_spawn_cmd('tab', a:request, dispatch#prepare_start(a:request))

  let output = system(cmd)
  let pane_id = matchstr(output, '^\d\+$')

  if !empty(pane_id)
    call s:restore_focus_and_set_title(pane_id, a:request.title, a:request.background)
  endif
  return 1
endfunction

" Handle: :Dispatch, :Make
function! s:make(request) abort
  let qf_height = get(g:, 'dispatch_quickfix_height', 10)
  if get(a:request, 'background', 0) || (qf_height <= 0 && dispatch#has_callback())
    let type = 'tab'
  else
    let type = 'split'
  endif

  let cmd_with_capturing = a:request.expanded .
                      \ '; echo ' . dispatch#status_var() . ' > ' . a:request.file . '.complete' .
                      \ '; wezterm cli get-text --pane-id $WEZTERM_PANE --start-line -999999 > ' . a:request.file

  let cmd = s:wezterm_spawn_cmd(type, a:request, dispatch#prepare_start(a:request, cmd_with_capturing, 'make'))
  let output = system(cmd)
  let pane_id = matchstr(output, '^\d\+$')

  if !empty(pane_id)
    call s:restore_focus_and_set_title(pane_id, a:request.title, 1)
    let s:waiting[pane_id] = a:request
    return 1
  endif
endfunction

" https://wezterm.org/cli/cli/index.html
function! s:wezterm_spawn_cmd(type, request, command) abort
  if a:type ==# 'tab'
    let cmd = 'wezterm cli spawn'
  else
    let cmd = 'wezterm cli split-pane --bottom'
    let percent = get(g:, 'dispatch_wezterm_percent', 30)
    if percent != 0
      let cmd .= ' --percent=' . percent
    endif
  endif

  let cmd .= ' --cwd ' . shellescape(a:request.directory)
  return cmd . ' -- sh -c ' . shellescape(a:command)
endfunction

function! s:restore_focus_and_set_title(pane_id, title, restore_focus) abort
  call system('wezterm cli set-tab-title --pane-id ' . a:pane_id . ' ' . shellescape(a:title))

  if a:restore_focus
    call system('wezterm cli activate-pane --pane-id ' . $WEZTERM_PANE)
  endif
endfunction

function! s:find_pane_by_pid(pid) abort
  let list_output = system('wezterm cli list --format json')
  if v:shell_error
    return ''
  endif
  " Parse JSON to find pane with matching pid
  " Format: [{"pane_id": 1, "...": "...", "pid": 12345}, ...]
  let pattern = '"pane_id":\s*\(\d\+\)[^}]*"pid":\s*' . a:pid . '\>'
  let match = matchlist(list_output, pattern)
  if !empty(match)
    return match[1]
  endif
  " Try reverse order (pid before pane_id)
  let pattern = '"pid":\s*' . a:pid . '\>[^}]*"pane_id":\s*\(\d\+\)'
  let match = matchlist(list_output, pattern)
  if !empty(match)
    return match[1]
  endif
  return ''
endfunction

" Section: Without callback - polling

function! s:poll() abort
  if empty(s:waiting)
    return
  endif

  for [pane_id, request] in items(s:waiting)
    if !s:wezterm_pane_exists(pane_id)
      call remove(s:waiting, pane_id)
      call dispatch#complete(request)
    endif
  endfor
endfunction

function! s:wezterm_pane_exists(pane_id) abort
  let output = system('wezterm cli list')
  return output =~# '\<' . a:pane_id . '\>'
endfunction

augroup dispatch_wezterm
  autocmd!
  autocmd VimResized * nested if !dispatch#has_callback() | call s:poll() | endif
augroup END
