mod_name = "hexcoder-fulgoran-drones"

data:extend({
	{
		type = "double-setting",
		name = mod_name.."-vault-defense-radius",
		localised_name = "Vault Defense radius",
		localised_description = "",
		setting_type = "runtime-global",
		default_value = 60,
	},
	{
		type = "double-setting",
		name = mod_name.."-wave-freq",
		localised_name = "Wave frequency multiplier",
		localised_description = "",
		setting_type = "runtime-global",
		default_value = 1,
		minimum_value = 0.1,
		maximum_value = 50,
	},
	{
		type = "double-setting",
		name = mod_name.."-wave-size",
		localised_name = "Wave size multiplier",
		localised_description = "",
		setting_type = "runtime-global",
		default_value = 1,
		minimum_value = 0.1,
		maximum_value = 20,
	},
	{
		type = "double-setting",
		name = mod_name.."-wave-min-time",
		localised_name = "Minimum time between waves",
		localised_description = "in minutes\n1 should result in about 1 wave every 10 minutes at 5k/min mining rate",
		setting_type = "runtime-global",
		default_value = 1,
		minimum_value = 0.1,
		maximum_value = 20,
	},
	{
		type = "double-setting",
		name = mod_name.."-wave-max-time",
		localised_name = "Maximum time between waves",
		localised_description = "in minutes\nSmall waves will spawn even without mining",
		setting_type = "runtime-global",
		default_value = 8,
		minimum_value = 1,
		maximum_value = 60,
	}
})
