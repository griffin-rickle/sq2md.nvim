local M = {}

function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do M.config[k] = v end
end

local function parse_csv_line(line)
  local res = {}
  local field = ""
  local in_quotes = false
  for i = 1, #line do
    local c = line:sub(i,i)
    if c == '"' then
      in_quotes = not in_quotes
    elseif c == ',' and not in_quotes then
      table.insert(res, field)
      field = ""
    else
      field = field .. c
    end
  end
  table.insert(res, field)
  return res
end

local function split_line(line, sep)
  sep = sep or ","  -- default to comma
  if sep == "," then
    return parse_csv_line(line)  -- handle quoted CSV
  else
    return vim.split(line, sep)
  end
end

local function tsv_to_markdown(tsv_text, sep)
  sep = sep or "\t"
  -- Parse TSV into a table of rows
  local rows = {}
  for _, line in ipairs(vim.split(tsv_text, "\n", { trimempty = true })) do
    table.insert(rows, split_line(line, sep))
  end
  if #rows == 0 then return {} end

  local n_cols = #rows[1]

  -- Compute max width per column
  local col_widths = {}
  for i = 1, n_cols do col_widths[i] = 0 end
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do
      local cell_width = vim.fn.strdisplaywidth(cell)
      col_widths[i] = math.max(col_widths[i], cell_width)
    end
  end

  -- Helper to pad a string
  local function pad(str, width)
    local padding = width - vim.fn.strdisplaywidth(str)
    return str .. string.rep(" ", padding)
  end

  -- Build Markdown lines
  local md_lines = {}

  -- Header row
  local header = {}
  for i, cell in ipairs(rows[1]) do
    table.insert(header, pad(cell, col_widths[i]))
  end
  table.insert(md_lines, "| " .. table.concat(header, " | ") .. " |")

  -- Separator row
  local sep = {}
  for i = 1, n_cols do
    table.insert(sep, string.rep("-", col_widths[i]))
  end
  table.insert(md_lines, "| " .. table.concat(sep, " | ") .. " |")

  -- Data rows
  for r = 2, #rows do
    local row_line = {}
    for i, cell in ipairs(rows[r]) do
      table.insert(row_line, pad(cell, col_widths[i]))
    end
    table.insert(md_lines, "| " .. table.concat(row_line, " | ") .. " |")
  end

  return md_lines
end

-- result window / buffer reuse helpers
M._result_bufnr = M._result_bufnr or nil
M._result_winid = M._result_winid or nil

-- Open or reuse the result buffer and window. Returns bufnr.
local function open_or_reuse_result_window(ft, title)
  -- if buffer exists and valid, reuse it; otherwise create a new scratch buffer
  local bufnr = M._result_bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = vim.api.nvim_create_buf(false, true) -- listed=false, scratch (unlisted) buffer
    M._result_bufnr = bufnr
    -- set buffer-local options
    vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  end

  -- if the buffer is already displayed in a window, focus that window
  local winid = vim.fn.bufwinid(bufnr)
  if winid and winid ~= -1 then
    vim.api.nvim_set_current_win(tonumber(winid))
    M._result_winid = tonumber(winid)
  else
    -- not displayed: open a new top split and set the buffer into it
    vim.cmd("topleft new")                  -- open new horizontal split at top
    local curwin = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(curwin, bufnr) -- show our buffer in that window
    M._result_winid = curwin
  end

  -- set filetype and buffer name (optional)
  if ft then pcall(vim.api.nvim_buf_set_option, bufnr, "filetype", ft) end
  if title then pcall(vim.api.nvim_buf_set_name, bufnr, title) end

  return bufnr
end

-- Try to call plenary.curl if present; returns (err, response)
local function call_plenary(url, body, headers, opts, callback)
  local ok, curl = pcall(require, "plenary.curl")
  if not ok or not curl then return nil end
  opts = opts or {}
  local method = opts.method or "POST"
  local curl_opts = {
    body = body,
    headers = headers,
    timeout = opts.timeout or M.config.timeout,
    callback = function(response)
      -- plenary's callback runs in a different thread; use vim.schedule to forward
      vim.schedule(function() callback(nil, response) end)
    end
  }
  if method == "GET" then
    curl.get(url, curl_opts)
  else
    curl.post(url, curl_opts)
  end
  return true
end

