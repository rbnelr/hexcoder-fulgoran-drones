local const = require("const")
---@class Vault
local Vault = require("control.vault")
local common = require("control.common")
local depth_scaling = require("control.depth_scaling")
local myutil = require("lib.myutil")
local round = myutil.round

local function spawn_position()
	local spawn_r_x = const.VAULT_SPAWN_RADIUS
	local spawn_r_y = spawn_r_x * const.VAULT_SHAFT_ELLIPSE_K
	
	--return random_in_ellipse_center_bias({x=0,y=0}, { x=spawn_r_x, y=spawn_r_y })
	return myutil.random_in_ellipse({x=0,y=0}, { x=spawn_r_x, y=spawn_r_y })
end
-- project x onto bottom of ellipse, where bot (projectile) can spawn hidden behind VAULT_NEAR_WALL_NAME entity
---@param x number
---@return number y
local function emerging_obscured_y_pos(x)
	local r = const.VAULT_SHAFT_RADIUS
	return const.VAULT_SHAFT_ELLIPSE_K * math.sqrt(r*r - x*x)
end

---@param wave WaveInfo
---@param bot_type string
---@param quality_tier number 0-(MAX_BOT_QUALITY-1)
---@param count integer
---@param delay number
---@param duration number
function Vault:_queue_spawn_drones(wave, bot_type, quality_tier, count, delay, duration)
	local name = const.EMERGE_PARTICLES[bot_type]
	for i = 1,count do
		local quality_level = depth_scaling.roll_bot_quality_from_tier(quality_tier)
		local quality_name = const.QUALITY_IDS[quality_level]
		
		---@type Emerging
		local emerging = {
			tick = game.tick + math.floor((delay + math.random() * duration) * 60),
			--id = id,
			name = name,
			quality = quality_name,
			final_pos = spawn_position(),
		}
		table.insert(self.emerging_queued, emerging)
		
		wave.bot_qualities[quality_name] = (wave.bot_qualities[quality_name] or 0) + 1
	end
	wave.bot_types[bot_type] = (wave.bot_types[bot_type] or 0) + count
end

-- emerging bots: spawn projectile that looks like bot mostly hidden behind the near-wall
-- once the projectile hits the spot it ws aiming at, it spawns the real bot
-- TODO: projectile and or particles and bots have actual z axis, do we need to fake z via y here?
function Vault:update_emerging()
	--draw_ellipse(self.entity, self.entity.surface,
	--	VAULT_SHAFT_CENTER, {x=VAULT_SHAFT_RADIUS, y=VAULT_SHAFT_RADIUS*VAULT_SHAFT_ELLIPSE_K},
	--	{1,1,0, 0.3})
	
	local cur_tick = game.tick
	local center = { x = const.VAULT_SHAFT_CENTER.x + self.entity.position.x,
	                 y = const.VAULT_SHAFT_CENTER.y + self.entity.position.y }
	for id,emerging in pairs(self.emerging_queued) do
		if cur_tick >= emerging.tick then
			local x = center.x + emerging.final_pos.x
			local y = center.y + emerging.final_pos.y
			local sy = center.y + emerging_obscured_y_pos(emerging.final_pos.x) + const.BOT_FLOAT_HEIGHT
			
			--rendering.draw_line{from={x,sy}, to={x,y}, width=1, surface=self.entity.surface, time_to_live=30, color={1,1,0.5}}
			
			local projectile = self.entity.surface.create_entity{
				name=emerging.name,
				position = {x=x, y=sy}, target = {x=x, y=y}, snap_to_grid = false,
				force=const.DRONE_FORCE,
				source = self.entity, -- track which vault this came from
				preserve_ghosts_and_corpses = true, -- ??
				quality = emerging.quality -- projectile can take quality
			} ---@cast projectile - nil
			self.emerging_queued[id] = nil
			
			-- projectiles have no unit_number!
			--local proj_id = script.register_on_object_destroyed(projectile)
			--self.emerging_projectiles[proj_id] = projectile
			table.insert(self.emerging_projectiles, projectile)
		end
	end
	-- clear them here instead of in on_trigger_created_entity to handle deleted before it finishes?
	for id,entity in pairs(self.emerging_projectiles) do
		if not entity.valid then
			self.emerging_projectiles[id] = nil
		end
	end
end

