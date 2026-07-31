
local dmg = {}

-- TODO: LuaEntity.protected is this relevant?

-- fully damaged -> disable, show status and make non military to stop attacks
---@param id unit_number
---@param e LuaEntity
---@param force LuaForce
local function building_fully_damaged(id, e, force)
	
	e.is_military_target = false
	--storage.marked_military[id] = nil
	
	e.disabled_by_script = true
	e.custom_status = {
		diode=defines.entity_status_diode.red,
		label="damaged by drones"
	}
	
	-- workaround to stop drones getting stuck attacking this target
	-- make drone force non-hostile
	force.set_friend("player", true)
	storage.friend_end_tick = game.tick + 2 -- 1 tick not enough
	
	-- start polling disabled building for repairs due to lack of on_entity_repaired API
	local poll = storage.poll_repaired
	
	local data = poll[id]
	if not data then
		local status_icon = rendering.draw_sprite{
			sprite = "virtual-signal/signal-explosion",
			tint = {1.0,0.85,0,1.0},
			x_scale = 1.7, y_scale = 1.7,
			render_layer = "entity-info-icon-above",
			blink_interval = 30,
			target = e,
			surface = e.surface,
			render_mode = "game",
			only_in_alt_mode = true,
		}
		
		poll[id] = { entity = e, icon = status_icon }
	end
end
-- repairing makes building a valid target again
---@param id unit_number
---@param e LuaEntity
local function building_partially_repaired(id, e)
	e.is_military_target = true
	--storage.marked_military[id] = e
end

-- reset building
-- either because building was restored by sufficient repair
-- or building was destroyed or otherwise reset it
-- this may get called with buildings we didn't actually touch, safe except for other mods trying to use disabled_by_script
-- could kinda fix this by tracking which buildings we modify, but not 100% safe either
---@param id unit_number
---@param e LuaEntity?
---@param data Damaged?
---@param is_military_target boolean?
local function reset_building(id, e, data, is_military_target)
	if e and e.valid and e.surface.name == "fulgora" then -- at least restrict to fulgora
		e.is_military_target = is_military_target or false
		--storage.marked_military[id] = is_military_target and e or nil
		
		e.disabled_by_script = false
		if e.custom_status and e.custom_status.label == "damaged by drones" then
			e.custom_status = nil
		end
	end
	-- remove draw_sprite
	if data and data.icon then
		data.icon.destroy()
	end
	
	storage.poll_repaired[id] = nil
end

local _filter = {}
local _on_dmg_filter = {}
for _,type in pairs(TARGETS) do
	table.insert(_filter, {filter="type", type=type})
	table.insert(_on_dmg_filter, {filter="type", type=type})
	table.insert(_on_dmg_filter, {filter="final-health", value=1, comparison="<=", mode="and"})
end

script.on_event(defines.events.on_entity_damaged, function(event)
	--game.print("on_entity_damaged: ".. serpent.line(event))
	init()
	
	local force = event.force
	local e = event.entity
	if not (e and e.valid) then return end
	local id = e.unit_number ---@cast id -nil
	if force and force.name == DRONE_FORCE then
		building_fully_damaged(id, e, force)
		e.health = 1 -- hp was <=1, setting it to 1 cancels building being killed
		-- if we want buildings to be disabled at >0 HP already, should use individual thresholds in on_entity_damaged filter
		--e.health = math.max(1, e.max_health * 0.1)
	else
		-- likely player killed the building
		-- on_entity_died will 
	end
end, _on_dmg_filter)

-- I think this is needed since
for _, event in pairs({
	defines.events.on_built_entity,
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned, -- source to destination
	defines.events.on_entity_died
}) do
	script.on_event(event, function(event)
		---@type LuaEntity
		init()
		local e = event.entity or event.destination ---@diagnostic disable-line
		reset_building(e.unit_number, e, nil, false)
	end, _filter)
end

---@param event EventData.on_tick
function dmg.on_tick(event)
	-- reset drone hostility (workaround)
	if storage.friend_end_tick ~= nil and event.tick >= storage.friend_end_tick then
		game.forces[DRONE_FORCE].set_friend("player", false)
		storage.friend_end_tick = nil
	end
	
	local id = storage.poll_prev
	for i = 1,MAX_POLL do
		id, data = next(storage.poll_repaired or {}, id)
		if id == nil then break end
		local e = data.entity
		if not e.valid then
			storage.poll_repaired[id] = nil -- apparently safe to do (?)
		elseif e.health >= e.max_health*0.666666667 then -- 2/3 is where HP bar becomes green
			-- apparently deleting is safe with next() iteration, not sure if also if inserting inbetween
			-- but worst case next returns nil, which restarts iteration(?)
			reset_building(id, e, data, true) -- this has to be the actual LuaEntity, not a new one!
		elseif e.health > 1 then
			building_partially_repaired(id, e)
		end
	end
	storage.poll_prev = id
end

--script.on_event(defines.events.on_player_repaired_entity, function(event)
--	--game.print("on_player_repaired_entity: ".. serpent.line(event))
--end)

return dmg