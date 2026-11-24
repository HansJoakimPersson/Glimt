" Greeting command for the current buffer.
let s:greeting = 'Hello'

function! Greet(name)
  echo s:greeting . ' ' . a:name
endfunction
