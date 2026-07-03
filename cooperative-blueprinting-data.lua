local lib = {}

---@class CooperativeBlueprintingModData
---@field host_name string The name of the mod that is the current Host.
---@field host_protocol_version int The protocol version of the Host mod.

---Attempt to become the Cooperative Blueprinting host. If there is already a
---Host, this does nothing. If there is no Host, this mod becomes the Host. You
---must provide the correct name of your mod as the `host_mod_name` argument.
---This function must be called unconditionally at the top level of the data
---phase.
---@param host_mod_name string The name of your mod, as it appears in `info.json`.
function lib.cooperative_blueprinting_data_phase(host_mod_name)
	if helpers.stage ~= "prototype" then
		error("cooperative_blueprinting_data_phase must be called in the data phase")
	end

	-- Check for existing host
	local cb_md_proto = data.raw["mod-data"]["cooperative-blueprinting"]
	if not cb_md_proto then
		data:extend({
			{
				type = "mod-data",
				name = "cooperative-blueprinting",
				data = {},
			},
		})
		cb_md_proto = data.raw["mod-data"]["cooperative-blueprinting"]
	end
	local cb_md = cb_md_proto.data

	if cb_md.host_name then
		log({
			"",
			"Cooperative Blueprinting data phase: host '",
			cb_md.host_name,
			"' already exists; ignoring host request from '",
			host_mod_name,
			"'",
		})
		return
	end

	cb_md.host_name = host_mod_name
	cb_md.host_protocol_version = 1
	log({ "", "Cooperative Blueprinting data phase: host set to '", host_mod_name, "'" })

	data:extend({
		{ type = "custom-event", name = "cooperative-blueprinting-v1-on_pre_build_blueprint" },
		{ type = "custom-event", name = "cooperative-blueprinting-v1-on_pre_extract" },
		{ type = "custom-event", name = "cooperative-blueprinting-v1-on_extract" },
		{ type = "custom-event", name = "cooperative-blueprinting-v1-on_post_extract" },
	})
end

return lib
