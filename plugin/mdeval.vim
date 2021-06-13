if exists('g:mdeval_loaded') | finish | endif

let s:save_cpo = &cpo
set cpo&vim

command! MdEval lua require'mdeval'.eval_code_block()
command! MdEvalClean lua require'mdeval'.eval_clean_results()

let &cpo = s:save_cpo
unlet s:save_cpo

let g:mdeval_loaded = 1
