local M = {}

local Utils = require("skel-nvim.utils")
local skeld = require("skel-nvim.defaults")
local Picker = require("skel-nvim.picker")
local config_path = vim.fn.stdpath("config")
local skel_autogroup = vim.api.nvim_create_augroup("skel_autogroup", { clear = true })
local buffer_state = {}
local skel_enabled = true
local apply_skel_for_empty_file = true

-- this extended/overriden by user config
local default_config = {
	-- enable/disable plugin, this supercedes disable_for_empty_file
	skel_enabled = true,
	-- enable/disable processing for bufread + empty file
	apply_skel_for_empty_file = true,
	-- dir containing skeleton files
	templates_dir = config_path .. "/skeleton",
	-- file pattern -> template mapping
	mappings = {
		["main.cpp"] = "main.cpp.skel",
		["*.h"] = "h.skel",
		["*.cpp"] = "cpp.skel",
		["*.t.cpp"] = "utests.cpp.skel",
		["main.c"] = "main.c.skel",
		["*.c"] = "c.skel",
		["*.go"] = "go.skel",
		["*.py"] = "py.skel",
		["*.lua"] = "lua.skel",
		["*.sh"] = "sh.skel",
	},
	-- substitutions in templates
	-- can be a string or a callback function
	substitutions = {
		["FILENAME"] = skeld.get_filename,
		["NAME"] = skeld.get_author,
		["DATE"] = skeld.get_date,
		["CPP_HDR_GUARD"] = skeld.get_cppheaderguard,
		["CPP_TEST_HDR_GUARD"] = skeld.get_testheaderguard,
		["CPP_HDR_INCLUDE"] = skeld.get_headerinclude,
		["CLASS_NAME"] = skeld.get_classname2,
		["NAMESPACE_OPEN"] = skeld.get_namespaceopen,
		["NAMESPACE_CLOSE"] = skeld.get_namespaceclose,
	},

	-- Misc config vars available to substitution callback functions
	-- Users can add their own variable here
	author = "MyName",
	namespace = { "MyOrg", "MyApp" },

	-- per project overrides
	projects = {},
}

-- used to differentiate between plugin/user keys
local plugin_keys = {
	skel_enabled = true,
	apply_skel_for_empty_file = true,
	project = true,
	projects = true,
	path = true,
	templates_dir = true,
	mappings = true,
	substitutions = true,
	author = true,
	namespace = true,
}

-- this is overriden by setup
local runtime_config = default_config

-- cache for current buffer config
local current_config = nil

-- compares filename to pattern see if they match
local function find_match(filename, pattern)
	local fully_matched = false
	local wildcard_match = false
	local num_chars_matched = 0

	local max_len = math.max(string.len(filename), string.len(pattern))

	-- match each char from the end until we eithr
	--    find a mismatch
	--    stop on wildcard '*' in pattern
	--    fully match
	for i = 1, max_len, 1 do
		local idx = i * -1
		local filename_char = string.sub(filename, idx, idx)
		local pattern_char = string.sub(pattern, idx, idx)
		if filename_char == pattern_char then
			num_chars_matched = num_chars_matched + 1
		-- print(filename, pattern, idx, filename_char, pattern_char)
		else
			if pattern_char == "*" then
				-- first mismatch is on wildcard char
				wildcard_match = true
			end
			break
		end
	end

	fully_matched = num_chars_matched == max_len
	-- print(filename, pattern, max_len, wildcard_match, num_chars_matched, fully_matched)

	-- success: if either wildcard_match or fully_matched
	return { matched = fully_matched or wildcard_match, full_match = fully_matched, weight = num_chars_matched }
end

-- using current buffer filename attempts to
-- find best matched filename pattern
local function find_best_matching(filename)
	if not filename then
		filename = "main.cpp"
	end
	-- print(filename, string.sub(filename, -1))
	local result = nil
	local config = M.get_config()
	for k, v in pairs(config.mappings) do
		local res = find_match(filename, k)
		if res["matched"] then
			res["template"] = v
			res["pattern"] = k
			if res["full_match"] then
				-- print ("full match")
				result = res
				break
			elseif not result or res["weight"] > result["weight"] then
				result = res
			end
		end
	end

	return result
end

