local spawning = {}

---@param wave LuaEntity[]
---@param vault Vault
---@param bot_type string
---@param count integer
function spawn_drones(wave, vault, bot_type, count)
	for i = 1,count do
		local x = (math.random()-0.5) * 3
		local y = (math.random()-0.5) * 3
		
		local ve = vault.entity
		local bot = ve.surface.create_entity{
			name=bot_type,
			position={ ve.position.x+x, ve.position.y+y },
			force=DRONE_FORCE,
		}
		bot.combat_robot_owner = ve
		
		table.insert(wave, bot)
	end
end

---@param vault Vault
function spawning.start_attack(vault)
	prepare_vault(vault)
	
	-- if attack wave already, just spawn more drones anyway, but this should never happen
	local wave = vault.bot_wave or {}
	if table_size(wave) < 400 then -- avoid wave never ending, as else we don't remove dead bots right now
		vault.bot_wave = wave
		spawn_drones(wave, vault, "defender", 44)
		spawn_drones(wave, vault, "distractor", 13)
		spawn_drones(wave, vault, "destroyer", 14)
	end
	
	game.forces["player"].add_custom_alert(vault.entity,
		{type="entity", name="fulgoran-ruin-vault"},
		{"alert.active-attack"}, true)
end
---@param vault Vault
function spawning.end_attack(vault)
	game.forces["player"].remove_alert{entity=vault.entity}
end

---@param vault Vault
local function check_ore_and_attack(vault)
	local count = check_ore_depletion(vault)
	
	if vault.prev_attack_ore_amount == nil then
		vault.prev_attack_ore_amount = count
	end
	
	local diff = count - vault.prev_attack_ore_amount
	
	game.print("ore: ".. count .."  (".. (diff or "nil") ..") at ("..vault.entity.position.x..", "..vault.entity.position.y..")")
	
	-- TODO: time-based and some sort of evolution?
	if diff < -2000 then
		vault.prev_attack_ore_amount = count
		spawning.start_attack(vault)
	end
end

script.on_nth_tick(60*10, function(event)
	init()
	
	for id,v in pairs(storage.vaults) do
		check_ore_and_attack(v)
	end
end)

--_bots = {}
--commands.add_command("fulg-spawn", "", function(command)
--	local commands = {}
--	if command.parameter then
--		for cmd in string.gmatch(command.parameter or "", "%w+") do
--			table.insert(commands, cmd)
--		end
--	end
--	local bot_type = commands and commands[1] or "defender"
--	local count = commands and tonumber(commands[2]) or 5
--
--	local player = game.get_player(command.player_index) ---@cast player -nil
--	
--	local surface = player.surface
--	local selected = player.selected
--	if selected == nil then return end
--	
--	prepare_vault(init_vault(selected))
--	
--	local bots = {}
--	for i = 1,count do
--		local x = (math.random()-0.5) * 3
--		local y = (math.random()-0.5) * 3
--		
--		local bot = surface.create_entity{
--			name=bot_type,
--			position={ selected.position.x+x, selected.position.y+y },
--			force="player",
--		}
--		bot.combat_robot_owner = selected
--		
--		--bot.set_movement({-1,0}, 1)
--		
--		table.insert(bots, bot)
--	end
--	_bots = bots
--end)

return spawning