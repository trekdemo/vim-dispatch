" dispatch.vim rex strategy
"
" This handler requires Vim to run inside a Rex terminal, with the rex CLI on
" the PATH.  See https://www.superlogical.com/rex/docs/automate/cli

if exists('g:autoloaded_dispatch_rex')
  finish
endif
let g:autoloaded_dispatch_rex = 1

let s:waiting = {}

" -----------------------------------------------------------------------------
" Public handler interface

function! dispatch#rex#handle(request) abort
  if empty($REX_BLOCK) || !executable('rex')
    return 0
  endif

  if a:request.action ==# 'make'
    return s:make(a:request)
  elseif a:request.action ==# 'start'
    return s:start(a:request)
  endif
endfunction

" Started blocks label themselves with the pid of their shell, see s:start().
function! dispatch#rex#activate(pid) abort
  call system('rex focus ' . shellescape(s:label(a:pid)))
  return !v:shell_error
endfunction

" -----------------------------------------------------------------------------
" Private implementation of the "rex" handler

" Handle: :Start, :Spawn
function! s:start(request) abort
  let script = dispatch#isolate(a:request, [],
        \ dispatch#set_title(a:request),
        \ dispatch#prepare_start(a:request))
  " Rename before exec, so $$ is the pid that prepare_start() writes.
  let rename = shellescape(exepath('rex')) . ' block rename "$REX_BLOCK" ' . s:label('$$')

  let cmd = 'rex run --cwd ' . shellescape(a:request.directory)
  if a:request.background
    let cmd .= ' --focus=false'
  endif
  let cmd .= ' -- sh -c ' . shellescape(rename . ' >/dev/null 2>&1; exec ' . script)

  call system(cmd)
  return !v:shell_error
endfunction

" Handle: :Dispatch, :Make
function! s:make(request) abort
  let script = dispatch#isolate(a:request, [],
        \ 'echo $$ > ' . a:request.file . '.pid',
        \ a:request.expanded)

  let qf_height = get(g:, 'dispatch_quickfix_height', 10)
  if get(a:request, 'background', 0) || (qf_height <= 0 && dispatch#has_callback())
    let cmd = 'rex run'
  else
    let cmd = 'rex split -b ' . shellescape($REX_BLOCK) . ' --split=below'
    let cmd .= ' --ratio ' . get(g:, 'dispatch_rex_ratio', 30)
  endif
  " Keep the block open after the command exits, so s:watch() can capture it.
  let cmd .= ' --focus=false --keep-open --json'
  let cmd .= ' --cwd ' . shellescape(a:request.directory)
  let cmd .= ' --label ' . shellescape(a:request.title)
  let cmd .= ' -- sh -c ' . shellescape('exec ' . script)

  let output = system(cmd)
  let block_id = matchstr(output, '"block_ids":\_s*\[\_s*"\zs[^"]\+')

  if !empty(block_id)
    call s:watch(block_id, a:request)
    let s:waiting[block_id] = a:request
    return 1
  endif
endfunction

" Waits for the command in the background, then captures the block's output
" into the request's file and closes the block.
function! s:watch(block_id, request) abort
  let rex = shellescape(exepath('rex'))
  let block = shellescape(a:block_id)
  let file = shellescape(a:request.file)
  let complete = shellescape(a:request.file . '.complete')

  let script = rex . ' wait ' . block . ' >/dev/null 2>&1; status=$?; ' .
        \ rex . ' capture -b ' . block . ' --trim --unwrap > ' . file . '; ' .
        \ 'echo $status > ' . complete . '; ' .
        \ rex . ' block close ' . block
  let callback = dispatch#callback(a:request)
  if !empty(callback)
    let script .= '; ' . callback
  endif

  call system('sh -c ' . shellescape(script) . ' >/dev/null 2>&1 &')
endfunction

function! s:label(pid) abort
  return 'dispatch-' . a:pid
endfunction

" Section: Without callback - polling

function! s:poll() abort
  if empty(s:waiting)
    return
  endif

  for [block_id, request] in items(s:waiting)
    if filereadable(request.file . '.complete')
      call remove(s:waiting, block_id)
      call dispatch#complete(request)
    endif
  endfor
endfunction

augroup dispatch_rex
  autocmd!
  autocmd VimResized * nested if !dispatch#has_callback() | call s:poll() | endif
augroup END
