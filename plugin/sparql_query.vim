" plugin/sparql_query.vim
if exists('g:loaded_sparql_query_plugin')
  finish
endif
let g:loaded_sparql_query_plugin = 1

" :SparqlQuery -> interactive prompt (delegates fully to Lua)
command! SparqlQuery lua require('sparql_query').prompt_and_run()

" :SparqlExec <endpoint> <query...>
" Example:
"   :SparqlExec http://localhost:5820/mydb "SELECT ?s WHERE { ?s ?p ?o } LIMIT 5"
command! -nargs=* SparqlExec call s:RunSparqlExec(<f-args>)

function! s:RunSparqlExec(...) abort
  if a:0 < 2
    echom "Usage: :SparqlExec <endpoint> <query>"
    return
  endif

  " first arg is endpoint
  let l:args = a:000
  let l:endpoint = remove(l:args, 0)

  " remaining args (possibly many) are the query - join with spaces
  let l:query = join(l:args, ' ')

  " call Lua safely, quoting both endpoint and query
  execute 'lua require("sparql_query").exec_and_show(' . string(l:query) . ', { endpoint = ' . string(l:endpoint) . ' })'
endfunction

function! s:RunSparqlExecFile(...) abort
  if a:0 != 2
    echom "Usage: :SparqlExecFile <endpoint> <file>"
    return
  endif

  let l:endpoint = a:1
  let l:file = a:2

  if !filereadable(l:file)
    echom "File not found: " . l:file
    return
  endif

  " Call Lua and pass endpoint and file path
  execute 'lua require("sparql_query").exec_file('
        \ . string(l:endpoint) . ', ' . string(l:file) . ')'
endfunction

" :SparqlExecFile <endpoint> <file>
" Usage: :SparqlExecFile http://localhost:5820/mydb /path/to/query.sparql
command! -nargs=* SparqlExecFile call s:RunSparqlExecFile(<f-args>)

" :SparqlWithConfig -> pick a config, prompt for a query, run with that config
command! SparqlWithConfig lua require('sparql_query').prompt_and_run_with_config()

" optionally also provide a command to choose and run the last-config without UI
command! SparqlLastConfig lua require('sparql_query').choose_config({ prefer_last = true, auto_select = true }, function(cfg) if cfg then vim.notify("Selected config: "..cfg.name) end end)

" range-aware command: use a visual selection or specify a range
" Usage:
"   - visual select lines then :SparqlWithConfigRange
"   - or :1,10SparqlWithConfigRange
command! -range SparqlWithConfigRange lua require('sparql_query').run_with_config_from_range(<line1>, <line2>)
