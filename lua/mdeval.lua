local defaults = require'defaults'

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
  if vim.loop.os_uname().version:match "Windows" then
    return string.format("wsl %s", prefix, cmd)
  end
  return cmd
end

local function create_tmp_build_dir()
    local handle = io.popen(get_command(string.format("mkdir -p %s 2>&1", M.opts.tmp_build_dir)))
    handle:close()
end

-- Exclude long temporary directory name from the output.
-- @param out Table containing lines from the output.
local function sanitize_output(temp_filename, out)
    assert(temp_filename ~= nil)
    temp_filename = temp_filename:gsub('-', '%%-')
    for k, v in pairs(out) do
        out[k] = v:gsub(temp_filename, 'temp')
    end
    return out
end

-- Wraps command inside the "timeout" call.
local function get_timeout_command(cmd, timeout)
    if vim.loop.os_uname().sysname == 'Darwin' then
        timeout_cmd = 'gtimeout'
    else
        timeout_cmd = 'timeout'
    end
    return get_command(string.format("%s %d sh -c '%s' 2>&1",
                                     timeout_cmd, timeout, cmd))
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
    local handle = io.popen(get_command(string.format("rm -f %s 2>&1",
                                                      a_out_filepath)))
    handle:close()

    local handle = io.popen(get_command(string.format("%s %s -o %s 2>&1; echo $?",
                                                      table.concat(command, " "),
                                                      src_filepath,
                                                      a_out_filepath)))
    local result = {}
    local lastline
    for line in handle:lines() do
        result[#result+1] = line
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
        result[#result+1] = line
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
        result[#result+1] = line
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
        return run_compiler(lang_options.command,
                            lang_options.extension,
                            temp_filename,
                            code,
                            timeout)
    elseif lang_options.exec_type == "interpreted" then
        return run_interpreter(lang_options.command,
                               lang_options.extension,
                               temp_filename,
                               code,
                               timeout)
    end

    if lang.exec_type == nil then
        error(string.format("Execution type for %s unset.", lang_name))
        error("Please set one of the: compiled and interpreted one.")
    else
        error(string.format("Unknown execution type for %s: %s",
                            lang_name, lang.exec_type))
    end

    return nil, false
end

local function generate_temp_filename(buffer_name, start_pos, end_pos)
    local basename = buffer_name:match("^.+/(.+)$")
    -- Allow only alphanumeric values in the names.
    -- Some compilers require this (for example, rustc).
    basename = basename:gsub('%W', '')
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
    if not maybe_results_line:find(M.opts.results_label) then
        return
    end
    fn.execute(string.format("%d,%ddelete", linenr, results_linenr))

    -- Remove multiline code blocks following the results header.
    local cur_line = fn.getline(linenr)
    if cur_line:find(code_block_start()) then
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
        local num_lines = fn.line('$')
        if end_linenr + 2< num_lines and
           fn.getline(end_linenr + 1) == "" and
           fn.getline(end_linenr + 2) == "" then
           end_linenr = end_linenr + 1
       end

        fn.execute(string.format("%d,%ddelete", linenr, end_linenr))
    end

    fn.setpos(".", saved_pos)
end

-- Writes output of the excuted command after the linenr line.
-- @param out Table containing lines from the output.
local function write_output(linenr, out)
    local out_table = {"",}
    if out == nil then
        out_table[#out_table+1] = string.format("%s `<no output>`",
                                                M.opts.results_label)
    else
        if #out == 1 then
            out_table[#out_table+1] = string.format("%s `%s`",
                                                    M.opts.results_label,
                                                    out[1])
        else
            out_table[#out_table+1] = M.opts.results_label
            out_table[#out_table+1] = code_block_start()
            for _, s in pairs(out) do
                out_table[#out_table+1] = s:gsub('\\n', '')
            end
            out_table[#out_table+1] = code_block_end()
        end
    end

    -- Add an additional new line after the end, if it doesn't already exist.
    if fn.getline(linenr + #out_table+1) ~= "" then
        out_table[#out_table+1] = ""
    end

    for _, s in pairs(out_table) do
        fn.append(linenr, s)
        linenr = linenr + 1
    end
end

-- Parses start line to get code of the language.
-- For example: `#+BEGIN_SRC cpp` returns `cpp`.
function get_lang(start_line)
    local start_pos = string.find(start_line, code_block_start())
    local len = string.len(code_block_start())
    return string.sub(start_line, start_pos + len):gsub("%s+", "")
end

function M:eval_code_block()
	local linenr_from = fn.search(code_block_start()..".\\+$", "bnW")
	local linenr_until = fn.search(code_block_end()..".*$", "nW")
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

    local code = api.nvim_buf_get_lines(0, linenr_from, linenr_until - 1, false)
    if next(code) == nil then
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
                string.format("Evaluate this %s code block on your system?",
                              lang_name),
                              "&Yes\n&No", 2)
            if choice == 2 then
                return
            end
        end
    end

    local temp_filename = generate_temp_filename(api.nvim_buf_get_name(0),
                                                 linenr_from,
                                                 linenr_until)
    local code_str = table.concat(code, "\n")
    local eval_output, rc = eval_code(lang_name, lang_options,
                                      temp_filename, code_str,
                                      M.opts.exec_timeout)
    remove_previous_output(linenr_until + 1)
    write_output(linenr_until, eval_output)
end

function M:eval_clean_results()
	local linenr_from = fn.search(code_block_start()..".\\+$", "bnW")
	local linenr_until = fn.search(code_block_end()..".*$", "nW")
    if linenr_from == 0 or linenr_until == 0 then
        print("Not inside a code block.")
        return
    end
    remove_previous_output(linenr_until + 1)
end

M.opts = defaults
function M.setup(opts)
  -- Apply user-defined options with fallback to defaults.
  for k, v in pairs(opts) do
      if type(v) ~= 'table' then
          M.opts[k] = v
      end
  end
  for k, v in pairs(opts.eval_options) do
      if M.opts.eval_options[k] == nil then
          M.opts.eval_options[k] = {}
      end
      for nk, nv in pairs(v) do
          M.opts.eval_options[k][nk] = nv
      end
  end
end

return M