-- fallback: use curl CLI via jobstart
local function call_curl_cli(url, body, headers, opts, callback)
  opts = opts or {}
  local cmd = { "curl", "-sS", "-X", opts.method or "POST" }
  -- add headers
  for k, v in pairs(headers or {}) do
    table.insert(cmd, "-H")
    table.insert(cmd, string.format("%s: %s", k, v))
  end
  -- data
  if body and body ~= "" then
    table.insert(cmd, "--data-binary")
    table.insert(cmd, body)
  end
  -- timeout
  if opts.timeout then
    table.insert(cmd, "--max-time")
    table.insert(cmd, tostring(opts.timeout))
  end
  table.insert(cmd, url)

  local out = {}
  local err = {}
  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then vim.list_extend(out, data) end
    end,
    on_stderr = function(_, data)
      if data then vim.list_extend(err, data) end
    end,
    on_exit = function(_, code)
      local resp = {
        status = code,
        body = table.concat(out, "\n"),
        stderr = table.concat(err, "\n"),
        raw = out,
      }
      if code ~= 0 then
        vim.schedule(function() callback(resp.stderr ~= "" and resp.stderr or ("exit code " .. tostring(code)), resp) end)
      else
        vim.schedule(function() callback(nil, resp) end)
      end
    end,
  })

  if job <= 0 then
    callback("failed to start curl", nil)
  end
end

-- generic HTTP POST helper that picks plenary if available
local function http_post(url, body, headers, opts, callback)
  opts = opts or {}
  -- try plenary
  local used_plenary = call_plenary(url, body, headers, opts, callback)
  if used_plenary then return end
  -- fallback to curl CLI
  call_curl_cli(url, body, headers, opts, callback)
end

-- Build SPARQL endpoint URL: server + "/" + db + "/query" when db provided,
-- otherwise use provided endpoint directly.
local function build_query_url(endpoint, db)
  if not endpoint then return nil end
  if db and db ~= "" then
    -- strip trailing slash from endpoint
    local ep = endpoint:gsub("/+$", "")
    return string.format("%s/%s/query", ep, db)
  end
  return endpoint
end

-- Execute SPARQL query; opts may contain: endpoint, db, accept, user, pass, format, timeout
-- callback(err, response_table)
function M.execute(query, opts, callback)
  opts = opts or {}
  callback = callback or function() end

  local endpoint = opts.endpoint or M.config.endpoint
  if not endpoint then
    return callback("no SPARQL endpoint configured", nil)
  end
  local db = opts.db
  local url = build_query_url(endpoint, db)
  if not url then return callback("no URL built", nil) end

  local headers = {
    ["Accept"] = opts.accept or M.config.accept,
    ["Content-Type"] = "application/sparql-query"
  }
  -- Basic Auth header if provided (pass user/pass)
  local user = opts.user or M.config.user
  local pass = opts.pass or M.config.pass
  if user and pass then
    local b64 = vim.fn.systemlist({"bash", "-lc", "printf '%s:%s' " .. vim.fn.shellescape(user) .. " " .. vim.fn.shellescape(pass) .. " | base64"})[1] or ""
    if b64 and b64 ~= "" then headers["Authorization"] = "Basic " .. b64 end
  end

  local body = query
  local http_opts = { method = "POST", timeout = opts.timeout or M.config.timeout }
  http_post(url, body, headers, http_opts, function(err, resp)
    if err then return callback(err, resp) end
    return callback(nil, resp)
  end)
end

function show_result(lines, ft, title)
  ft = ft or "text"
  title = title or "SPARQL Result"

  vim.schedule(function()
    -- open / reuse buffer & window
    local bufnr = open_or_reuse_result_window(ft, title)

    -- update contents (replace all lines)
    -- use set_lines: start=0 end=-1 replacement
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)

    -- keep window focus on results (optional). If you prefer to return focus to previous window, save/restore it.
    -- Here we leave focus in the result window. To restore focus, capture previous winid before calling open_or_reuse and set it back.
  end)
end