-- reverse of emerging: destroy bot and spawn descend projectile, finishing hidden behind the near-wall
-- this particle variant does not spawn a bot at the end
-- destroy() skips destroy_action, so no particle and no wreck
---@param bot LuaEntity
function Vault:descend_bot(bot)
	local center = { x = const.VAULT_SHAFT_CENTER.x + self.entity.position.x,
	                 y = const.VAULT_SHAFT_CENTER.y + self.entity.position.y }
	local pos = bot.position
	local name = const.DESCEND_PROJECTILES[bot.name]

	-- end at the hidden bottom edge below the bot, clamped into the shaft
	local r = const.VAULT_SHAFT_RADIUS * 0.9
	local x = math.min(math.max(pos.x - center.x, -r), r)
	local sy = center.y + emerging_obscured_y_pos(x) + const.BOT_FLOAT_HEIGHT
	
	self.entity.surface.create_entity{
		name = name,
		position = pos, target = {x=center.x + x, y=sy}, snap_to_grid = false,
		force = const.DRONE_FORCE,
		quality = bot.quality -- for good measure
		--speed = myutil.vector_length(bot.get_movement()), -- not sure if this does anything
	}

	bot.destroy()
end

-- projectile automatically spawns bot, but we use callback to keep tracking the bot
-- and to set force and time to live
-- quality projectiles automatically spawn bots at correct quality
script.on_event(defines.events.on_trigger_created_entity, function(event)
	local bot = event.entity
	local source = event.source
	-- we are not actually being told the projectile, which makes things harder as I can't associate an id with the spawned bot
	if bot.type == "combat-robot" and source and source.valid and source.name == const.VAULT_NAME then
		init()
		
		bot.combat_robot_owner = source -- source is vault entity
		
		local vault = get_vault(source)
		
		-- set force again, already set on projectile and _should_ have spawned bot with correct force, but does not
		-- force is neutral for some reason, possibly because source==vault (simple-entity) can't actually have a force?
		bot.force = const.DRONE_FORCE

		local variation = 1.0 - math.random()*0.2
		bot.time_to_live = bot.time_to_live * variation
		
		if vault then
			table.insert(vault.active_bots, bot)
			--emerging projectile cleared in update_emerging
		end
	end
end)

---@param drop_loot boolean?
function Vault:_kill_all_bots(drop_loot)
	self.emerging_queued = {}
	
	for id,e in pairs(self.emerging_projectiles) do
		if e.valid then
			-- don't drop loot?
			e.destroy() -- would .die work?
		end
	end
	self.emerging_projectiles = {}
	
	for id,e in pairs(self.active_bots) do
		if e.valid then
			if drop_loot then
				-- should drop loot
				e.die() -- force=neutral, cause=nothing
			else
				e.destroy()
			end
		end
	end
	self.active_bots = {}
end

-- spawn wave based on final scaled size and later quality
-- also takes freq to remember so alerts and gui can keep displaying them
---@param size number?
---@param freq number?
---@param bot_quality_tier number? -- 0-(MAX_BOT_QUALITY-1)
---@return WaveInfo wave
function Vault:_spawn_wave_bots(size, freq, bot_quality_tier)
	size = size or 1
	freq = freq or 1
	bot_quality_tier = bot_quality_tier or 0
	
	--self.next_bot_id = 1
	
	local var1 = 1 + (math.random()*2-1) * 0.3
	local var2 = 1 + (math.random()*2-1) * 0.3
	local var3 = 1 + (math.random()*2-1) * 0.3
	
	local s1 = math.max(size * var1, 0)
	local s2 = math.max(size * var2 - 0.1, 0)
	local s3 = math.max(size * var3 - 0.3, 0)
	
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
	
	local wave = {
		start_tick = game.tick,
		end_tick = nil,
		size = size,
		freq = freq,
		bot_quality_tier = bot_quality_tier,
		bot_types = {},
		bot_qualities = {},
	}
	
	-- distractors spawn first, other types delayed
	self:_queue_spawn_drones(wave, "fulgoran-defender", bot_quality_tier, round(32*s1), delay+1.5, 15*dur1)
	self:_queue_spawn_drones(wave, "fulgoran-distractor", bot_quality_tier, round(10*s2), delay+0, 9*dur2)
	self:_queue_spawn_drones(wave, "fulgoran-destroyer", bot_quality_tier, round(6*s3), delay+3.5, 10*dur3)
	
	--game.print("_spawn_wave: "..serpent.block(wave))
	return wave
