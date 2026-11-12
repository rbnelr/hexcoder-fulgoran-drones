local const = require("const")
local meld = require("__core__.lualib.meld")

local scrap = {}

function scrap.data()
	
end

function scrap.data_updates()
	-- always defined (hidden when off), so turning the setting off does not delete existing vault-scrap, control converts it back
	data:extend{
		meld(table.deepcopy(data.raw["resource"]["scrap"]), {
			name = "vault-scrap",
			hidden = not const.INF_SCRAP_ENABLED,
			localised_name = {"", {"entity-name.scrap"}, " (Vault)"},
			order = "a[scrap]-a[scrap]-b[inf-vault]",
			--hidden = true,
			--hidden_from_player_crafting = true,
			--hidden_in_factoriopedia = true,
			--factoriopedia_alternative = "scrap",
			icon = meld.delete(),
			icons = {
				{ icon = data.raw["resource"]["scrap"].icon,
				  icon_size = 64, scale = .5 },
				{ icon = data.raw["simple-entity"][const.VAULT_NAME].icon,
				  icon_size = 64, scale = .25, shift = {5, 10} },
			},
			--minable = {
			--	mining_time = 1.25, -- was 0.5
			--	result = meld.delete(),
			--	results = {{
			--		type="item",
			--		name = "scrap",
			--		amount_min = 1,
			--		amount_max = 4, -- avg 2.5
			--	}}
			--},
			minable = {
				-- keep the same to try and make finite and infine mining similar with the same numbers
				mining_time = 0.5, -- was 0.5
			},

			infinite = true,

			-- ~20M vault patches
			-- individual fulgora vault scrap tiles seem to average around 100k
			-- with normal = 50k, we get faster mining initially, then slower mining later
			-- TODO: estimate time until hitting minimum (not too long if quality is tied to this)
			-- TODO: test other mapgen settings (siZe/richness) to see if they break things (low richness giving high quality instantly?)

			minimum = 10000, -- min 20% like crude oil
			normal =  50000,
			-- make reaching minimum yield quicker with same totals and yield curve
			infinite_depletion_amount = const.INF_DEPLETION_RATE,
		})
	}

	-- split the scrap autoplace into normal scrap and vault-scrap (vault islands only)
	-- fulgora_vaults_and_starting_vault is 0 or 1 (built only from comparisons), so positions and amounts stay identical, only the type changes
	-- existing surfaces keep their own map_gen_settings, control (recreate_fulgora.update_autoplace_settings) adds/removes vault-scrap there
	local VAULT_MASK_NOISE = "fulgora_vaults_and_starting_vault"
	local scrap_res = data.raw["resource"]["scrap"]
	local vault_scrap = data.raw["resource"]["vault-scrap"]
	if const.INF_SCRAP_ENABLED and scrap_res.autoplace then
		local prob = tostring(scrap_res.autoplace.probability_expression)

		vault_scrap.autoplace = table.deepcopy(scrap_res.autoplace)
		vault_scrap.autoplace.probability_expression = "("..prob..") * "..VAULT_MASK_NOISE
		scrap_res.autoplace.probability_expression = "("..prob..") * (1 - "..VAULT_MASK_NOISE..")"

		local entity_settings = data.raw["planet"]["fulgora"].map_gen_settings.autoplace_settings.entity.settings
		entity_settings["vault-scrap"] = entity_settings["scrap"] or {}
	else
		-- no autoplace when off, the prototype only exists so existing vault-scrap can be converted back
		vault_scrap.autoplace = nil
	end
end

return scrap