local function apply_subs(line, subs, callback_arg)
	local subs_to_apply = {}
	for str in string.gmatch(line, "@[%w_]+@") do
		local clean_key = string.gsub(str, "@", "")
		local val = subs[clean_key]
		if val then
			subs_to_apply[clean_key] = val
		end
	end

	for k, v in pairs(subs_to_apply) do
		-- we don't support tables as a substitution value
		if type(v) == "table" then
			return line
		end

		local val = v
		if type(v) == "function" then
			val = v(callback_arg)
		end
		-- support callback returning multiline
		if type(val) == "table" then
			return val
		end
		--
		line = string.gsub(line, "@" .. k .. "@", val)
	end
	return line
end

-- identifies which config should apply to current
-- buffer based on pathname
local function set_current_config()
	local fname = vim.api.nvim_buf_get_name(0)
	local proj = nil
	local max = 0

	for _, v in pairs(runtime_config) do
		local s, e = fname:find(v.path)
		local weight = 0
		if s ~= nil and e ~= nil then
			weight = e - s
		end
		if weight > max then
			proj = v
			max = weight
		end
	end

	if proj ~= nil then
		-- print (proj.project)
		return proj
	else
		-- print (runtime_config['default'].project)
		return runtime_config["default"]
	end
end

-- build the config table that will be passed to
-- substitution handlers
local function build_callback_config(config, filename)
	local callback = {
		author = config.author,
		filename = filename,
		namespace = config.namespace,
	}

	for key, val in pairs(config) do
		if plugin_keys[key] == nil then
			callback[key] = val
		end
	end

	return callback
end

