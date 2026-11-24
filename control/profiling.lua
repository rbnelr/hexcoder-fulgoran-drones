-- Only with const.PROFILE (independent of const.DEBUG, whose expensive code would skew the timings): times every function of the mod modules and every event handler, without touching them
-- FMTK's profiler is gone since FMTK 2.1.2 (native debug adapter), and line hooks would need --enable-unsafe-lua-debug-api
-- control.lua calls wrap_script() before control.events registers its handlers, and wrap_modules() after all requires
-- each wrapped function gets one LuaProfiler (restarted and stopped around each call): inclusive time (callees included, so the column doesn't sum up), only the outermost call of recursion is timed
-- not covered: local functions (show up inside their callers), functions captured as locals before wrapping (e.g. per tile helpers in ore_tracking)
-- LuaProfiler values can only be printed, not read as numbers, so the report is unsorted (sorted by name)
-- /vaults-profile [reset]: writes script-output/vaults-profile.txt (name, calls, total), reset clears all timers
-- an error inside a wrapped function (only matters where it is caught by pcall) leaves its clock running and depth up until the next reset

local const = require("const")

local profiling = {}

---@class ProfileEntry
---@field total LuaProfiler -- stopped between calls, restart() continues without resetting
---@field calls integer
---@field depth integer

local entries = {} ---@type table<string, ProfileEntry>
local wrappers = {} ---@type table<function, true> -- never wrap a wrapper again (tests.lua re-registers handlers it got from get_event_handler)
local reset_tick = nil ---@type MapTick? -- nil: since load

local event_names = {} ---@type table<defines.events, string>
for name,id in pairs(defines.events) do
	event_names[id] = name
end

---@param e ProfileEntry
local function finish(e, ...)
	e.depth = e.depth - 1
	if e.depth == 0 then
		e.total.stop()
	end
	return ...
end

-- calls with the same name share one entry
---@param name string
---@param func function
---@return function
function profiling.wrap(name, func)
	if wrappers[func] then return func end
	local e = entries[name]
	if not e then
		e = { total=helpers.create_profiler(true), calls=0, depth=0 }
		entries[name] = e
	end
	local wrapper = function(...)
		e.calls = e.calls + 1
		if e.depth == 0 then e.total.restart() end
		e.depth = e.depth + 1
		return finish(e, func(...))
	end
	wrappers[wrapper] = true
	return wrapper
end

-- replaces every function field of tbl (methods too, instances look them up through __index)
---@param name string
---@param tbl table
---@param sep string? -- "." (default) or ":" for classes
function profiling.wrap_table(name, tbl, sep)
	sep = sep or "."
	for key,v in pairs(tbl) do
		if type(v) == "function" then
			tbl[key] = profiling.wrap(name..sep..key, v)
		end
	end
end

-- replaces the global script with a proxy whose on_event/on_nth_tick wrap the handlers, everything else goes to the real LuaBootstrap
function profiling.wrap_script()
	local real = script
	local proxy = setmetatable({}, {__index = real})

	function proxy.on_event(event, handler, filters)
		if type(event) == "table" then
			for _,id in pairs(event) do
				proxy.on_event(id, handler, filters)
			end
			return
		end
		if handler then
			handler = profiling.wrap(event_names[event] or tostring(event), handler)
		end
		real.on_event(event, handler, filters)
	end
	function proxy.on_nth_tick(tick, handler)
		if type(tick) == "table" then
			for _,t in pairs(tick) do
				proxy.on_nth_tick(t, handler)
			end
			return
		end
		if tick and handler then
			handler = profiling.wrap("on_nth_tick_"..tick, handler)
		end
		real.on_nth_tick(tick, handler)
	end

	script = proxy
end

-- after all control files are required (modules are shared through the require cache)
function profiling.wrap_modules()
	profiling.wrap_table("Vault", require("control.vault"), ":")
	local ore = require("control.ore_tracking")
	profiling.wrap_table("OreTracker", ore.OreTracker, ":")
	profiling.wrap_table("ore", ore)
	profiling.wrap_table("dmg", require("control.disable_on_damage"))
	profiling.wrap_table("movement", require("control.bot_movement"))
	profiling.wrap_table("gui", require("control.gui"))
	profiling.wrap_table("spawning", require("control.spawning"))
	profiling.wrap_table("depth_scaling", require("control.depth_scaling"))
	profiling.wrap_table("dead_bots", require("control.dead_bots"))
	profiling.wrap_table("original_mapgen", require("control.original_mapgen"))
	profiling.wrap_table("drills_without_ore", require("control.drills_without_ore"))
	profiling.wrap_table("common", require("control.common"))
	-- lib/myutil left out: small helpers called per bot/drill, the wrapper would cost more than they do
	--profiling.wrap_table("myutil", require("lib.myutil"))

	-- globals are looked up at call time
	for _,name in pairs{"init", "reset", "migrate", "get_vault", "get_or_init_vault", "find_nearby_vaults"} do
		if type(_G[name]) == "function" then
			_G[name] = profiling.wrap(name, _G[name])
		end
	end
end

---@param player LuaPlayer?
function profiling.write_report(player)
	local file = "vaults-profile.txt"
	local since = reset_tick and string.format("since reset at tick %d", reset_tick) or "since load"
	local ticks = game.tick - (reset_tick or 0)
	helpers.write_file(file, string.format("tick %d, %s (%s ticks)\nname\tcalls\ttotal (inclusive)\n",
		game.tick, since, reset_tick and tostring(ticks) or "?"), false)

	local names = {}
	for name,e in pairs(entries) do
		if e.calls > 0 then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _,name in ipairs(names) do
		local e = entries[name]
		helpers.write_file(file, {"", name, "\t", tostring(e.calls), "\t", e.total, "\n"}, true)
	end
	dbg_print(string.format("profile of %d functions (%s) written to script-output/%s", #names, since, file), true, nil, player)
end

function profiling.reset()
	for _,e in pairs(entries) do
		e.total.reset()
		e.total.stop()
		e.calls = 0
		e.depth = 0
	end
	reset_tick = game.tick
end

commands.add_command("vaults-profile", "[reset]\nwrite the function timings to script-output/vaults-profile.txt, reset: clear them (needs const.PROFILE)", function(command)
	local player = command.player_index and game.get_player(command.player_index) or nil
	if command.parameter == "reset" then
		profiling.reset()
		dbg_print("profile timers reset", true, nil, player)
	else
		profiling.write_report(player)
	end
end)

return profiling
