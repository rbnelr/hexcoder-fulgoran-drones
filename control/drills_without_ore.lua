local const = require("const")

-- The "drills without ore" setting (const.ALLOW_DRILLS_WITHOUT_ORE) turns require_resources_to_place off for all solid drills (prototypes/misc.lua),
-- this keeps vanilla behaviour away from vaults (release_plan 2.3): a drill or drill ghost built by a player
-- with no minable resource in its mining area and no vault within the defense radius is removed again
-- the placement preview stays green everywhere (the price of the global flag)
-- handlers are registered in control/events.lua (one handler per event per mod, on_built_entity is shared with on_entity_create)
-- on_built_entity removes it in the same tick (never rendered, no undo entry, build smoke still shows) and refunds consumed_items

local drills_without_ore = {}

-- vanilla rule for the drills misc.lua changed, plus anywhere within a vault radius
-- (resource_searching_offset is ignored, vanilla solid drills have none)
---@param surface LuaSurface
---@param proto LuaEntityPrototype mining drill
---@param quality QualityID?
---@param position MapPosition
---@return boolean
local function is_allowed(surface, proto, quality, position)
	local categories = proto.resource_categories
	if not categories or not categories["basic-solid"] then return true end -- keeps its own require_resources_to_place

	if surface.count_entities_filtered{name=const.VAULT_NAME, position=position, radius=const.VAULT_DEFENSE_RADIUS, limit=1} > 0 then
		return true
	end

	local r = proto.get_mining_drill_radius(quality)
	local x, y = position.x or position[1], position.y or position[2]
	for _,res in pairs(surface.find_entities_filtered{type="resource", area={{x-r, y-r}, {x+r, y+r}}}) do
		if categories[res.prototype.resource_category] then return true end
	end
	return false
end

-- same message and sound as the vanilla check
---@param player LuaPlayer?
---@param proto LuaEntityPrototype
---@param position MapPosition
local function notify(player, proto, position)
	if not player then return end
	player.create_local_flying_text{text={"cant-build-reason.no-resource-for-drill", proto.localised_name}, position=position}
	player.play_sound{path="utility/cannot_build"}
end

-- consumed items back to the player: into the hand first (so it doesn't run out), then the inventory, spill the rest
---@param player LuaPlayer
---@param items LuaInventory
local function refund(player, items)
	local cursor = player.cursor_stack
	for i=1,#items do
		local s = items[i]
		if s.valid_for_read then
			if cursor then
				if cursor.valid_for_read then
					if cursor.name == s.name and cursor.quality.name == s.quality.name then
						cursor.transfer_stack(s)
					end
				else
					-- last item was used up, hand shows a ghost of it
					local ghost = player.cursor_ghost
					if ghost and ghost.name.name == s.name then
						cursor.transfer_stack(s)
					end
				end
			end
			if s.valid_for_read then
				local inserted = player.insert(s)
				if inserted < s.count then
					s.count = s.count - inserted
					player.surface.spill_item_stack{position=player.position, stack=s, force=player.force, allow_belts=false}
				end
			end
		end
	end
end

---@param event EventData.on_built_entity
---@return boolean removed
function drills_without_ore.on_built_entity(event)
	local entity = event.entity
	local is_ghost = entity.type == "entity-ghost"
	local proto = is_ghost and entity.ghost_prototype or entity.prototype ---@cast proto LuaEntityPrototype
	if proto.type ~= "mining-drill" then return false end

	local surface, position = entity.surface, entity.position
	if is_allowed(surface, proto, entity.quality, position) then return false end

	local player = game.get_player(event.player_index)
	if player and not is_ghost and event.consumed_items then
		refund(player, event.consumed_items)
	end
	entity.destroy()
	notify(player, proto, position)
	return true
end

return drills_without_ore
