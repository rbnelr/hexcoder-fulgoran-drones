---@class Vault
local Vault = require("vault")

function spawn_position()
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
	for i = 1,count do
		--local id = self.next_bot_id ---@cast id -nil
		--self.next_bot_id = id + 1
		---@type Emerging
		local emerging = {
			tick = game.tick + math.floor((start_time + math.random() * over_time) * 60),
			--id = id,
			name = name,
			final_pos = spawn_position(),
		}
		table.insert(self.wave_emerging, emerging)
	end
end
function Vault:update_emerging()
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
			} ---@cast projectile - nil
			self.wave_emerging[id] = nil
			
			-- projectiles have no unit_number!
			--local proj_id = script.register_on_object_destroyed(projectile)
			--self.wave_emerging_projectiles[proj_id] = projectile
			table.insert(self.wave_emerging_projectiles, projectile)
		end
	end
	
	for id,e in pairs(self.wave_emerging_projectiles) do
		if not e.valid then
			self.wave_emerging_projectiles[id] = nil
		end
	end
end

script.on_event(defines.events.on_trigger_created_entity, function(event)
	local bot = event.entity
	local source = event.source
	-- we are not actually being told the projectile, which makes things harder as I can't associate an id with the spawned bot
	if bot.type == "combat-robot" and source and source.name == VAULT_NAME then
		bot.combat_robot_owner = source
		
		local id = script.register_on_object_destroyed(source)
		local vault = storage.vaults[id]
		
		bot.force = DRONE_FORCE -- force is neutral for some reason, because vault (simple-entity) can't actually have a force?
		--bot.color = {1,0,0} -- doesn't work
		
		if vault then
			table.insert(vault.wave_bots, bot)
		end
	end
end)


---@param size number?
---@param freq number?
---@return boolean success
function Vault:spawn_wave(size, freq)
	size = size or 1
	freq = freq or 1
	
	self:start_wave(size, freq)
	
	--self.next_bot_id = 1
	
	self:queue_spawn_drones("defender", 44, 1, 15)
	self:queue_spawn_drones("distractor", 13, 0, 6)
	self:queue_spawn_drones("destroyer", 14, 1.2, 4)
	
	return true
end

---@param mined_ore integer mined ore since last wave
---@param time_since_last number elapsed time in minutes since last wave started
---@param time_between number elapsed time in minutes since last wave ended
---@return boolean fire, number? size, number? freq, number? eta
function Vault:should_spawn_wave(mined_ore, time_since_last, time_between, early_out)
	local wave_variation = 0.3 -- percent variation eg 0.2 => 0.8-1.2
	
	self.wave_rng = self.wave_rng or (math.random()*2-1)
	self.wave_rng2 = self.wave_rng2 or (math.random()*2-1)
	local variation = 1 + self.wave_rng * wave_variation
	local variation2 = 1 + self.wave_rng2 * wave_variation
	
	-- vary min and max time too, to avoid waves synching
	local min_time       = settings.global[mod_name.."-wave-min-time"].value * variation
	if time_since_last < min_time and early_out then
		return false -- not enough time has elapsed, no wave
	end
	
	local wave_frequency = settings.global[mod_name.."-wave-freq"].value / variation
	local max_time       = settings.global[mod_name.."-wave-max-time"].value * variation
	-- use a second rng to make size and frequency non-correlated
	local wave_size      = settings.global[mod_name.."-wave-size"].value * variation2
	local min_size = 0.3
	local max_size = 10
	
	
	-- 1 wave every 10 minutes if mining 3000 ore/min
	local base_mining_rate = 3000 -- was 5000 50% resource drain on big miners makes this more forgiving
	local base_frequency = 1 / 10
	-- nonlinear, at 4x the mining rate: 2x as often and 2x as big, at 9x the rate 3x as often
	local nonlinear_exp = 0.5
	
	local frequency = wave_frequency * base_frequency
	
	local mining_rate = mined_ore / math.max(time_since_last, 0.01)
	
	local time_fac = mining_rate / base_mining_rate
	local nonlinear = time_fac ^ nonlinear_exp
	local target_freq = frequency * nonlinear
	local scale_factor = time_fac / math.max(nonlinear, 0.01)
	
	--if mining_rate > 0 then
	--	game.print(serpent.line{ time_fac=time_fac, time=time_since_last, period=1 / target_freq,
	--		mining_rate=mining_rate, target_freq=target_freq, scale_factor=scale_factor, at=self.entity})
	--end
	--if time_since_last < min_time then
	--	return -- not enough time has elapsed, no wave
	--end
	
	local size = wave_size * scale_factor
	if size > max_size then size = max_size end
	if size < min_size then size = min_size end
	
	target_freq = math.max(target_freq, 1/max_time)
	local target_period = 1/target_freq
	local eta = target_period - time_since_last
	
	local fire = time_since_last < min_time or time_since_last >= target_period
	return fire, size, target_freq, eta
end

function Vault:update_waves()
	if self:wave_active() then return end
	
	local count = self:get_ore_remaining()
	
	if self.prev_wave_start_ore_amount == nil then
		-- initially it takes one period for waves to appear
		self.prev_wave_start_ore_amount = count
		self.wave_start_tick = game.tick
		self.wave_end_tick = game.tick
	end
	
	local mined_ore = self.prev_wave_start_ore_amount - count
	if mined_ore < 0 then mined_ore = 0 end
	
	local time_since_last = (game.tick - (self.wave_start_tick or 0)) / 3600
	local time_between = (game.tick - (self.wave_end_tick or 0)) / 3600
	
	--game.print(serpent.line{ ore=count, diff=diff, --[[id=self.id, tick=game.tick,]] at=self.entity})
	
	local fire, size, freq = self:should_spawn_wave(mined_ore, time_since_last, time_between, true)
	if fire then
		self.prev_wave_start_ore_amount = count
		
		self:spawn_wave(size, freq)
	end
end

---@param player LuaPlayer
function Vault:dbg_print(player)
	if self:wave_active() then
		player.print(string.format("Vault (%d): Wave active! Bots: %d active %d emerging %d queued", self.id,
			table_size(self.wave_bots),
			table_size(self.wave_emerging_projectiles),
			table_size(self.wave_emerging)
		), {volume_modifier=0})
	else
		local count = self:get_ore_remaining()
		
		local mined_ore = (self.prev_wave_start_ore_amount or count) - count
		if mined_ore < 0 then mined_ore = 0 end
		
		local time_since_last = (game.tick - (self.wave_start_tick or 0)) / 3600
		local time_between = (game.tick - (self.wave_end_tick or 0)) / 3600
		
		local mining_rate = mined_ore / time_since_last
		
		local fire, size, freq, eta = self:should_spawn_wave(mined_ore, time_since_last, time_between, false)
		
		--player.print("Last wave: "..time_since_last.." min ago  ore: "..mined_ore.." ("..mining_rate.."/m) => "
		--	.."Wave "..size.."x ("..freq.."/m)", {volume_modifier=0})
		player.print(string.format("Vault (%d): Last wave: %.2f min ago  Mining: %d (%d/m) => Next wave %.2fx (%.2f/m) ETA %.2fm",
			self.id, time_since_last, mined_ore, mining_rate, size or 0, freq or 0, eta or 0), {volume_modifier=0})
	end
end
