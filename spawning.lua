---@class Vault
local Vault = require("vault")
local g = require("common")

local function spawn_position()
	local spawn_r_x = g.VAULT_SPAWN_RADIUS
	local spawn_r_y = spawn_r_x * g.VAULT_SHAFT_ELLIPSE_K
	
	--return random_in_ellipse_center_bias({x=0,y=0}, { x=spawn_r_x, y=spawn_r_y })
	return g.random_in_ellipse({x=0,y=0}, { x=spawn_r_x, y=spawn_r_y })
end
-- project x onto bottom of ellipse, where bot (projectile) can spawn hidden behind VAULT_NEAR_WALL_NAME entity
---@param x number
---@return number y
local function emerging_obscured_y_pos(x)
	local r = g.VAULT_SHAFT_RADIUS
	return g.VAULT_SHAFT_ELLIPSE_K * math.sqrt(r*r - x*x)
end

local function get_total_scrap_produced()
	local surface = game.surfaces["fulgora"]
	--local test = surface.get_resource_counts() -- only counts generated chunks, not clear how to use this
	
	-- this counts productivity, unlike my per-vault spawning logic, but that's probably ok
	local stats = game.forces["player"].get_item_production_statistics(surface)
	
	local total = 0
	for Q,_ in pairs(prototypes.quality) do
		if Q ~= "quality-unknown" then
			total = total + stats.get_input_count({name="scrap", quality=Q})
		end
	end
	
	return total
end
local function get_evolution_factor()
	local total = get_total_scrap_produced()

	local evo_speed = settings.global[g.MOD_NAME.."-evolution-speed"].value --[[@as number]]
	local x = total * (evo_speed / 10000000)
	local factor = x / (x + 1) -- like vanilla, squash 0-inf into 0-1 range
	return factor
end

---@param bot_type string
---@param count integer
---@param delay number
---@param duration number
function Vault:queue_spawn_drones(bot_type, count, delay, duration)
	local name = "hexcoder-"..bot_type.."-emerge"
	for i = 1,count do
		--local id = self.next_bot_id ---@cast id -nil
		--self.next_bot_id = id + 1
		---@type Emerging
		local emerging = {
			tick = game.tick + math.floor((delay + math.random() * duration) * 60),
			--id = id,
			name = name,
			final_pos = spawn_position(),
		}
		table.insert(self.wave_emerging_queued, emerging)
	end
	self.wave_bots_count[bot_type] = (self.wave_bots_count[bot_type] or 0) + count
end
function Vault:update_emerging()
	--draw_ellipse(self.entity, self.entity.surface,
	--	VAULT_SHAFT_CENTER, {x=VAULT_SHAFT_RADIUS, y=VAULT_SHAFT_RADIUS*VAULT_SHAFT_ELLIPSE_K},
	--	{1,1,0, 0.3})
	
	local cur_tick = game.tick
	local center = { x = g.VAULT_SHAFT_CENTER.x + self.entity.position.x,
	                 y = g.VAULT_SHAFT_CENTER.y + self.entity.position.y }
	for id,e in pairs(self.wave_emerging_queued) do
		if cur_tick >= e.tick then
			local x = center.x + e.final_pos.x
			local y = center.y + e.final_pos.y
			local sy = center.y + emerging_obscured_y_pos(e.final_pos.x) + g.BOT_FLOAT_HEIGHT
			
			--rendering.draw_line{from={x,sy}, to={x,y}, width=1, surface=self.entity.surface, time_to_live=30, color={1,1,0.5}}
			
			local projectile = self.entity.surface.create_entity{
				name=e.name,
				position = {x=x, y=sy}, target = {x=x, y=y}, snap_to_grid = false,
				force=g.DRONE_FORCE,
				source = self.entity, -- track which vault this came from
			} ---@cast projectile - nil
			self.wave_emerging_queued[id] = nil
			
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
	if bot.type == "combat-robot" and source and source.name == g.VAULT_NAME then
		init()
		
		bot.combat_robot_owner = source
		
		local id = script.register_on_object_destroyed(source)
		local vault = storage.vaults[id]
		
		-- set force again, already set on projectile and _should_ have spawned bot with correct force, but does not
		-- force is neutral for some reason, possibly because source==vault (simple-entity) can't actually have a force?
		bot.force = g.DRONE_FORCE
		--bot.color = {1,0,0} -- individual bot tinting doesn't work?
		
		local variation = 1.0 - math.random()*0.2
		bot.time_to_live = bot.time_to_live * variation
		
		if vault then
			table.insert(vault.active_wave_bots, bot)
		end
	end
end)

-- stop bots not yet spawned as projectiles
--function Vault:stop_queued_bots()
--	self.wave_emerging_queued = {} -- drops old table (purely data)
--end

---@param drop_loot boolean?
function Vault:stop_wave_and_kill_bots(drop_loot)
	self.wave_emerging_queued = {}
	
	for id,e in pairs(self.wave_emerging_projectiles) do
		if e.valid then
			-- don't drop loot?
			e.destroy() -- would .die work?
		end
	end
	self.wave_emerging_projectiles = {}
	
	for id,e in pairs(self.active_wave_bots) do
		if e.valid then
			if drop_loot then
				-- should drop loot
				e.die() -- force=neutral, cause=nothing
			else
				e.destroy()
			end
		end
	end
	self.active_wave_bots = {}
end

