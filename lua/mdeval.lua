local defaults = require("defaults")

local vim = vim
local api = vim.api
local fn = vim.fn

local M = {}

local function code_block_start()
  return defaults.lang_conf[vim.bo.filetype][1]
end

local function code_block_end()
  return defaults.lang_conf[vim.bo.filetype][2]
end

-- A wrapper to execute commands throught WSL on Windows.
local function get_command(cmd)
  if vim.loop.os_uname().version:match("Windows") then
    return string.format("wsl %s", prefix, cmd)
  end
  return cmd
end

local function create_tmp_build_dir()
  local handle = io.popen(
    get_command(string.format("mkdir -p %s 2>&1", M.opts.tmp_build_dir))
  )
  handle:close()
end

-- Exclude long temporary directory name from the output.
-- @param out Table containing lines from the output.
local function sanitize_output(temp_filename, out)
  assert(temp_filename ~= nil)
  temp_filename = temp_filename:gsub("-", "%%-")
  for k, v in pairs(out) do
    out[k] = v:gsub(temp_filename, "temp")
  end
  return out
end

-- Wraps command inside the "timeout" call.
local function get_timeout_command(cmd, timeout)
  if vim.loop.os_uname().sysname == "Darwin" then
    timeout_cmd = "gtimeout"
  else
    timeout_cmd = "timeout"
  end
  return get_command(
    string.format("%s %d sh -c '%s' 2>&1", timeout_cmd, timeout, cmd)
  )
end