local function load_template_file(template_file)
	local bufnr = vim.api.nvim_get_current_buf()

	-- if we've already processed this buffer ignore other patterns that match this file
	if buffer_state[bufnr] then
		return
	end

	local abspath = vim.fn.expand("%:p")
	if abspath == nil or abspath == "" then
		return
	end
	local config = M.get_config()

	local proj_file = config.templates_dir .. "/" .. template_file
	local default_file = default_config.templates_dir .. "/" .. template_file

	local template_path = proj_file
	if not Utils.fileexists(template_path) then
		template_path = default_file
	end

	local fh = io.open(template_path)
	local lines = {}
	if fh == nil then
		return
	end

	-- build callback config object
	local callback_cfg = build_callback_config(config, abspath)

	-- load skeleton file and apply substitutions
	for line in fh:lines() do
		line = apply_subs(line, config.substitutions, callback_cfg)
		-- line can be substituted by multilines
		if type(line) == "table" then
			for _, l in ipairs(line) do
				lines[#lines + 1] = l
			end
		else
			lines[#lines + 1] = line
		end
	end
	fh:close()

	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	-- local cmd = "0r "..default_config.templates_dir.."/"..res["template"]
	-- vim.cmd(cmd) print(cmd)

	-- set flag to indicate this buffer has bee processed.
	buffer_state[bufnr] = true
	current_config = nil
end

-- Main handler for BufNewFile events
function M.handle_new_file(pattern, skeleton_file, manual)
	if not manual and not skel_enabled then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()

	-- if we've already processed this buffer ignore other patterns that match this file
	if buffer_state[bufnr] then
		return
	end

	local filename = vim.fn.expand("%")
	local abspath = vim.fn.expand("%:p")

	-- we can have multiple patterns that match this filenam, we need
	-- try to find best match and apply it's skeleton file
	local res = find_best_matching(filename)
	if not res["matched"] then
		return
	end

	local template_file = res["template"]

	if type(res["template"]) == "table" then
		local num_entries = Utils.size(res["template"])
		if num_entries < 1 then
			return
		elseif num_entries == 1 then
			template_file = res["template"][1]
		else
			Picker.get_selection(res["template"], load_template_file)
			return
		end
	end

	load_template_file(template_file)
end

-- This should only apply skeleton if we've read a buffer
--  * buffer is not a new file
--  * buffer is however empty
-- This is common use case when creating a new file using nvim-tree
-- and then loading opening/reading the empty buffer
function M.handle_buff_read(pattern, skeleton_file, manual)
	if not manual and not skel_enabled then
		return
	end
	if not manual and not apply_skel_for_empty_file then
		return
	end

	local num_lines = vim.api.nvim_buf_line_count(0)
	if num_lines ~= 1 then
		return
	end
	local line_data = vim.api.nvim_buf_get_lines(0, 0, 1, 0)
	if string.len(line_data[1]) ~= 0 then
		return
	end

	M.handle_new_file(pattern, skeleton_file, manual)
	-- print ("Num Lines:", num_lines, "Line1:", string.len(line_data[1]))
	-- if buf
end

-- register pattern with BufNewFile
local function register_mapping(pattern, skeleton_file)
	vim.api.nvim_create_autocmd({ "BufNewFile" }, {
		pattern = { pattern },
		callback = function()
			M.handle_new_file(pattern, skeleton_file, false)
		end,
		group = skel_autogroup,
	})
	vim.api.nvim_create_autocmd({ "BufRead" }, {
		pattern = { pattern },
		callback = function()
			M.handle_buff_read(pattern, skeleton_file, false)
		end,
		group = skel_autogroup,
	})
end

-- convinience functtion to get current config
function M.get_config()
	if current_config == nil then
		current_config = set_current_config()
	end
	return current_config
end

-- setup
function M.setup(config)
	if config then
		default_config = vim.tbl_deep_extend("force", default_config, config)
	end

	-- generate configs for
	--   default
	--   per project
	runtime_config = {
		default = {
			project = "default",
			path = "",
			templates_dir = default_config.templates_dir,
			mappings = default_config.mappings,
			substitutions = default_config.substitutions,
			author = default_config.author,
			namespace = default_config.namespace,
		},
	}

	for pname, cfg in pairs(default_config.projects) do
		local path = default_config.templates_dir .. "/" .. pname

		local maps = default_config.mappings
		if cfg["mappings"] ~= nil then
			-- print("updating project", pname)
			maps = vim.tbl_deep_extend("force", maps, cfg.mappings)
		end

		local subs = default_config.substitutions
		if cfg["substitutions"] ~= nil then
			subs = vim.tbl_deep_extend("force", subs, cfg.substitutions)
		end

		local auth = default_config.author
		if cfg["author"] ~= nil then
			auth = cfg.author
		end

		local ns = default_config.namespace
		if cfg["namespace"] ~= nil then
			ns = cfg.namespace
		end

		runtime_config[pname] = {
			project = pname,
			path = cfg.path,
			templates_dir = path,
			mappings = maps,
			substitutions = subs,
			author = auth,
			namespace = ns,
		}
	end

	-- copy over user variables to our runtime configs

	-- first copy user globals to runtime default connfig
	for key, val in pairs(default_config) do
		if plugin_keys[key] == nil then
			runtime_config.default[key] = val
		end
	end

	-- copy user per project to runtime_config.proj
	for user_pname, user_pcfg in pairs(default_config.projects) do
		local run_pcfg = runtime_config[user_pname]

		-- copy variables from user project cfg to runtime project config
		for key, val in pairs(user_pcfg) do
			if plugin_keys[key] == nil then
				run_pcfg[key] = val
			end
		end
		-- copy over user global configs to runtime project config if we
		-- don't already have this value from user project config.
		for key, val in pairs(default_config) do
			if plugin_keys[key] == nil then
				if run_pcfg[key] == nil then
					run_pcfg[key] = val
				end
			end
		end
	end

	-- register autocommands for each file pattern
	for k, v in pairs(config.mappings) do
		--print("registering", k, v)
		register_mapping(k, v)
	end

	skel_enabled = default_config.skel_enabled
	apply_skel_for_empty_file = default_config.apply_skel_for_empty_file
end

-- Commands --

-- SkelEnable
function M.enable()
	skel_enabled = true
end

-- SkelDisable
function M.disable()
	skel_enabled = false
end

-- SkelStatus
function M.status()
	vim.notify("skel status=" .. tostring(skel_enabled), vim.log.levels.INFO, {})
	return skel_enabled
end

-- SkelRun
function M.run_on_current_buffer()
	local abspath = vim.fn.expand("%:p")
	if abspath == nil or abspath == "" then
		vim.notify("skel: current buffer must have a valid filename", vim.log.levels.INFO, {})
		return
	end

	M.handle_buff_read("", abspath, true)
end

-- SkelEdit
function M.create_file(opts)
	vim.cmd(":e " .. opts.args)
	if not skel_enabled then
		M.handle_buff_read("", vim.fn.expand("%:p"), true)
	end
end

return M
