local const = require("const")
local common = require("control.common")
local depth_scaling = require("control.depth_scaling")
local myutil = require("lib.myutil")
local round = myutil.round

-- functions take the vault instead of being Vault methods, so this file doesn't require control.vault (vault.lua requires it)
local spawning = {}

--#region bot spawn code

local function spawn_position()
	local spawn_r_x = const.VAULT_SPAWN_RADIUS
	local spawn_r_y = spawn_r_x * const.VAULT_SHAFT_ELLIPSE_K
	
	return myutil.random_in_ellipse_center_bias({x=0,y=0}, { x=spawn_r_x, y=spawn_r_y })
	--return myutil.random_in_ellipse({x=0,y=0}, { x=spawn_r_x, y=spawn_r_y })
end
-- project x onto bottom of ellipse, where bot (projectile) can spawn hidden behind the vault's front wall (drawn by the vault itself, prototypes/vault_ruin.lua)
---@param x number
---@return number y
local function emerging_obscured_y_pos(x)
	local r = const.VAULT_SHAFT_RADIUS
	return const.VAULT_SHAFT_ELLIPSE_K * math.sqrt(r*r - x*x)
end

---@param vault Vault
---@param wave WaveInfo
---@param bot_type string
---@param quality_tier number 0-(MAX_BOT_QUALITY-1)
---@param count integer
---@param delay number
---@param duration number
local function queue_spawn_drones(vault, wave, bot_type, quality_tier, count, delay, duration)
	for i = 1,count do
		local quality_level = depth_scaling.roll_bot_quality_from_tier(quality_tier)
		local quality_name = const.QUALITY_IDS[quality_level]
		
		---@type Emerging
		local emerging = {
			tick = game.tick + math.floor((delay + math.random() * duration) * 60),
			--id = id,
			name = bot_type,
			quality = quality_name,
			final_pos = spawn_position(),
		}
		table.insert(vault.emerging_queued, emerging)
		
		wave.bot_qualities[quality_name] = (wave.bot_qualities[quality_name] or 0) + 1
	end
	if count > 0 then
		wave.bot_types[bot_type] = (wave.bot_types[bot_type] or 0) + count
	end
end

