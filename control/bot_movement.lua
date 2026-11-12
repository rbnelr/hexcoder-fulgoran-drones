local const = require("const")
local common = require("control.common")
local movement = {}

-- Weyl sequence
-- turn ids into uniformly distributed points in [0,1)
local function weyl_hash01(id)
	local p = id * 0.618033988749895
	return p - math.floor(p)
end

-- choose bot target when it wants to switch
-- TODO: track how many bots are targeting which target and bias against it, so attacks are more spread out
---@param vault Vault
---@param bot LuaEntity
---@return LuaEntity
local function choose_next_target(vault, bot)
	local R = const.VAULT_DEFENSE_RADIUS
	
	-- break off = got to waypoint
	local break_off = math.random() < 0.08
	local rnd = math.random()
	
	if not break_off then
		-- to consider: LuaSurface.find_nearest_enemy
		-- to consider: LuaSurface.get_closest
		
		-- check for close targets (TODO: may be the main cost of this code?)
		local close = vault.entity.surface.find_entities_filtered{position=bot.position, radius=const.RETARGET_DIST,
			type = const.TARGETS, is_military_target=true}
		if next(close) then
			local idx = math.floor(rnd * (#close-0.001))+1
			return close[idx]
		end
		--local count = #close
		--if count > 0 then
		--	for i=1,3 do
		--		local idx = math.floor(rnd * (count-0.001))+1
		--		local targ = close[idx]
		--		-- TODO: distance check is not actually needed since radius is already circular?
		--		-- technically it's circle-touches-bounding-box vs distance to center, but we don't care about that...
		--		-- and if this can't fail this weird retry loop is not even needed!
		--		if common.check_distance(targ.position, vault.entity.position, R) then
		--			return targ
		--		end
		--		rnd = math.random() -- new random to pick other target
		--	end
		--end
		
		-- no close target found, pick random target
		-- reuse rnd
		
		-- TODO: avoid building temp list by keeping it around?
		-- how to cull dead or disabled targets from vault.targets?
		-- lazily swap with last?
		-- like: pick random, check if valid, if not swap with last and pick that?
		local list = {}
		for _,targ in pairs(vault.targets) do
			if targ and targ.valid and targ.is_military_target then
				table.insert(list, targ)
			end
		end
		local count = #list
		local idx = math.floor(rnd * (count-0.001))+1
		local targ = list[idx]
		if targ then return targ end
	end
	-- reuse rnd
	
	-- no actual target found or wanting to break off, go to waypoint
	-- go to waypoint acts like a random patrol
	count = #vault.waypoints
	idx = math.floor(rnd * (count-0.001))+1
	targ = vault.waypoints[idx]
	if targ then return targ end
	
	-- no waypoint found?
	return vault.entity
end

-- TODO: can be optimized, by only checking bots depending on tick, and reacting to building_fully_damaged()
---@param vault Vault
function movement.update(vault)
	--local count = table_size(vault.active_wave_bots)
	--local had_bots = count > 0
	local had_bots = next(vault.active_wave_bots) ~= nil
	
	local tick = game.tick
	local vault_e = vault.entity
	local vault_center = { x = const.VAULT_SHAFT_CENTER.x + vault_e.position.x,
	                       y = const.VAULT_SHAFT_CENTER.y + vault_e.position.y }
	
	--local j = 1
	local target = nil
	
	local function try_leave(id, bot)
		bot.combat_robot_owner = vault_e
		
		local dist = common.get_distance(bot.position, vault_center)
		local radius_fraction = dist / (const.VAULT_SHAFT_RADIUS*1.2) -- 0-1, or higher if outside
		
		local time_left = bot.time_to_live
		local time_passed_fraction = 1 - time_left / const.RETURN_TIME -- 1: no time left, 0: all time remain
		
		-- bots get pushed away from each other, sometimes preventing them from moving towards vault
		-- TODO: could try overriding movement via set_movement()?
		
		if time_left <= 1 or radius_fraction < time_passed_fraction then -- try to get to center, but vary automatically via time, and accept futher out if out of time
			vault:descend_bot(bot)
			vault.active_wave_bots[id] = nil
		end
	end
	
	for id,bot in pairs(vault.active_wave_bots) do
		--- experimental movement logic, should rewrite later!
		-- move all at once (robotic hivemind feeling)
		-- or move staggered
		-- or move in random intervals (including switching target if target dies)
		-- maybe switch target to closest if it dies, but move to purely random otherwise?
		-- could also divide robots into clusters and stagger clusters, might look cool
		if bot and bot.valid then
			local leave = const.DRONES_TRY_TO_RETURN and bot.time_to_live < const.RETURN_TIME
			if leave then
				try_leave(id, bot)
			elseif bot.name ~= "fulgoran-distractor" then
				---@cast bot -nil
				-- form groups of bots where that all go to same target, with bots randomly breaking off
				-- switch targets on a timer, or when target defeated
				local group_idx = math.floor(id / 4)
				local group_leader = group_idx * 4
				--local switch_target = (tick % 500) == math.floor(group_leader / count * 500)
				local switch_target = (tick % 500) == math.floor(weyl_hash01(group_leader) * 500)
				
				local cur_target = bot.combat_robot_owner
				if cur_target and not cur_target.valid then cur_target = nil end
				local is_waypoint = cur_target and cur_target.name == const.WAYPOINT
				local valid_target = cur_target and cur_target.valid and (is_waypoint or cur_target.is_military_target)
				
				if switch_target or not valid_target then
					local rng = math.random()
					local break_off = rng < 0.2
					
					-- TODO: entire group to same target, does leave or break_off currently cause rest of the group to move?
					-- if so fix?
					if id == group_leader or is_waypoint or break_off then
						target = choose_next_target(vault, bot)
					end
					if target and target.valid then
						-- abuse combat_robot_owner to make defenders and destroyers move to targets
						bot.combat_robot_owner = target
					end
				end
			end
			
			--if bot and bot.valid and bot.name ~= "fulgoran-distractor" then
			--	local DBG_COL = {
			--		["fulgoran-defender"] = {0,0,1}, ["fulgoran-distractor"] = {0,1,0}, ["fulgoran-destroyer"] = {1,0,0},
			--	}
			--	if bot.valid then
			--		rendering.draw_line{from=bot, to=bot.combat_robot_owner,
			--			surface = bot.surface, width = 2, color = DBG_COL[bot.name], time_to_live=1}
			--	end
			--end
		else
			-- remove dead bots (and not distractor accidentally too!)
			vault.active_wave_bots[id] = nil
		end
	end
	
	if had_bots and vault:wave_active() == false then
		-- wave over, should only trigger once
		vault:end_wave()
	end
end

return movement