end

--function Vault:_start_fake_wave_without_spawns()
--	return {
--		start_tick = game.tick,
--		end_tick = nil,
--		size = 0,
--		freq = 0,
--		bot_quality_tier = 0,
--		bot_types = {},
--		bot_qualities = {},
--	}
--end

---@param mining_rate number mined ore per minute since last wave (OreTracker:mining_rate)
---@param time_since_last number elapsed time in minutes since last wave started
---@return boolean trigger_wave, number? size, number? freq, number? eta
function Vault:should_spawn_wave(mining_rate, time_since_last, early_out)
	local wave_variation = 0.3 -- percent variation eg 0.2 => 0.8-1.2
	
	-- allow calling should_spawn_wave(), and getting same variation rng each time until set to nil
	self.cur_rng = self.cur_rng or (math.random()*2-1)
	self.cur_rng2 = self.cur_rng2 or (math.random()*2-1)
	local variation = 1 + self.cur_rng * wave_variation
	local variation2 = 1 + self.cur_rng2 * wave_variation
	
	-- vary min and max time too, to avoid waves synching
	-- TODO: min time is a bit weird, esp being a setting, unless somebody really wants a ex. 2 minute safe window
	-- esp with this not even being time_between, but time_since_last (did I make this change for consistency)?
	-- in fact, at high mining rates/evo/settings, having attacks literally uninterruppted may be cool
	-- TODO: just remove this?
	local min_time = common.WAVE_MIN_TIME * variation
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
	
	local wave_frequency = common.WAVE_FREQ / variation * base_frequency
	local max_time       = common.WAVE_MAX_TIME * variation
	-- use a second rng to make size and frequency non-correlated
	local wave_size      = common.WAVE_SIZE * variation2
	local min_size = 0.1
	local max_size = 10
	
	local mining_factor = mining_rate / base_mining_rate
	
	wave_frequency = wave_frequency * mining_factor ^ freq_exp
	wave_size = wave_size * mining_factor ^ size_exp
	
	wave_size = math.max(wave_size, min_size)
	wave_size = math.min(wave_size, max_size)
	
	wave_frequency = math.max(wave_frequency, 1/max_time) -- 1/max_time==min_freq could also be added instead of max'ed
	wave_frequency = math.min(wave_frequency, 1/min_time)
	
	local target_period = 1/wave_frequency
	local eta = math.max(target_period - time_since_last, 0)
	
	local trigger_wave = time_since_last < min_time or time_since_last >= target_period
	return trigger_wave, wave_size, wave_frequency, eta
end


function Vault:update_waves()
	local had_drills = self.has_drills -- from the previous update_targets (poll or build event)
	self:update_targets()
	
	-- allow waves to overlap
	-- so current or prev wave counts start_tick is counted for mining rate
	-- if mining rate high enough or settings aggressive enough and bots still active waves will overlap
	-- existing bots will remain and eventually die or return while new ones emerge
	-- new wave start will counts as new wave for gui and for should_spawn_wave logic
	--if self:bots_active() then return end
	
	-- scan ore only while mining is possible since the last scan: drills now or at the previous poll (counts the mining until they were removed)
	-- without drills no scans, rare min size waves still happen
	-- TODO: player could be near and mine by hand but well, probably does not matter
	if self.has_drills or had_drills then
		local e = self.entity
		self.scrap_tracker:scan(e.surface, e.position, const.VAULT_DEFENSE_RADIUS, self.has_drills)
	end
	
	if self.has_drills then
		self:update_quality_for_vault_drills() -- drill quality from depth
	end
	
	local mining_rate = self.scrap_tracker:mining_rate() -- mining rate, usually since last wave start
	local time_since_last = (game.tick - self.wave_timer_start) / 3600
	--local time_between = (game.tick - self.wave_end_tick) / 3600
	
	local trigger_wave, size, freq = self:should_spawn_wave(mining_rate, time_since_last, true)
	if trigger_wave then
		local quality_tier = depth_scaling.bot_tier(self.scrap_tracker.depth)
		self:start_wave(size, freq, quality_tier)
		
		-- reset rng here, other codepaths that start waves do not use rng
		self.cur_rng = nil -- every wave gets random variation for time and mining spawning
		self.cur_rng2 = nil
	end
end
