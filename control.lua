local const = require("const")
local profiling = const.PROFILE and require("control.profiling") or nil
if profiling then profiling.wrap_script() end -- before control.events registers the handlers
require("control.initialize")
require("control.events")
require("control.commands")
if const.DEBUG then
	require("control.tests")
end
if profiling then profiling.wrap_modules() end
