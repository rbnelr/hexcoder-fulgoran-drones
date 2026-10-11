local g = require("common")
local dmg = {}

local RESTORED_HP = 2.0/3 -- 2/3 is where HP bar becomes green

-- TODO: LuaEntity.protected is this relevant?

-- fully damaged -> disable, show status and make non military to stop attacks
---@param id unit_number
---@param e LuaEntity
---@param force LuaForce
function dmg.building_fully_damaged(id, e, force)
	
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
function dmg.building_partially_repaired(id, e)
	e.is_military_target = true
	--storage.marked_military[id] = e
end

-- reset building
-- either because building was restored by sufficient repair
-- or building was destroyed or we otherwise want to reset it
-- this may get called with buildings we didn't actually touch, safe except for other mods trying to use disabled_by_script
-- could kinda fix this by tracking which buildings we modify, but not 100% safe either
---@param id unit_number
---@param e LuaEntity?
---@param data Damaged?
---@param is_military_target boolean?
function dmg.restore_building(id, e, data, is_military_target)
	if e and e.valid and e.surface.name == "fulgora" then -- at least restrict to fulgora
		e.is_military_target = is_military_target or false -- TODO: may be incorrect if the building was a military_target originally (only turrets?), but probably irrelevant
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

-- fix stuck disabled_by_script or icons, probably happening only during development
---@param id unit_number
---@param e LuaEntity
function dmg.fix_building(id, e)
	if e.disabled_by_script and e.health >= e.max_health*RESTORED_HP then -- somehow got stuck disabled despite enough HP
		local data = storage.poll_repaired[id]
		dmg.restore_building(id, e, data, false) -- TODO: Should this be true, not false?
	end
end
function dmg.fix_all_icons()
	for _,r in pairs(rendering.get_all_objects(g.MOD_NAME)) do
		if r.type == "sprite" and r.sprite == "virtual-signal/signal-explosion" then
			local e = r.target.type == "entity" and r.target.entity ---@cast e LuaEntity
			if not (e.valid and e.disabled_by_script) then
				r.destroy()
			end
		end
	end
end

dmg.event_filter = {}
dmg.on_dmg_filter = {}
for _,type in pairs(g.TARGETS) do
	table.insert(dmg.event_filter, {filter="type", type=type})
	
	table.insert(dmg.on_dmg_filter, {filter="type", type=type})
	table.insert(dmg.on_dmg_filter, {filter="final-health", value=1, comparison="<=", mode="and"})
end

function dmg.on_entity_damaged(event)
	init()
	--game.print("on_entity_damaged: ".. serpent.line(event))
	
	local force = event.force
	local e = event.entity
	if not (e and e.valid) then return end
	local id = e.unit_number ---@cast id -nil
	if force and force.name == g.DRONE_FORCE then
		dmg.building_fully_damaged(id, e, force)
		e.health = 1 -- hp was <=1, setting it to 1 cancels building being killed
		-- if we want buildings to be disabled at >0 HP already, should use individual thresholds in on_entity_damaged filter
		--e.health = math.max(1, e.max_health * 0.1)
	else
		-- likely player killed the building
		-- on_entity_died will 
	end
end

---@param e LuaEntity
function dmg.on_entity_event(e)
	init()
	dmg.restore_building(e.unit_number, e, nil, false) -- TODO: why false here?, I guess I try to keep buildings non-military while no attack is active
end

---@param event EventData.on_tick
function dmg.on_tick(event)
	-- reset drone hostility (workaround)
	if storage.friend_end_tick ~= nil and event.tick >= storage.friend_end_tick then
		game.forces[g.DRONE_FORCE].set_friend("player", false)
		storage.friend_end_tick = nil
	end
	
	local id = storage.poll_prev
	for i = 1,g.REPAIR_POLL_LIMIT do
		id, data = next(storage.poll_repaired or {}, id)
		if id == nil then break end
		local e = data.entity
		if not e.valid then
			storage.poll_repaired[id] = nil -- apparently safe to do (?)
		elseif e.health >= e.max_health*RESTORED_HP then
			-- apparently deleting is safe with next() iteration, not sure if also if inserting inbetween
			-- but worst case next returns nil, which restarts iteration(?)
			dmg.restore_building(id, e, data, true) -- this has to be the actual LuaEntity, not a new one!
		elseif e.health > 1 then
			dmg.building_partially_repaired(id, e)
		end
	end
	storage.poll_prev = id
end

return dmg