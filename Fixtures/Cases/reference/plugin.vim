" Vim script
let s:count = 3
function! GlimtGreet(name) abort
  echo 'Hej ' . a:name
endfunction
command! -nargs=1 Greet call GlimtGreet(<q-args>)
