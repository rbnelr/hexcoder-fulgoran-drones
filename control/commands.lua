local const = require("const")
local common = require("control.common")
---@class Vault
local Vault = require("control.vault")
local ore = require("control.ore_tracking")

local HOVER_VAULT_MSG = "Run command while hovering a vault ruin"

-- "Prepare for uninstall": storage is empty and must stay so (init() would start the mod again)
---@param command CustomCommandData
---@return boolean
local function paused(command)
	if common.UNINSTALL then
		dbg_print("Paused for uninstall (\"Prepare for uninstall\" in map settings)", true, nil, game.get_player(command.player_index))
	end
	return common.UNINSTALL
end

if const.DEBUG then
	commands.add_command("vaults-start-wave",
			"(size=<percent>) (depth=<0-100>) (quality=<1-5>)\n"..
			"start a wave at the hovered vault with current or supplied parameters\n"..
			"size: wave size in % (driven by mining rate)\n"..
			"depth: depth in m, determines bot counts and bot quality tier\n"..
			"quality: bot quality tier, 1 = normal (driven by depth)",
			function(command)
		if paused(command) then return end
		init()

		-- ignore unknown args
		local args = {}
		for k,v in string.gmatch(command.parameter or "", "(%w+)=(%S+)") do
			args[k] = tonumber(v)
		end
		if args["size"] then args["size"] = args["size"] / 100 end
		if args["depth"] then args["depth"] = args["depth"] / 100 end
		if args["quality"] then args["quality"] = math.max(args["quality"] - 1, 0) end
		
		local player = game.get_player(command.player_index) ---@cast player -nil
		local sel = player.selected
		if sel and sel.valid and sel.name == const.VAULT_NAME then
			local vault = get_or_init_vault(sel)
			--vault:end_wave(true) -- true: kill bots
			local wave = vault:start_wave(args.size, 1, args.quality, args.depth)
			
			dbg_print(string.format("Started wave: size %.0f%%, threat %.0f%%, quality tier %.2f, depth %.0fm",
					wave.size * 100, wave.threat or 0, wave.bot_quality_tier + 1,
					(args.depth or select(2, vault:find_current_mining_rate_and_depth())) * 100),
				true, nil, player)
		else
			dbg_print(HOVER_VAULT_MSG, true, nil, player)
		end
	end)
	commands.add_command("vaults-end-wave",
			"(kill) (repair)\n"..
			"end the hovered vault's wave\n"..
			"kill: also kill its bots\n"..
			"repair: heal and restore all buildings",
			function(command)
		if paused(command) then return end
		init()

		-- ignore unknown args
		local kill, repair = false, false
		for arg in string.gmatch(command.parameter or "", "%S+") do
			if arg == "kill" then kill = true elseif arg == "repair" then repair = true end
		end

		local player = game.get_player(command.player_index) ---@cast player -nil

		local sel = player.selected
		if sel and sel.valid and sel.name == const.VAULT_NAME then
			get_or_init_vault(sel):end_wave(kill, repair)
		else
			dbg_print(HOVER_VAULT_MSG, true, nil, player)
		end
	end)
	
	--[[
	commands.add_command("vaults-list",
			"log all vault ruins with their initial scrap amount (scrap tiles in the defense radius, overlapping vaults count shared tiles twice), summary in chat",
			function(command)
		if paused(command) then return end
		init()

		local totals = {} ---@type number[]
		for _,vault in pairs(storage.vaults) do
			local e = vault.entity
			if e.valid then
				local tracker = vault.scrap_tracker
				local initial, current, tiles = 0, 0, 0
				if const.INF_SCRAP_ENABLED then
					-- infinite tiles never disappear and keep their initial_amount
					for _,o in pairs(e.surface.find_entities_filtered{name=const.ACTIVE_SCRAP, position=e.position, radius=const.VAULT_DEFENSE_RADIUS}) do
						initial = initial + o.initial_amount
						current = current + o.amount
						tiles = tiles + 1
					end
				else
					-- finite: tracker initials, incl. mined out tiles
					initial, current = tracker.initial_total or 0, tracker.amount_total or 0
					tiles = table_size(tracker.initial_amounts or {})
				end
				table.insert(totals, initial)

				local p = e.position
				log(const.PRINT_PREFIX..string.format("Vault at [gps=%d,%d,%s]: initial %.1fM, current %.1fM, %d tiles (avg %.0fk), depth %.0fm",
					math.floor(p.x), math.floor(p.y), e.surface.name, initial / 1e6, current / 1e6, tiles,
					tiles > 0 and initial / tiles / 1e3 or 0, tracker:scanned_depth() * 100))
			end
		end

		if #totals == 0 then
			dbg_print("No vault ruins registered", true, nil, game.get_player(command.player_index))
			return
		end
		table.sort(totals)
		local sum = 0
		for _,t in pairs(totals) do sum = sum + t end
		log(dbg_print(string.format("%d vault ruins: initial scrap avg %.1fM, median %.1fM, min %.1fM, max %.1fM (per vault lines in the log)",
			#totals, sum / #totals / 1e6, totals[math.ceil(#totals / 2)] / 1e6, totals[1] / 1e6, totals[#totals] / 1e6), true))
	end)
	]]
end

commands.add_command("vaults-change-ore",
		"(restore=<percent>) (convert) (all)\n"..
		"restore the scrap around the hovered vault ruin to a percentage of its original amount including recreating fully depleted tiles, works off the real mapgen\n"..
		"restore: percent of initial, 0-100; infinite scrap clamps to its minimum, finite to 1\n"..
		"convert: convert scrap between finite and infinite to the current setting (useful for vault ruins not from mapgen, e.g. cloned, current amount assumed to be the initial)\n"..
		"all: every vault ruin on fulgora instead of the hovered one (slow)",
		function(command)
	if paused(command) then return end
	init()

	local player = game.get_player(command.player_index) ---@cast player -nil

	-- ignore unknown args
	local percent, convert, all = nil, false, false
	for arg in string.gmatch(command.parameter or "", "%S+") do
		local k, v = string.match(arg, "^(%w+)=(%S+)$")
		if k == "restore" then percent = tonumber(v)
		elseif arg == "convert" then convert = true
		elseif arg == "all" then all = true end
	end
	if percent then percent = math.min(math.max(percent, 0), 100) end
	if percent == nil and not convert then
		dbg_print("Nothing to do, pass restore=<percent> and/or convert", true, nil, player)
		return
	end
	local restore = percent and percent / 100

	local what = convert and (percent and string.format("Converted and restored to %g%%", percent) or "Converted") or string.format("Restored to %g%%", percent)

	if all then
		local surface = game.get_surface("fulgora")
		if surface == nil then
			dbg_print("Fulgora does not exist yet", true, nil, player)
			return
		end
		local prof = helpers.create_profiler()
		ore.change_ore(surface, "all", restore, convert)
		prof.stop()
		-- freezes the game like the conversion, so include the time
		log(dbg_print({"", string.format("%s scrap around all vault ruins on %s. ", what, surface.name), prof}, true))
		return
	end

	local sel = player.selected
	if sel and sel.valid and sel.name == const.VAULT_NAME then
		ore.change_ore(sel.surface, get_or_init_vault(sel), restore, convert)
		local p = sel.position
		log(dbg_print(string.format("%s scrap around vault ruin at [gps=%d,%d,%s]", what, math.floor(p.x), math.floor(p.y), sel.surface.name), true))
	else
		dbg_print(HOVER_VAULT_MSG.." (or add \"all\")", true, nil, player)
	end
end)