-- emerging bots: spawn projectile that looks like bot mostly hidden behind the vault's front wall
-- once the projectile hits the spot it ws aiming at, it spawns the real bot
-- TODO: projectile and or particles and bots have actual z axis, do we need to fake z via y here?
---@param vault Vault
function spawning.update_emerging(vault)
	--myutil.draw_ellipse(vault.entity, vault.entity.surface,
	--	const.VAULT_SHAFT_CENTER, {x=const.VAULT_SHAFT_RADIUS, y=const.VAULT_SHAFT_RADIUS*const.VAULT_SHAFT_ELLIPSE_K},
	--	{1,1,0, 0.3})
	
	-- emerging_queued is sorted latest to earliest, pop off end to keep array valid (allow later table.insert and table.sort)
	local queued = vault.emerging_queued
	local count = #queued
	local cur_tick = game.tick
	
	if count > 0 and cur_tick >= queued[count].tick then
		local center = { x = const.VAULT_SHAFT_CENTER.x + vault.entity.position.x,
		                 y = const.VAULT_SHAFT_CENTER.y + vault.entity.position.y }
		repeat
			local emerging = queued[count]
			
			--local outward_fac = emerging.name == "fulgoran-distractor" and 1 or 2.5
			--local outward_fac = emerging.name == "fulgoran-distractor" and 1 or 1.8
			--
			--local x0 = center.x + emerging.final_pos.x
			--local y0 = center.y + emerging_obscured_y_pos(emerging.final_pos.x) + const.BOT_FLOAT_HEIGHT
			--local x1 = x0
			--local y1 = center.y + emerging.final_pos.y
			--local tx = center.x + emerging.final_pos.x * outward_fac
			--local ty = y1
			
			--local max_dist = math.abs(ty-y0) --math.abs(tx-x0) + math.abs(ty-y0)

			--rendering.draw_line{from={x0,y0}, to={x1,y1}, width=1, surface=vault.entity.surface, time_to_live=30, color={1,1,0.5}}
			--rendering.draw_line{from={x1,y1}, to={tx,ty}, width=1, surface=vault.entity.surface, time_to_live=30, color={0.5,1,0}}
			
			local x0 = center.x + emerging.final_pos.x
			local y0 = center.y + emerging_obscured_y_pos(emerging.final_pos.x) + const.BOT_FLOAT_HEIGHT
			local ty = center.y + emerging.final_pos.y
			local tx = x0
			local max_dist = 10
			
			local projectile = vault.entity.surface.create_entity{
				name=const.EMERGE_PROJECTILES[emerging.name],
				position = {x=x0, y=y0}, target = {x=tx, y=ty}, snap_to_grid = false,
				force=const.DRONE_FORCE,
				source = vault.entity, -- track which vault this came from
				preserve_ghosts_and_corpses = true, -- ??
				quality = emerging.quality, -- projectile can take quality
				
				speed = const.EMERGE_TOP_SPEEDS[emerging.name]/60, -- speed up to EMERGE_TOP_SPEEDS (hopefully with turn speed increasing so that most of the turning is at the end)
				max_range = max_dist, -- avoid circling forever if made to turn
			} ---@cast projectile - nil
			--projectile.speed = 0
			projectile.orientation = 0

			-- projectiles have no unit_number!
			--local proj_id = script.register_on_object_destroyed(projectile)
			--vault.emerging_projectiles[proj_id] = projectile
			table.insert(vault.emerging_projectiles, projectile)
			
			queued[count] = nil
			
			count = count - 1
		until count <= 0 or cur_tick < queued[count].tick
	end
	
	
	-- TODO: optimize this, don't run it every tick, either just clear in on_trigger_created_entity, or that + a fallback run occasionally?
	--- can't actually do this in on_trigger_created_entity, without also getting id via register_on_object_destroyed?
	-- clear them here instead of in on_trigger_created_entity to handle deleted before it finishes?
	if (cur_tick % 10) == 0 then -- makes bots_active() wrong for a few ticks
		for i,entity in pairs(vault.emerging_projectiles) do
			if not entity.valid then
				vault.emerging_projectiles[i] = nil
			end
		end
	end
end

-- reverse of emerging: destroy bot and spawn descend projectile, finishing hidden behind the vault's front wall
-- this particle variant does not spawn a bot at the end
-- destroy() skips destroy_action, so no particle and no wreck
---@param vault Vault
---@param bot LuaEntity
function spawning.descend_bot(vault, bot)
	local center = { x = const.VAULT_SHAFT_CENTER.x + vault.entity.position.x,
	                 y = const.VAULT_SHAFT_CENTER.y + vault.entity.position.y }
	local pos = bot.position
	local name = const.DESCEND_PROJECTILES[bot.name]

	-- end at the hidden bottom edge below the bot, clamped into the shaft
	local r = const.VAULT_SHAFT_RADIUS * 0.9
	local x = math.min(math.max(pos.x - center.x, -r), r)
	local sy = center.y + emerging_obscured_y_pos(x) + const.BOT_FLOAT_HEIGHT
	
	vault.entity.surface.create_entity{
		name = name,
		position = pos, target = {x=center.x + x, y=sy}, snap_to_grid = false,
		force = const.DRONE_FORCE,
		quality = bot.quality, -- for good measure
		--speed = myutil.vector_length(bot.get_movement()), -- not sure if this does anything
		speed = 1/60, -- have them accelerate downwards up to DECEND_TOP_SPEEDS
	}

	bot.destroy()
end

