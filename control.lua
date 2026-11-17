local const = require("const")
require("control.initialize")
require("control.events")
require("control.commands")
if const.DEBUG then
	require("control.tests")
end
