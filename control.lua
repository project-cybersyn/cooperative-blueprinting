local lib = require("cooperative-blueprinting-control")

local binds = lib.cooperative_blueprinting_control_phase()

if binds then
	for ev, fn in pairs(binds) do
		script.on_event(ev, fn)
	end
end