-- projectile automatically spawns bot, but we use callback to keep tracking the bot
-- and to set force and time to live
-- quality projectiles automatically spawn bots at correct quality
-- registered in control/events.lua
---@param event EventData.on_trigger_created_entity
function spawning.on_trigger_created_entity(event)
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
		--bot.set_movement({1,0}, 2/60)

		-- keep moving like the projectile did: outward from the shaft center (same direction as dead_bots.decollide_with_vault) at its end speed
		local pos = bot.position
		local source_pos = source.position
		local offset_x = pos.x - (source_pos.x + const.VAULT_SHAFT_CENTER.x)
		local offset_y = pos.y - (source_pos.y + const.VAULT_SHAFT_CENTER.y)
		local r_x = const.VAULT_SHAFT_RADIUS
		local r_y = r_x * const.VAULT_SHAFT_ELLIPSE_K
		local dir_x, dir_y = myutil.ellipse_outward_dir(offset_x, offset_y, r_x, r_y)
		-- ellipse coords back to world space (squashed in y like the shaft), set_movement normalizes it
		if bot.name ~= "fulgoran-distractor" then
			bot.set_movement({dir_x * r_x, dir_y * r_y}, const.EMERGE_TOP_SPEEDS[bot.name]/60)
		end
		
		local variation = (vault and vault.testing) and 1 or common.rand_variation(1, 0.1)
		bot.time_to_live = bot.time_to_live * variation
		
		if vault then
			table.insert(vault.active_bots, bot)
			--emerging projectile cleared in update_emerging
		end
	end
end

---@param vault Vault
---@param drop_loot boolean?
function spawning.kill_all_bots(vault, drop_loot)
	vault.emerging_queued = {}
	
	for id,e in pairs(vault.emerging_projectiles) do
		if e.valid then
			-- don't drop loot?
			e.destroy() -- would .die work?
		end
	end
	vault.emerging_projectiles = {}
	
	for id,e in pairs(vault.active_bots) do
		if e.valid then
			if drop_loot then
				-- should drop loot
				e.die() -- force=neutral, cause=nothing
			else
				e.destroy()
			end
		end
	end
	vault.active_bots = {}
end

--#endregion

--#region wave spawn scaling (wave size, frequency and depth-scaled bot counts)

---@param wave_size number multiplier
---@param depth number
---@param variation_range number
---@param rng number? -- 0-1, 0.5 = plain rounding without variation
---@return table<string, integer> counts
---@return number threat
function spawning.roll_bot_counts(wave_size, depth, variation_range, rng)
	local threat = 0
	local counts = {}
	for _,type in pairs(const.BOT_NAMES) do
		local avg_count = common.eval_curve(common.BOT_COUNTS_CURVE[type], depth)
		avg_count = avg_count * wave_size
		local count = common.rand_variation_int(avg_count, avg_count*variation_range, rng)
		
		counts[type] = count
		-- TODO: take into account bot quality scaling?
		threat = threat + count * common.THREAT_PER_BOT[type]
	end
	return counts, threat
end
---@param wave_size number multiplier
---@param depth number
---@return table<string, number> counts
---@return number threat
function spawning.estimate_bot_counts(wave_size, depth)
	local threat = 0
	local counts = {}
	for _,type in pairs(const.BOT_NAMES) do
		local avg_count = common.eval_curve(common.BOT_COUNTS_CURVE[type], depth)
		avg_count = avg_count * wave_size
		
		counts[type] = avg_count
		-- TODO: take into account bot quality scaling?
		threat = threat + avg_count * common.THREAT_PER_BOT[type]
	end
	return counts, threat
end

-- trigger wave to spawn based on size multiplier and bot quality tier
-- also takes freq to remember so alerts and gui could display them
-- no defaults, Vault:start_wave fills them in
---@param vault Vault
---@param size number
---@param freq number
---@param bot_quality_tier number -- 0-(MAX_BOT_QUALITY-1)
---@param depth number -- 0-1
---@return WaveInfo wave
function spawning.spawn_wave_bots(vault, size, freq, bot_quality_tier, depth)

	local counts, threat = spawning.roll_bot_counts(size, depth, 0.3, vault.testing and 0.5 or nil)
	local n1 = counts["fulgoran-defender"]
	local n2 = counts["fulgoran-distractor"]
	local n3 = counts["fulgoran-destroyer"]
	
	-- TODO: need to depend on bot counts as well in some way, or else higher depth has higher bot rate but same time
	local dur_var = vault.testing and 0 or 0.3
	local dur1 = common.rand_variation(size, size*dur_var) ^ 0.3
	local dur2 = common.rand_variation(size, size*dur_var) ^ 0.3
	local dur3 = common.rand_variation(size, size*dur_var) ^ 0.3

	local delay = 2

	---@type WaveInfo
	local wave = {
		start_tick = game.tick,
		end_tick = nil,
		size = size,
		freq = freq,
		threat = threat,
		bot_quality_tier = bot_quality_tier,
		bot_types = {},
		bot_qualities = {},
	}
	
	-- distractors spawn first, other types delayed
	queue_spawn_drones(vault, wave, "fulgoran-defender", bot_quality_tier, n1, delay+1.5, 15*dur1)
	queue_spawn_drones(vault, wave, "fulgoran-distractor", bot_quality_tier, n2, delay+0, 9*dur2)
	queue_spawn_drones(vault, wave, "fulgoran-destroyer", bot_quality_tier, n3, delay+3.5, 10*dur3)
	
	table.sort(vault.emerging_queued, function(a, b) return a.tick > b.tick end) -- sort latest to earliest so update_emerging can pop items off the end
	
	--log(dbg_print{"_spawn_wave_bots ", serpent.block(wave)})
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

