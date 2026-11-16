local const = require("const")
local common = require("control.common")
---@class Vault
local Vault = require("control.vault")
local ore = require("control.ore_tracking")
local depth_scaling = require("control.depth_scaling")

local HOVER_VAULT_MSG = "Run command while hovering a vault ruin"

-- "Prepare for uninstall": storage is empty and must stay so (init() would start the mod again)
local function paused(command)
	if common.UNINSTALL then
		dbg_print("Paused for uninstall (\"Prepare for uninstall\" in map settings)", true, nil, game.get_player(command.player_index))
	end
	return common.UNINSTALL
end

if const.DEBUG then
	commands.add_command("vaults-attack", "", function(command)
		if paused(command) then return end
		init()
		
		local size = command.parameter and tonumber(command.parameter) or 100
		
		local player = game.get_player(command.player_index) ---@cast player -nil
		local sel = player.selected
		if sel and sel.valid and sel.name == const.VAULT_NAME then
			local vault = get_or_init_vault(sel)
			vault:end_wave(true) -- true: kill bots
			vault:start_wave(size, 1, depth_scaling.bot_tier(vault.scrap_tracker.depth))
		else
			dbg_print(HOVER_VAULT_MSG, true, nil, player)
		end
	end)
	commands.add_command("vaults-end-wave", "", function(command)
		if paused(command) then return end
		init()
		
		local player = game.get_player(command.player_index) ---@cast player -nil
		local sel = player.selected
		if sel and sel.valid and sel.name == const.VAULT_NAME then
			get_or_init_vault(sel):end_wave(true)
		else
			dbg_print(HOVER_VAULT_MSG, true, nil, player)
		end
	end)
end

commands.add_command("vaults-restore-ore",
		"<percent> [all]\nrestore the scrap around the hovered vault ruin to a percentage of its original amount (default 100, may be > 100; infinite scrap clamps to its minimum, finite to 1)\nalso recreates fully mined tiles\nall: every vault island on fulgora instead of the hovered vault ruin (slow)",
		function(command)
	if paused(command) then return end
	init()

	local player = game.get_player(command.player_index) ---@cast player -nil

	-- percent and "all" in any order
	local percent, all = nil, false
	for arg in string.gmatch(command.parameter or "", "%S+") do
		if arg == "all" then all = true else percent = tonumber(arg) end
	end
	percent = (percent and percent >= 0) and percent or 100

	if all then
		local surface = game.get_surface("fulgora")
		if surface == nil then
			dbg_print("Fulgora does not exist yet", true, nil, player)
			return
		end
		local prof = helpers.create_profiler()
		ore.restore_all_ore(surface, percent / 100)
		prof.stop()
		-- freezes the game like the conversion, so include the time
		log(dbg_print({"", string.format("Restored all vault island scrap on %s to %g%%. ", surface.name, percent), prof}, true))
		return
	end

	local sel = player.selected
	if sel and sel.valid and sel.name == const.VAULT_NAME then
		ore.restore_ore(get_or_init_vault(sel), percent / 100)
		local p = sel.position
		log(dbg_print(string.format("Restored scrap around vault ruin at [gps=%d,%d,%s] to %g%%", math.floor(p.x), math.floor(p.y), sel.surface.name, percent), true))
	else
		dbg_print(HOVER_VAULT_MSG.." (or add \"all\")", true, nil, player)
	end
end)
