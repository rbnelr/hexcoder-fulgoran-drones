local Vault = require("vault")

---@param vault Vault
function spawn_position(vault)
	local spawn_r_x = VAULT_SPAWN_RADIUS
	local spawn_r_y = spawn_r_x * VAULT_SHAFT_ELLIPSE_K
	
	--return random_in_ellipse_center_bias({x=0,y=0}, { x=spawn_r_x, y=spawn_r_y })
	return random_in_ellipse({x=0,y=0}, { x=spawn_r_x, y=spawn_r_y })
end
-- project x onto bottom of ellipse
---@param x number
---@return number y
function spawn_depth(x)
	local r = VAULT_SHAFT_RADIUS
	return VAULT_SHAFT_ELLIPSE_K * math.sqrt(r*r - x*x)
end

---@param bot_type string
---@param count integer
---@param start_time number
---@param over_time number
function Vault:queue_spawn_drones(bot_type, count, start_time, over_time)
	local name = "hexcoder-"..bot_type.."-emerge"
	self.entity.force = DRONE_FORCE
	for i = 1,count do
		---@type Emerging
		local emerging = {
			name = name,
			final_pos = spawn_position(self),
			tick = game.tick + math.floor((start_time + math.random() * over_time) * 60)
		}
		table.insert(self.wave_emerging, emerging)
	end
end
function Vault:spawn_all_emerging()
	--draw_ellipse(self.entity, self.entity.surface,
	--	VAULT_SHAFT_CENTER, {x=VAULT_SHAFT_RADIUS, y=VAULT_SHAFT_RADIUS*VAULT_SHAFT_ELLIPSE_K},
	--	{1,1,0, 0.3})
	
	local cur_tick = game.tick
	local center = { x = VAULT_SHAFT_CENTER.x + self.entity.position.x,
	                 y = VAULT_SHAFT_CENTER.y + self.entity.position.y }
	for id,e in pairs(self.wave_emerging) do
		if cur_tick >= e.tick then
			local x = center.x + e.final_pos.x
			local y = center.y + e.final_pos.y
			local sy = center.y + spawn_depth(e.final_pos.x) + BOT_FLOAT_HEIGHT
			
			--rendering.draw_line{from={x,sy}, to={x,y}, width=1, surface=self.entity.surface, time_to_live=30, color={1,1,0.5}}
			
			local projectile = self.entity.surface.create_entity{
				name=e.name,
				position = {x=x, y=sy}, target = {x=x, y=y}, snap_to_grid = false,
				force=DRONE_FORCE,
				source = self.entity, -- track which vault this came from
			}
			self.wave_emerging[id] = nil
			--self.active_projectiles [projectile.unit_number] = projectile
		end
	end
end

script.on_event(defines.events.on_trigger_created_entity, function(event)
	local bot = event.entity
	local source = event.source
	if bot.type == "combat-robot" and source and source.name == "fulgoran-ruin-vault" then
		bot.combat_robot_owner = source
		
		local id = script.register_on_object_destroyed(source)
		local vault = storage.vaults[id]
		
		bot.force = DRONE_FORCE -- force is neutral for some reason
		
		--self.wave_emerging[projectile.unit_number] = projectile
		table.insert(vault.wave_bots, bot)
	end
end)

-- TODO: time offset spawns

function Vault:start_wave()
	self:prepare()
	
	-- if attack wave already started, just spawn more drones anyway, but this should never happen
	-- since bots currently die after a minute, and the projectiles trigger after a few seconds
	-- can failsafe if there are too many bots, nut can't track active projectiles easily right now
	if table_size(self.wave_bots) < 400 then
		self:queue_spawn_drones("defender", 44, 1, 8)
		self:queue_spawn_drones("distractor", 13, 0, 6)
		self:queue_spawn_drones("destroyer", 14, 1.2, 4)
	end
	
	game.forces["player"].add_custom_alert(self.entity,
		{type="entity", name="fulgoran-ruin-vault"},
		{"alert.active-attack"}, true)
end
function Vault:end_wave()
	--self.wave_emerging = {}
	self.wave_bots = {}
	game.forces["player"].remove_alert{entity=self.entity}
	
	self:delete_waypoints()
end

---@param vault Vault
local function check_ore_and_attack(vault)
	local count = check_ore_depletion(vault)
	
	if vault.prev_wave_ore_amount == nil then
		vault.prev_wave_ore_amount = count
	end
	
	local diff = count - vault.prev_wave_ore_amount
	
	game.print("ore: ".. count .."  (".. (diff or "nil") ..") at ("..vault.entity.position.x..", "..vault.entity.position.y..")")
	
	-- TODO: time-based and some sort of evolution?
	if diff < -2000 then
		vault.prev_wave_ore_amount = count
		vault:start_wave()
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
--	init_vault(selected).prepare()
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