-- size and frequency of the next automatic wave from the current mining rate and depth, the caller starts it (update_waves)
-- also used for previews (gui, /vaults-start-wave defaults), the variation rng stays the same until a wave starts
-- early_out: return false right away if less than the min time passed, before scanning (update_waves), false: always compute size etc.
---@param vault Vault
---@param early_out boolean
---@return boolean trigger_wave, number? size, number? freq, number? eta
function spawning.should_spawn_wave(vault, early_out)
	local time_since_last = (game.tick - vault.wave_timer_start) / 3600 -- minutes since the last wave start
	--local time_between = (game.tick - vault.wave_end_tick) / 3600
	
	-- allow calling should_spawn_wave(), and getting same variation rng each time until set to nil
	vault.cur_rng = vault.cur_rng or math.random()
	vault.cur_rng2 = vault.cur_rng2 or math.random()
	local rng1, rng2 = vault.cur_rng, vault.cur_rng2
	if vault.testing then rng1, rng2 = 0.5, 0.5 end -- no variation
	local variation = common.rand_variation(1, 0.3, rng1) -- percent variation eg 0.2 => 0.8-1.2
	local variation2 = common.rand_variation(1, 0.3, rng2)
	
	local min_time = common.WAVE_MIN_TIME * variation -- very small min time, keep variation to remove potential patterns
	if time_since_last < min_time and early_out then
		return false -- not enough time has elapsed, no wave
	end
	
	-- mined since the last wave start, scans if needed
	local mining_rate, depth = vault:find_current_mining_rate_and_depth()
	
	-- weird code I came up with to make attacks more dynamic than 'attack every 10k ore mined'
	-- both size and frequency of attacks increase with higher mining rate, though rate is determined by mined amount since last wave
	-- so if stopped mining, the rate is not 0 but actually decreases over time, the attack will happen later and at lower size
	
	-- exp=0.5: at 4x the mining rate: 2x as often and 2x as big, at 9x the rate 3x as often
	-- meaning the number of bots over time is proportional to mining rate
	-- could increase so size and frequency would be exponential to mining rate
	local freq_exp = 1.0 -- was 0.5
	local size_exp = 1.1 -- was 0.5
	
	local max_time       = common.WAVE_MAX_TIME * variation
	local wave_frequency = common.WAVE_FREQ_MULT / variation * common.BASE_FREQUENCY
	-- use a second rng to make size and frequency non-correlated
	local wave_size      = common.WAVE_SIZE_MULT * variation2
	
	local factor = mining_rate / common.BASE_MINING_RATE
	local depth_freq_factor = common.eval_curve(common.DEPTH_FREQ_CURVE, depth)
	
	wave_frequency = wave_frequency * depth_freq_factor * (factor ^ freq_exp)
	wave_size = wave_size * (factor ^ size_exp)
	
	wave_size = math.max(wave_size, common.WAVE_MIN_SIZE)
	wave_size = math.min(wave_size, common.WAVE_MAX_SIZE)
	
	wave_frequency = math.max(wave_frequency, 1/max_time) -- 1/max_time==min_freq could also be added instead of max'ed
	wave_frequency = math.min(wave_frequency, 1/min_time)
	
	local target_period = 1/wave_frequency
	local eta = math.max(target_period - time_since_last, 0)
	
	local trigger_wave = time_since_last >= target_period
	return trigger_wave, wave_size, wave_frequency, eta
end

--#endregion

return spawning
