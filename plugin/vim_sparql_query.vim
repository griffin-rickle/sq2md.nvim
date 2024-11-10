let s:plugin_root_dir = fnamemodify(resolve(expand('<sfile>:p')), ':h')
python3 import vim_sparql_query.vsq as vsq

function! NewQuery()
    python3 vsq.new_query()
endfunction

function! PrintError(job_id, data, event)
    echo "Error! Error!"
    echo a:data
endfunction

function! PrintResults(job_id, data, event)
    call ClearQueryResults()
    call appendbufline('QueryResults', 0, a:data)
    execute("normal gg")
endfunction

function! GetPythonExecutable()
    if filereadable($HOME."/.pyenv/shims/python3")
        return $HOME."/.pyenv/shims/python3"
    endif
    return 'python3'
endfunction

function! ClearQueryResults()
    if bufwinnr("QueryResults") < 0
        call bufnr("QueryResults", 1)
        execute("sb QueryResults")
    endif
    execute(bufwinnr("QueryResults") .. 'wincmd w')
    execute("normal ggdG")
    call setbufvar('QueryResults', '&buftype', 'nofile')
    call setbufvar('QueryResults', '&wrap', 0)
endfunction



let s:python_executable = GetPythonExecutable()
function! BufferQuery()
    let s:job_id = jobstart([g:python3_host_prog, s:plugin_root_dir . '/../python3/vim_sparql_query/vsq.py'], {'stdin': 'pipe', 'stdout_buffered': 1, 'on_stdout':function('PrintResults'), 'on_stderr': function('PrintError')})
    for s:query_line in getline(1, '$')
        call chansend(s:job_id, s:query_line . '\n')
    endfor
    call chanclose(s:job_id, 'stdin')
endfunction

command! -nargs=0 BufferQuery call BufferQuery()
command! -nargs=0 NewQuery call NewQuery()