-- Convenience: run query and show results in buffer. Attempts to pretty-print JSON.
-- opts same as execute; if opts.format == "csv"/"tsv" will treat as plain table.
function M.exec_and_show(query, opts)
  opts = opts or {}
  M.execute(query, opts, function(err, resp)
    if err then
      show_result({ "ERROR: " .. tostring(err) }, "text", "SPARQL Error")
      return
    end
    local accept = (opts.accept or M.config.accept):lower()
    vim.notify(accept, vim.log.levels.INFO)
    if accept:find("json") then
      -- try to decode and pretty-print with jq if available
      local ok, decoded = pcall(vim.fn.json_decode, resp.body)
      if ok and decoded then
        local pretty = nil
        if vim.fn.executable("jq") == 1 then
          -- use systemlist to pretty print
          local lines = vim.fn.systemlist({ "jq", "." }, resp.body)
          if vim.v.shell_error == 0 then pretty = table.concat(lines, "\n") end
        end
        pretty = pretty or vim.fn.json_encode(decoded)
        show_result(vim.split(pretty, "\n"), "json", "SPARQL JSON")
        return
      else
        -- not JSON-decodable: show raw
        show_result(vim.split(resp.body or "", "\n"), "text", "SPARQL Result")
        return
      end
    else
        if accept == "text/tab-separated-values"
            or accept:match("tab%-separated%-values") then
            sep = "\t"
        elseif accept == "text/csv"
                or accept:match("csv") then
            sep = ","
        end
        if sep then
            -- TSV or CSV
            ft = "md"
            lines = tsv_to_markdown(resp.body or "", sep)
            show_result(lines, "markdown", "SPARQL Markdown Table")
        else
            local ft = "text"
            show_result(resp.raw or vim.split(resp.body or "", "\n"), ft, "SPARQL Result")
        end
    end
  end)
end

-- interactive prompt: ask endpoint (optional), then query, then run
function M.prompt_and_run()
  local endpoint_default = M.config.endpoint or ""
  local prompt_ep = "SPARQL endpoint (leave empty to use default): "
  vim.ui.input({ prompt = prompt_ep, default = endpoint_default }, function(ep)
    ep = (ep == nil or ep == "") and endpoint_default or ep
    if not ep or ep == "" then
      vim.notify("No endpoint supplied", vim.log.levels.ERROR)
      return
    end
    vim.ui.input({ prompt = "SPARQL> " }, function(q)
      if not q or q == "" then return end
      M.exec_and_show(q, { endpoint = ep })
    end)
  end)
end

-- Read a query from a file and execute it. endpoint is required.
-- Usage: require('sq2md').exec_file(endpoint, file_path, opts)
function M.exec_file(endpoint, file_path, opts)
  if not endpoint or endpoint == "" then
    vim.notify("sq2md.exec_file: endpoint required", vim.log.levels.ERROR)
    return
  end
  if not file_path or file_path == "" then
    vim.notify("sq2md.exec_file: file path required", vim.log.levels.ERROR)
    return
  end

  local f, err = io.open(file_path, "r")
  if not f then
    vim.notify("Cannot open file: " .. tostring(file_path) .. " (" .. tostring(err) .. ")", vim.log.levels.ERROR)
    return
  end

  local query = f:read("*a")
  f:close()

  -- Merge opts with endpoint so exec_and_show sees endpoint
  opts = opts or {}
  opts.endpoint = opts.endpoint or endpoint

  -- Reuse existing exec_and_show to run and display the query
  M.exec_and_show(query, opts)
end

local uv = vim.loop
local api = vim.api
local fn = vim.fn

-- where we persist last-used selection
local function state_path()
  return fn.stdpath('data') .. '/sparql_query_state.json'
end

-- load persisted state { last = "name" }
local function load_state()
  local path = state_path()
  local f = io.open(path, "r")
  if not f then return {} end
  local ok, contents = pcall(function() return f:read("*a") end)
  f:close()
  if not ok or not contents or contents == "" then return {} end
  local ok2, tbl = pcall(fn.json_decode, contents)
  if ok2 and type(tbl) == "table" then return tbl end
  return {}
end

