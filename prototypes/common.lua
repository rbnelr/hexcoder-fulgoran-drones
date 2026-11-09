local meld = require("__core__.lualib.meld")
local util = require("util")

local common = {}

-- concat lists into new list
-- does not deduplicate
---@param list any[]
---@param values any[]|any
---@return any[]
function common.list_contains(list, values)
	if type(values) == "table" then
		for _,value in pairs(values) do
			for _,item in pairs(list) do
				if value == item then
					return true
				end
			end
		end
	else
		local value = values
		for _,item in pairs(list) do
			if value == item then
				return true
			end
		end
	end
	return false
end

-- concat lists into new list
-- does not deduplicate
---@param list any[]
---@param list2 any[]
---@return any[]
function common.list_concat(list, list2)
	local new_list = {}
	for _,v in pairs(list) do
		table.insert(new_list, v)
	end
	for _,v in pairs(list2) do
		table.insert(new_list, v)
	end
	return new_list
end

-- meld.append can create duplicates and meld can't remove entries by value (eg. name)

-- Default key to match list entries by:
--   "name"                                 -> itself                (prerequisites, categories, allowed_effects)
--   {type="item", name="x", amount=1}      -> "item/x"              (ingredients, results)
--   {type="unlock-recipe", recipe="x"}     -> "unlock-recipe/x"     (technology effects)
--   {"automation-science-pack", 1}         -> "automation-science-pack" (technology unit ingredients)
-- Effects without name or recipe (eg. gun-speed) all get the same key, pass a custom key_fn for those
local function entry_key(v)
	if type(v) ~= "table" then return v end
	if v[1] ~= nil then return v[1] end
	return (v.type or "").."/"..(v.name or v.recipe or "") -- combine type+name into unique string
end

local function add_or_assign(list, values, key_fn)
	local index = {}
	for i,v in pairs(list) do
		index[key_fn(v)] = i
	end

	for _,v in pairs(values) do
		local k = key_fn(v)
		if index[k] then
			list[index[k]] = util.copy(v) -- overwrite at index
		else
			-- push at back of list, update index
			table.insert(list, util.copy(v))
			index[k] = #list
		end
	end
	return list
end

local function remove(list, values, key_fn)
	local index = {}
	for _,v in pairs(values) do
		index[key_fn(v)] = true
	end

	-- iterate backwards, table.remove shifts the following entries down
	for i = #list, 1, -1 do
		if index[key_fn(list[i])] then
			table.remove(list, i)
		end
	end
	return list
end

-- Insert or overwrite entries in a list, matched by value or "name","type"+"name","recipe" or table[1] if value is table
-- eg. add prerequisite, category or allowed_effect without duplicates
--     add or modify ingredient or result
--     technology unit ingredient (first entry eg. {"automation-science-pack", 1})
---@param values any[]
---@param key_fn? fun(entry):any
function common.meld_add_or_assign(values, key_fn)
	key_fn = key_fn or entry_key
	return meld.invoke(function(list)
		return add_or_assign(list or {}, values, key_fn)
	end)
end

-- Remove entries in a list, matched by value or "name","type"+"name","recipe" or table[1] if value is table
-- like meld_add_or_assign, removing will not leave holes in array
---@param values any[]
---@param key_fn? fun(entry):any
function common.meld_remove(values, key_fn)
	key_fn = key_fn or entry_key
	return meld.invoke(function(list)
		if list == nil then return nil end
		return remove(list, values, key_fn)
	end)
end

-- meld_remove then meld_add_or_assign, since a meld table can only have one op per key
-- eg. replace a prerequisite or science pack: prerequisites = common.meld_replace({"agricultural-science-pack"}, {"electromagnetic-science-pack"})
---@param remove_values any[]
---@param add_values any[]
---@param key_fn? fun(entry):any
function common.meld_replace(remove_values, add_values, key_fn)
	key_fn = key_fn or entry_key
	return meld.invoke(function(list)
		return add_or_assign(remove(list or {}, remove_values, key_fn), add_values, key_fn)
	end)
end

--local list = { a={"apple", "banana", {type="item", name="orange", count=3}} }
--
--meld(list, { a=common.meld_add_or_assign{"chocolate"} })
--meld(list, { a=common.meld_add_or_assign{{type="fluid", name="orange", count=1}} })
--meld(list, { a=common.meld_add_or_assign{{type="item", name="orange", count=5}} })
--
--meld(list, { a=common.meld_remove{"blah"} })
--meld(list, { a=common.meld_remove{{type="fluid", name="orange", count=1}} })
--meld(list, { a=common.meld_remove{"banana"} })

---- Deleted prototypes
-- Deleting a prototype breaks other mods that reference it (prerequisites, unlocks), hiding a tech would make its dependents unreachable
-- so delete and fix up references in all technologies. Call these in a final_fixes() hook to catch references added by other mods

-- Replace prerequisite old_name by new_names in all technologies
---@param old_name string
---@param new_names string[]
function common.replace_tech_references(old_name, new_names)
	for _,tech in pairs(data.raw["technology"]) do
		for _,prereq in pairs(tech.prerequisites or {}) do
			if prereq == old_name then
				meld(tech, { prerequisites = common.meld_replace({old_name}, new_names) })
				break
			end
		end
	end
end

-- Remove all technology effects (unlock-recipe, change-recipe-productivity) referencing the recipes
---@param recipe_names string[]
function common.remove_recipe_references(recipe_names)
	local names = {}
	for _,n in pairs(recipe_names) do
		names[n] = true
	end
	for _,tech in pairs(data.raw["technology"]) do
		local effects = tech.effects
		if effects then
			for i = #effects, 1, -1 do
				if names[effects[i].recipe] then
					table.remove(effects, i)
				end
			end
		end
	end
end

return common
