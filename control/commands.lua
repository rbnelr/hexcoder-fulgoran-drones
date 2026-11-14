local const = require("const")
---@class Vault
local Vault = require("control.vault")
local ore = require("control.ore_tracking")
local depth_scaling = require("control.depth_scaling")
--local recreate_fulgora = require("control.recreate_fulgora") -- for fulg-bench-convert
--local dead_bots = require("control.dead_bots") -- for fulg-spawn-bot-res

if const.DEBUG then
	-- /c local s = game.player.surface; s.clear();
	-- /c local s = game.player.surface; s.request_to_generate_chunks({0, 0}, 20); s.force_generate_chunk_requests(); game.player.force.chart_all(s)
	
	-- TEMPORARY (disabled, recreate_fulgora.debug_convert_all was removed): compare whole map conversion variants, use a test save
	-- converts away from the setting and back, so the map ends up as before (finite tiles below the inf minimum stay raised)
	-- "full": fake fulgora for all chunks instead of only vault islands, to compare counts and time
	--commands.add_command("fulg-bench-convert", "[single|single-find-entity|single-lookup|chunks] [full] (default: all, vault island chunks only)", function(command)
		--init()
		--local player = game.get_player(command.player_index) ---@cast player -nil
		--local surface = game.get_surface("fulgora")
		--if not surface then
			--player.print("no fulgora")
			--return
		--end

		--local variants, all_chunks = {}, false
		--for arg in string.gmatch(command.parameter or "", "%S+") do
			--if arg == "full" then all_chunks = true else variants[#variants+1] = arg end
		--end
		--if #variants == 0 then variants = {"single", "single-find-entity", "single-lookup", "chunks"} end

		---- fresh fake surface for a fair time, deletion is queued until the end of the tick
		--if game.surfaces["hexcoder_fake_fulgora"] then
			--recreate_fulgora.delete_fake_fulgora()
			--player.print("deleted existing fake fulgora, run the command again")
			--return
		--end

		--local prof_fake = helpers.create_profiler()
		--local fake_surface, requested = recreate_fulgora.recreate_initial_surface_and_load_chunks(surface, "all", nil, all_chunks)
		--prof_fake.stop()
		--local msg_fake = {"", string.format("fake fulgora (%s, %d chunks) ", all_chunks and "full" or "vault islands", requested or 0), prof_fake}
		--player.print(msg_fake)
		--log(msg_fake)

		--local current = const.INF_SCRAP_ENABLED and "vault-scrap" or "scrap"
		--local other = const.INF_SCRAP_ENABLED and "scrap" or "vault-scrap"
		--for _,variant in ipairs(variants) do
			--local c1, p1 = recreate_fulgora.debug_convert_all(surface, fake_surface, variant, other)
			--local c2, p2 = recreate_fulgora.debug_convert_all(surface, fake_surface, variant, current)
			--local msg = {"", string.format("%s: to %s %d ", variant, other, c1), p1, string.format("  back to %s %d ", current, c2), p2}
			--player.print(msg)
			--log(msg)
		--end
	--end)

	commands.add_command("fulg-attack", "", function(command)
		init()
		
		local size = command.parameter and tonumber(command.parameter) or 1
		
		local sel = game.get_player(command.player_index).selected
		if sel and sel.valid and sel.name == const.VAULT_NAME then
			local vault = get_or_init_vault(sel)
			vault:end_wave(true) -- true: kill bots
			vault:start_wave(size, 1, depth_scaling.bot_tier(vault.scrap_tracker.depth))
		end
	end)
	commands.add_command("fulg-end-wave", "", function(command)
		init()
		
		local sel = game.get_player(command.player_index).selected
		if sel and sel.valid and sel.name == const.VAULT_NAME then
			get_or_init_vault(sel):end_wave(true)
		end
	end)
	
	--commands.add_command("fulg-spawn-bot-res", "", function(command)
	--	init()
	--	
	--	local args = command.parameter and string.gmatch(command.parameter, "[^%s]+")
	--	local type = args and args() or "destroyer"
	--	local countstr = args and args()
	--	local count = countstr and tonumber(countstr) or 1
	--	
	--	-- vault for testing
	--	local player = game.get_player(command.player_index) ---@cast player -nil
	--	
	--	local res_name = const.DRONE_RESOURCE["fulgoran-"..type]
	--	dead_bots.add_dead_bot_resource(player.surface, player.position, res_name, count)
	--end)
end

commands.add_command("fulg-restore-ore",
		"<percent>\nrestore the scrap around the hovered vault ruin to a percentage of its original amount (>= 0, may be > 100; infinite scrap clamps to its minimum, finite to 1)\nalso recreates fully mined tiles",
		function(command)
	init()

	local player = game.get_player(command.player_index) ---@cast player -nil

	local percent = tonumber(command.parameter or "")
	if not percent or percent < 0 then
		player.print(const.PRINT_PREFIX.."please pass a percentage >= 0")
		return
	end

	local sel = player.selected
	if sel and sel.valid and sel.name == const.VAULT_NAME then
		ore.restore_ore(get_or_init_vault(sel), percent / 100)
		player.print(const.PRINT_PREFIX.."ore restored")
	else
		player.print(const.PRINT_PREFIX.."need to hover a vault!")
	end
end)