-- save state table
local function save_state(state)
  local path = state_path()
  local dir = fn.fnamemodify(path, ':h')
  pcall(fn.mkdir, dir, 'p')
  local f, err = io.open(path, "w")
  if not f then
    vim.notify("Could not write sparql state: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  f:write(fn.json_encode(state))
  f:close()
end

-- config validation: ensure required fields exist
local function valid_config(cfg)
  if type(cfg) ~= "table" then return false, "config must be a table" end
  if not cfg.name or type(cfg.name) ~= "string" then return false, "config.name required" end
  if not cfg.endpoint or type(cfg.endpoint) ~= "string" then return false, "config.endpoint required" end
  return true
end

-- Public API: set configs (call from user init)
-- expected: { { name="local", endpoint="http://...", db="mydb", user=..., pass=..., accept=... , default=true }, ... }
function M.setup(opts)
  opts = opts or {}
  M.config = M.config or {}
  -- merge top-level options
  for k, v in pairs(opts) do
    if k ~= "configs" then M.config[k] = v end
  end

  -- configs: list -> map and keep order
  M._configs_list = {}
  M._configs_map = {}
  if type(opts.configs) == "table" then
    for _, cfg in ipairs(opts.configs) do
      local ok, err = valid_config(cfg)
      if not ok then
        vim.notify("sparql_query setup: invalid config '" .. tostring(cfg.name) .. "': " .. tostring(err), vim.log.levels.WARN)
      else
        table.insert(M._configs_list, cfg)
        M._configs_map[cfg.name] = cfg
      end
    end
  end
end

-- Helper: return list of display items for picker
local function build_display_list()
  local list = {}
  for i, cfg in ipairs(M._configs_list or {}) do
    local label = cfg.name
    local meta = {}
    if cfg.default then table.insert(meta, "default") end
    if cfg.db then table.insert(meta, cfg.db) end
    if cfg.user then table.insert(meta, cfg.user) end
    local suffix = ""
    if #meta > 0 then suffix = " [" .. table.concat(meta, ", ") .. "]" end
    table.insert(list, { name = cfg.name, label = label .. suffix, cfg = cfg })
  end
  return list
end

-- Public: fetch config by name
function M.get_config(name)
  return (M._configs_map and M._configs_map[name]) or nil
end

-- choose: interactive selection with default/last heuristics
-- opts:
--   prefer_last (bool) - auto-select last-used if true and exists
--   allow_none (bool) - if true, allow cancel (return nil)
function M.choose_config(opts, callback)
  opts = opts or {}
  callback = callback or function() end

  local list = build_display_list()
  if #list == 0 then
    vim.notify("No sparql_query configs defined. Use require('sparql_query').setup{ configs = {...} }", vim.log.levels.ERROR)
    return callback(nil)
  end

  -- try to choose default, then last if prefer_last
  local state = load_state()
  local last = state.last
  local pick_index = nil

  -- if user set a default config, choose that first
  for i, item in ipairs(list) do
    if item.cfg.default then
      pick_index = i
      break
    end
  end

  -- if prefer last and last exists, use last (override default choice)
  if opts.prefer_last and last then
    for i, item in ipairs(list) do
      if item.name == last then pick_index = i break end
    end
  end

  -- if we already have a pick and prefer auto-selection, call back immediately
  if pick_index and opts.auto_select then
    local chosen = list[pick_index].cfg
    -- persist last
    save_state({ last = chosen.name })
    return callback(chosen)
  end

  -- user interactive choice
  local choices = {}
  for _, it in ipairs(list) do table.insert(choices, it.label) end

  vim.ui.select(choices, { prompt = "Select SPARQL config:" }, function(choice, idx)
    if not choice then
      -- user cancelled
      return callback(nil)
    end
    local chosen = list[idx].cfg
    -- persist last-used
    local st = load_state()
    st.last = chosen.name
    save_state(st)
    callback(chosen)
  end)
end

function M.get_query_contents(start_line, end_line)
  -- convert to numbers (may be nil when called from other code)
  local bufnr = 0
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)

  start_line = tonumber(start_line)
  end_line = tonumber(end_line)

  -- if both nil, default to whole buffer
  if not start_line and not end_line then
    start_line = 1
    end_line = buf_line_count
  else
    -- if one is missing, fallback sensibly
    start_line = start_line or 1
    end_line = end_line or buf_line_count
  end

  -- detect the current cursor line and editor mode
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local mode = vim.fn.mode()

  -- If start==end==cursor line and user is NOT in visual mode, assume "no range given" -> use whole buffer
  if start_line == end_line and start_line == cur_line and not (mode == 'v' or mode == 'V' or mode == '\22') then
    start_line = 1
    end_line = buf_line_count
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  query = table.concat(lines, "\n")
  query = query:gsub("\r\n", "\n")

  if query:match("^%s*$") then
    vim.notify("Selected range is empty", vim.log.levels.WARN)
    return
  end

  return query
end

function M.run_with_last_config(start_line, end_line)
  local st = load_state()
  local last = st.last
  local cfg = nil
  if last and M._configs_map then cfg = M._configs_map[last] end
  query_content = M.get_query_contents(start_line, end_line)
  if not cfg then
    vim.notify("No previously used configuration detected")
    M.choose_config({ prefer_last = true }, function(cfg)
      if not cfg then return end
      M.exec_and_show(query_content, cfg)
    end)
  else
    M.exec_and_show(query_content, cfg)
  end
end

function M.choose_config_and_run(start_line, end_line)

  M.choose_config({ prefer_last = true }, function(cfg)
    if not cfg then return end
    query_content = M.get_query_contents(start_line, end_line)

    M.exec_and_show(query_content, cfg)
  end)
end

-- initialize defaults on module load
M._configs_list = M._configs_list or {}
M._configs_map = M._configs_map or {}

return M
