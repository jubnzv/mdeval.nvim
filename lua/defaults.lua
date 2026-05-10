local M = {}
local lang_conf = {}

lang_conf["markdown"] = { "```", "```" }
lang_conf["vimwiki"] = { "{{{", "}}}" }
lang_conf["norg"] = { "@code", "@end" }
lang_conf["org"] = { "#+BEGIN_SRC", "#+END_SRC" }
lang_conf["markdown.pandoc"] = { "```", "```" }

M.lang_conf = lang_conf

M.virtual_text = false
M.require_confirmation = true
M.allowed_file_types = {}
M.exec_timeout = -1
M.tmp_build_dir = "/tmp/mdeval/"
M.results_label = "*Results:*"
M.eval_options = {
  bash = {
    command = { "bash" },
    language_code = { "bash", "sh" },
    exec_type = "interpreted",
    extension = "sh",
  },
  c = {
    command = { "clang" },
    language_code = "c",
    exec_type = "compiled",
    extension = "c",
  },
  cpp = {
    command = { "clang++" },
    language_code = "cpp",
    exec_type = "compiled",
    extension = "cpp",
  },
  lua = {
    command = { "lua" },
    language_code = "lua",
    exec_type = "interpreted",
    extension = "lua",
  },
  haskell = {
    command = { "ghc" },
    language_code = "haskell",
    exec_type = "compiled",
    extension = "hs",
  },
  js = {
    command = { "node" },
    language_code = "js",
    exec_type = "interpreted",
    extension = "js",
  },
  ocaml = {
    command = { "ocamlc" },
    language_code = "ocaml",
    exec_type = "compiled",
    extension = "ml",
  },
  python = {
    command = { "python3" },
    language_code = { "python", "py" },
    exec_type = "interpreted",
    extension = "py",
  },
  ruby = {
    command = { "ruby" },
    language_code = "ruby",
    exec_type = "interpreted",
    extension = "rb",
  },
  rust = {
    command = { "rustc" },
    language_code = "rust",
    exec_type = "compiled",
    extension = "rs",
  },
}

return M
