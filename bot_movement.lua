local g = require("common")
local movement = {}

-- choose bot target when it wants to switch
-- TODO: track how many bots are targeting which target and bias against it, so attacks are more spread out
---@param vault Vault
---@param bot LuaEntity
---@return LuaEntity
local function choose_next_target(vault, bot)
	local R = g.VAULT_DEFENSE_RADIUS()
	
	-- break off = got to waypoint
	local break_off = math.random() < 0.08
	local rnd = math.random()
	
	if not break_off then
		-- check for close targets
		local close = vault.entity.surface.find_entities_filtered{position=bot.position, radius=g.RETARGET_DIST, type = g.TARGETS, is_military_target=true}
		local count = #close
		if count > 0 then
			for i=1,3 do
				local idx = math.floor(rnd * (count-0.001))+1
				local targ = close[idx]
				if g.check_distance(targ.position, vault.entity.position, R) then
					return targ
				end
				rnd = math.random() -- new random to pick other target
			end
		end
		
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

-- got this from claude, Weyl sequence
-- turn ids into uniformly distributed points in [0,1)
local function weyl_hash01(id)
	local p = id * 0.618033988749895
	return p - math.floor(p)
end

-- TODO: can be optimized, by only checking bots depending on tick, and reacting to building_fully_damaged()
---@param vault Vault
function movement.update(vault)
	--local count = table_size(vault.wave_bots)
	--local had_bots = count > 0
	local had_bots = next(vault.wave_bots) ~= nil
	
	local tick = game.tick
	--local j = 1
	local target = nil
	
	for id,bot in pairs(vault.wave_bots) do
		--- experimental movement logic, should rewrite later!
		-- move all at once (robotic hivemind feeling)
		-- or move staggered
		-- or move in random intervals (including switching target if target dies)
		-- maybe switch target to closest if it dies, but move to purely random otherwise?
		-- could also divide robots into clusters and stagger clusters, might look cool
		if bot and bot.valid and bot.name ~= "distractor" then
			---@cast bot -nil
			-- form groups of bots where that all go to same target, with bots randomly breaking off
			-- switch targets on a timer, or when target defeated
			local group_idx = math.floor(id / 4)
			local group_leader = group_idx * 4
			--local switch_target = (tick % 500) == math.floor(group_leader / count * 500)
			local switch_target = (tick % 500) == math.floor(weyl_hash01(group_leader) * 500)
			
			local cur_target = bot.combat_robot_owner
			if cur_target and not cur_target.valid then cur_target = nil end
			local is_waypoint = cur_target and cur_target.name == g.WAYPOINT
			local valid_target = cur_target and cur_target.valid and (is_waypoint or cur_target.is_military_target)
			
			if switch_target or not valid_target then
				local rng = math.random()
				local break_off = rng < 0.2
				
				-- entire group to same target
				if id == group_leader or is_waypoint or break_off then
					target = choose_next_target(vault, bot)
				end
				if target and target.valid then
					-- abuse combat_robot_owner to make defenders and destroyers move to targets
					bot.combat_robot_owner = target
				end
			end
			
			--local DBG_COL = {
			--	["defender"] = {0,0,1}, ["distractor"] = {0,1,0}, ["destroyer"] = {1,0,0},
			--}
			--rendering.draw_line{from=bot, to=bot.combat_robot_owner,
			--	surface = bot.surface, width = 2, color = DBG_COL[bot.name], time_to_live=1}
		else
			-- remove dead bots
			vault.wave_bots[id] = nil
		end
	end
	
	if had_bots and vault:wave_active() == false then
		-- wave over, should only trigger once
		vault:end_wave()
	end
end

return movement