---@param size number?
---@param freq number?
---@param apply_evo boolean?
---@return boolean success
function Vault:spawn_wave(size, freq, apply_evo)
	size = size or 1
	freq = freq or 1
	
	local evo = apply_evo and get_evolution_factor() or 1
	-- TODO: needs to be tuned still, maybe evo needs to be lower since I think a max of wave size 4x is fine with infinite techs, quality etc.
	-- it's just that right now all my saves are at high evo despite not being in the endgame
	size = size * (evo*evo * 3.8 + 0.2)
	
	self:start_wave(size, freq)
	
	--self.next_bot_id = 1
	
	local var1 = 1 + (math.random()*2-1) * 0.3
	local var2 = 1 + (math.random()*2-1) * 0.3
	local var3 = 1 + (math.random()*2-1) * 0.3
	
	local s1 = size * var1
	local s2 = size * var2
	local s3 = size * var3
	
	-- size 4 spawns 4x the bots over 2x the time (2x the rate)
	-- TODO: could also intentially cluster more around the start?
	local dur1 = math.sqrt(s1)
	local dur2 = math.sqrt(s2)
	local dur3 = math.sqrt(s3)
	
	local delay = 2
	
	-- TODO: current distribution fixed, should make
	-- low sizes spawn almost only defenders
	-- and high sizes more destroyers than this
	-- probably want 1-2 distractors and 0 or 1 destroyer even on minimum size
	
	-- distractors spawn first, other types delayed
	self:queue_spawn_drones("defender", 50*s1, delay+1, 15*dur1)
	self:queue_spawn_drones("distractor", 15*s2, delay+0, 9*dur2)
	self:queue_spawn_drones("destroyer", 20*s3, delay+2.5, 10*dur3)
	
	--game.print(serpent.block{ evo=evo, size=size, freq=freq })
	
	return true
end

---@param mined_ore integer mined ore since last wave
---@param time_since_last number elapsed time in minutes since last wave started
---@param time_between number elapsed time in minutes since last wave ended
---@return boolean trigger_wave, number? size, number? freq, number? eta
function Vault:should_spawn_wave(mined_ore, time_since_last, time_between, early_out)
	local wave_variation = 0.3 -- percent variation eg 0.2 => 0.8-1.2
	
	self.wave_rng = self.wave_rng or (math.random()*2-1)
	self.wave_rng2 = self.wave_rng2 or (math.random()*2-1)
	local variation = 1 + self.wave_rng * wave_variation
	local variation2 = 1 + self.wave_rng2 * wave_variation
	
	-- vary min and max time too, to avoid waves synching
	-- TODO: min time is a bit weird, esp being a setting, unless somebody really wants a ex. 2 minute safe window
	-- esp with this not even being time_between, but time_since_last (did I make this change for consistency)?
	-- in fact, at high mining rates/evo/settings, having attacks literally uninterruppted may be cool
	-- TODO: just remove this?
	local min_time = settings.global[g.MOD_NAME.."-wave-min-time"].value * variation
	if time_since_last < min_time and early_out then
		return false -- not enough time has elapsed, no wave
	end
	
	-- weird code I came up with to make attacks more dynamic than 'attack every 10k ore mined)
	-- both size and frequency of attacks increase with higher mining rate, though rate is determined by mined amount since last wave
	-- so if stopped mining, the rate is not 0 but actually decreases over time, the attack will happen later and at lower size
	
	-- 1 wave every 10 minutes if mining 3000 ore/min
	local base_mining_rate = 3000 -- was 5000 50% resource drain on big miners makes this more forgiving
	local base_frequency = 1 / 10
	
	-- exp=0.5: at 4x the mining rate: 2x as often and 2x as big, at 9x the rate 3x as often
	-- meaning the number of bots over time is proportional to mining rate
	-- could increase so size and frequency would be exponential to mining rate
	local freq_exp = 0.6 -- was 0.5
	local size_exp = 0.7 -- was 0.5
	
	local wave_frequency = settings.global[g.MOD_NAME.."-wave-freq"].value / variation * base_frequency
	local max_time       = settings.global[g.MOD_NAME.."-wave-max-time"].value * variation
	-- use a second rng to make size and frequency non-correlated
	local wave_size      = settings.global[g.MOD_NAME.."-wave-size"].value * variation2
	local min_size = 0.3
	local max_size = 10
	
	local mining_rate = mined_ore / math.max(time_since_last, 0.01)
	local mining_factor = mining_rate / base_mining_rate
	
	wave_frequency = wave_frequency * mining_factor ^ freq_exp
	wave_size = mining_factor ^ size_exp
	
	wave_size = math.max(wave_size, min_size)
	wave_size = math.min(wave_size, max_size)
	
	wave_frequency = math.max(wave_frequency, 1/max_time) -- 1/max_time==min_freq could also be added instead of max'ed
	wave_frequency = math.min(wave_frequency, 1/min_time)
	
	local target_period = 1/wave_frequency
	local eta = target_period - time_since_last
	
	local trigger_wave = time_since_last < min_time or time_since_last >= target_period
	return trigger_wave, wave_size, wave_frequency, eta
end

function Vault:update_waves()
	if self:wave_active() then return end
	
	local count = self:get_ore_remaining()
	
	if self.wave_start_ore_amount == nil then
		-- initially it takes one period for waves to appear
		self.wave_start_ore_amount = count
		self.wave_start_tick = game.tick
		self.wave_end_tick = game.tick
	end
	
	local mined_ore = self.wave_start_ore_amount - count
	if mined_ore < 0 then mined_ore = 0 end
	
	local time_since_last = (game.tick - (self.wave_start_tick or 0)) / 3600
	local time_between = (game.tick - (self.wave_end_tick or 0)) / 3600
	
	--game.print(serpent.line{ ore=count, diff=diff, --[[id=self.id, tick=game.tick,]] at=self.entity})
	
	local trigger_wave, size, freq = self:should_spawn_wave(mined_ore, time_since_last, time_between, true)
	if trigger_wave then
		self.wave_start_ore_amount = count
		
		self:spawn_wave(size, freq, true)
	end
end