local function run_compiler(command, extension, temp_filename, code, timeout)
  assert(command ~= nil)
  local filepath = string.format("%s/%s", M.opts.tmp_build_dir, temp_filename)
  local src_filepath = string.format("%s.%s", filepath, extension)
  local a_out_filepath = string.format("%s.out", filepath)

  local f = io.open(src_filepath, "w")
  f:write(code)
  f:close()

  -- Remove temp files left over from the previous compilation.
  local handle =
    io.popen(get_command(string.format("rm -f %s 2>&1", a_out_filepath)))
  handle:close()

  local handle = io.popen(
    get_command(
      string.format(
        "%s %s -o %s 2>&1; echo $?",
        table.concat(command, " "),
        src_filepath,
        a_out_filepath
      )
    )
  )
  local result = {}
  local lastline
  for line in handle:lines() do
    result[#result + 1] = line
    lastline = line
  end
  if #result > 0 then
    table.remove(result, #result)
  end
  if tonumber(lastline) ~= 0 then
    result = sanitize_output(filepath, result)
    return result, false
  end

  if timeout ~= -1 then
    handle = io.popen(get_timeout_command(a_out_filepath, timeout))
  else
    handle = io.popen(get_command(string.format("%s 2>&1", a_out_filepath)))
  end
  result = {}
  for line in handle:lines() do
    result[#result + 1] = line
  end
  handle:close()

  return result, true
end

local function run_interpreter(command, extension, temp_filename, code, timeout)
  assert(command ~= nil)
  local filepath = string.format("%s/%s", M.opts.tmp_build_dir, temp_filename)
  local src_filepath = string.format("%s.%s", filepath, extension)

  local f = io.open(src_filepath, "w")
  f:write(code)
  f:close()

  local cmd = string.format("%s %s", table.concat(command, " "), src_filepath)
  local handle
  if timeout ~= -1 then
    handle = io.popen(get_timeout_command(cmd, timeout))
  else
    handle = io.popen(get_command(string.format("%s 2>&1", cmd)))
  end
  local result = {}
  local lastline
  for line in handle:lines() do
    result[#result + 1] = line
    lastline = line
  end

  return result, true
end

-- Finds the appropriate language entry in the options tables and its name.
-- Returns {nil, nil} if no appropriate entry found.
local function find_lang_options(lang_code)
  local lang_name = nil
  local lang_options = nil
  for name, opts in pairs(M.opts.eval_options) do
    if type(opts.language_code) == "table" then
      for _, code in pairs(opts.language_code) do
        if code == lang_code then
          lang_name = name
          lang_options = opts
          break
        end
      end
    elseif opts.language_code == lang_code then
      lang_name = name
      lang_options = opts
      break
    end
  end
  return lang_name, lang_options
end

local function eval_code(lang_name, lang_options, temp_filename, code, timeout)
  create_tmp_build_dir()

  -- Prepend generated code with the default_header.
  if lang_options.default_header then
    code = lang_options.default_header .. "\n" .. code
  end

  if lang_options.exec_type == "compiled" then
    return run_compiler(
      lang_options.command,
      lang_options.extension,
      temp_filename,
      code,
      timeout
    )
  elseif lang_options.exec_type == "interpreted" then
    return run_interpreter(
      lang_options.command,
      lang_options.extension,
      temp_filename,
      code,
      timeout
    )
  end

  if lang.exec_type == nil then
    error(string.format("Execution type for %s unset.", lang_name))
    error("Please set one of the: compiled and interpreted one.")
  else
    error(
      string.format(
        "Unknown execution type for %s: %s",
        lang_name,
        lang.exec_type
      )
    )
  end

  return nil, false
end

local function generate_temp_filename(buffer_name, start_pos, end_pos)
  local basename = buffer_name:match("^.+/(.+)$")
  -- Allow only alphanumeric values in the names.
  -- Some compilers require this (for example, rustc).
  basename = basename:gsub("%W", "")
  return string.format("%s_%d_%d", basename, start_pos, end_pos)
end

-- Removes the line with the results left over from the previous
-- compilation/execution.
-- @param linenr Number of an empty line before results header.
local function remove_previous_output(linenr)
  local saved_pos = fn.getpos(".")

  -- Remove line with compilation results header.
  local results_linenr = linenr + 1
  local maybe_results_line = fn.getline(results_linenr)
  if maybe_results_line == nil then
    return
  end
  if not maybe_results_line:find(M.opts.results_label, 1, true) then
    return
  end
  fn.execute(string.format("%d,%ddelete", linenr, results_linenr))

  -- Remove multiline code blocks following the results header.
  local cur_line = fn.getline(linenr)
  if cur_line:find(code_block_start(), 1, true) then
    end_linenr = linenr
    while true do
      end_linenr = end_linenr + 1
      local cur_line = fn.getline(end_linenr)
      if cur_line == nil then
        break
      end
      if cur_line == code_block_end() then
        break
      end
    end

    -- Remove extra new line at the end.
    local num_lines = fn.line("$")
    if
      end_linenr + 2 < num_lines
      and fn.getline(end_linenr + 1) == ""
      and fn.getline(end_linenr + 2) == ""
    then
      end_linenr = end_linenr + 1
    end

    fn.execute(string.format("%d,%ddelete", linenr, end_linenr))
  end

  fn.setpos(".", saved_pos)
end

-- Deletes existing lines in virtual output
-- @param bufnr Buffer number
-- @param ns_id Namespace id
local function remove_virtual_lines(bufnr, ns_id, line_start, line_end)
  local existing_marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    ns_id,
    {line_start, 0},
    {line_end, 0},
    {}
  )
  for _, v in pairs(existing_marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns_id, v[1])
  end
end

-- Writes output of the excuted command after the linenr line.
-- @param out Table containing lines from the output.
local function write_output(linenr, out)
  local out_table = { "" }
  if out == nil then
    out_table[#out_table + 1] =
      string.format("%s `<no output>`", M.opts.results_label)
  else
    if #out == 1 then
      out_table[#out_table + 1] =
        string.format("%s `%s`", M.opts.results_label, out[1])
    else
      out_table[#out_table + 1] = M.opts.results_label
      out_table[#out_table + 1] = code_block_start()
      for _, s in pairs(out) do
        out_table[#out_table + 1] = s:gsub("\\n", "")
      end
      out_table[#out_table + 1] = code_block_end()
    end
  end

  -- Add an additional new line after the end, if it doesn't already exist.
  if fn.getline(linenr + 1) ~= "" then
    out_table[#out_table + 1] = ""
  end

  -- TODO: uncomment this block after we get the option to work
  -- -- Do not use virtual text
  -- if (M.opts.virtual_text ~= nil) then
  --   for _, s in pairs(out_table) do
  --     fn.append(linenr, s)
  --     linenr = linenr + 1
  --   end
  --   return
  -- end

  -- Use virtual text
  local bufnr = vim.api.nvim_get_current_buf()
  local ns_id = vim.api.nvim_create_namespace("mdeval")
  remove_virtual_lines(bufnr, ns_id, linenr, linenr+1)
  local virtual_lines = {}
  for _, s in pairs(out_table) do
    local vline = {{ s, "MdEvalLine" }}
    table.insert(virtual_lines, vline)
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, linenr, 0, {
    virt_lines = virtual_lines,
    virt_lines_above = true,
  })
end

-- Parses start line to get code of the language.
-- For example: `#+BEGIN_SRC cpp` returns `cpp`.
local function get_lang(start_line)
  local start_pos = string.find(start_line, code_block_start(), 1, true)
  local len = string.len(code_block_start())
  return string.sub(start_line, start_pos + len):match("%w+")
end

-- Returns indentation length for the string `s`.
local function get_indent_lenght(s)
  local tab_length = 4
  local indent = 0
  for i = 1, #s do
    c = s:sub(i, i)
    if c == " " then
      indent = indent + 1
    else
      if c == "\t" then
        indent = indent + tab_length
      else
        break
      end
    end
  end
  if indent == 0 then
    return 0
  else
    return indent + 1
  end
end

-- Parses source code of the block between `start_` and `end_l` line numbers in
-- the current buffer.
local function parse_code(start_l, end_l)
  local code = api.nvim_buf_get_lines(0, start_l, end_l, false)
  if code == nil then
    return ""
  end
  code = table.concat(code, "\n")
  -- Remove extra indent before the source code.
  -- This is important for space sensitive languages like Python and Haskell.
  local first_line_indent = 0
  local has_indent = false
  local lines = {}
  local rest_code = code
  while true do
    -- Get the current line
    if rest_code == nil then
      break
    end
    is, ie = string.find(rest_code, "\n")
    if is == nil then
      s = rest_code
    else
      s, _ = rest_code:sub(1, ie - 1)
    end
    if #s + 2 < #rest_code then
      rest_code, _ = rest_code:sub(#s + 2, #rest_code)
    else
      rest_code = nil
    end

    if not has_indent then
      -- Find the indent at the first line
      first_line_indent = get_indent_lenght(s)
      if first_line_indent == 0 then
        return code -- no extra indent found
      end
      table.insert(lines, s:sub(first_line_indent, #s))
    else
      line_indent = get_indent_lenght(s)
      if line_indent ~= first_line_indent then
        return code -- doesn't match the indent, so it is not an indentation
      end
      table.insert(lines, s:sub(line_indent, #s))
    end
  end

  return table.concat(lines, "\n")
end

function M:eval_code_block()
  local linenr_from = fn.search(code_block_start() .. ".\\+$", "bnW")
  local linenr_until = fn.search(code_block_end() .. ".*$", "nW")
  if linenr_from == 0 or linenr_until == 0 then
    print("Not inside a code block.")
    return
  end

  local start_line = fn.getline(linenr_from)
  local lang_code = get_lang(start_line)
  if lang_code == "" then
    print("Language is not defined.")
    return
  end

  local code = parse_code(linenr_from, linenr_until - 1)
  if code == "" then
    print("No code found.")
    return
  end

  local lang_name, lang_options = find_lang_options(lang_code)
  if lang_name == nil or lang_options == nil then
    print(string.format("Unsupported language: %s", lang_code))
    return
  end

  if M.opts.require_confirmation then
    local allowed = false
    for _, lang in pairs(M.opts.allowed_file_types) do
      if lang_name == lang then
        allowed = true
        break
      end
    end
    if not allowed then
      local choice = vim.fn.confirm(
        string.format("Evaluate this %s code block on your system?", lang_name),
        "&Yes\n&No",
        2
      )
      if choice == 2 then
        return
      end
    end
  end

  local temp_filename =
    generate_temp_filename(api.nvim_buf_get_name(0), linenr_from, linenr_until)
  local eval_output, rc =
    eval_code(lang_name, lang_options, temp_filename, code, M.opts.exec_timeout)
  remove_previous_output(linenr_until + 1)
  write_output(linenr_until, eval_output)
end

function M:eval_clean_results()
  local linenr_from = fn.search(code_block_start() .. ".\\+$", "bnW")
  local linenr_until = fn.search(code_block_end() .. ".*$", "nW")
  if linenr_from == 0 or linenr_until == 0 then
    print("Not inside a code block.")
    return
  end

  remove_previous_output(linenr_until + 1)

  -- clean virtual text (block)
  local bufnr = vim.api.nvim_get_current_buf()
  local ns_id = vim.api.nvim_create_namespace("mdeval")
  remove_virtual_lines(bufnr, ns_id, linenr_until, linenr_until+1)

  -- INFO: if it were to delete all virtual text, it would be like:
  -- delete_existing_lines(bufnr, ns_id, 0, vim.api.nvim_buf_line_count(0))
end

M.opts = defaults
function M.setup(opts)
  if not opts then
    return
  end

  -- Apply user-defined options, skipping tables and updating eval_options.
  for k, v in pairs(opts) do
    if type(v) ~= "table" then
      M.opts[k] = v
    elseif k == "eval_options" then
      M.opts.eval_options = M.opts.eval_options or {}
      for nk, nv in pairs(v) do
        M.opts.eval_options[nk] = nv
      end
    end
  end
end

return M
