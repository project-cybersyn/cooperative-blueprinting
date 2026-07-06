-- Control-phase for cooperative blueprinting.

local lib = {}

--------------------------------------------------------------------------------
-- UTILS
--------------------------------------------------------------------------------

local INT32_MAX = 2 ^ 31 - 1

local EMPTY = setmetatable({}, {
	__newindex = function() end,
	__metatable = false,
})

---Shallowly copies each given table into `dest`, returning `dest`.
---@generic T extends ({[any]: any} | table)
---@param dest T
---@param ... any
---@return T dest
local function assign(dest, ...)
	local n = select("#", ...)
	if n == 0 then return dest end
	for i = 1, n do
		local src = select(i, ...)
		if type(src) == "table" then
			for k, v in pairs(src) do
				dest[k] = v
			end
		end
	end
	return dest
end

---@param player_identification PlayerIdentification?
---@return int? player_index
local function player_identification_to_index(player_identification)
	if not player_identification then return nil end
	if type(player_identification) == "userdata" then
		return player_identification.index
	else
		---@diagnostic disable-next-line: param-type-mismatch
		local player = game.get_player(player_identification)
		if player then return player.index end
	end
end

---@param surface_identification SurfaceIdentification?
---@return int? surface_index
local function surface_identification_to_index(surface_identification)
	if not surface_identification then return nil end
	if type(surface_identification) == "userdata" then
		return surface_identification.index
	else
		---@diagnostic disable-next-line: param-type-mismatch
		local surface = game.get_surface(surface_identification)
		if surface then return surface.index end
	end
end

---@param force_identification ForceID?
---@return int? force_index
local function force_identification_to_index(force_identification)
	if not force_identification then return nil end
	if type(force_identification) == "userdata" then
		return force_identification.index
	else
		local force = game.forces[force_identification]
		if force then return force.index end
	end
end

---@param player LuaPlayer The player who is manipulating the blueprint.
---@param record? LuaRecord
---@param stack? LuaItemStack
---@return (LuaRecord|LuaItemStack)? blueprintish The actual blueprint involved, stripped of any containing books or nil if not found.
local function get_actual_blueprint(player, record, stack)
	if record then
		while record and record.type == "blueprint-book" do
			record = record.get_selected_record(player)
		end
		if record and not record.is_preview and record.type == "blueprint" then
			return record
		end
	elseif stack then
		if not stack.valid_for_read then return end
		while stack and stack.is_blueprint_book do
			local main_inventory = stack.get_inventory(defines.inventory.item_main)
			if not main_inventory then return end
			stack = main_inventory[
				stack.active_index --[[@as uint]]
			]
		end
		if stack and stack.is_blueprint then return stack end
	end
end

--------------------------------------------------------------------------------
-- PREBUILD
--------------------------------------------------------------------------------

---@param ev EventData.on_pre_build
local function on_pre_build(ev)
	local player = game.get_player(ev.player_index)
	if not player then return end
	if not player.is_cursor_blueprint() then return end
	local bp =
		get_actual_blueprint(player, player.cursor_record, player.cursor_stack)
	if not bp then return end

	---@type CooperativeBlueprinting.BlueprintOrientationData
	local orientation = {
		position = ev.position,
		direction = ev.direction,
		flip_horizontal = ev.flip_horizontal,
		flip_vertical = ev.flip_vertical,
	}

	---@diagnostic disable-next-line: missing-fields
	---@type CooperativeBlueprinting.OnPreBuildBlueprint
	local prebuild_ev = {
		blueprint = bp,
		player_index = ev.player_index,
		surface_index = player.surface.index,
		orientation = orientation,
		build_mode = ev.build_mode or defines.build_mode.normal,
		force_index = player.force_index,
	}
	script.raise_event(
		"cooperative-blueprinting-v1-on_pre_build_blueprint",
		prebuild_ev
	)
end

--------------------------------------------------------------------------------
-- EXTRACTION
--------------------------------------------------------------------------------

---@class CooperativeBlueprinting.ExtractionState
---@field blueprint_key CooperativeBlueprinting.BlueprintKey The key of the blueprint being extracted.
---@field entries CooperativeBlueprinting.Entry[] The entries of the blueprint being extracted.
---@field blueprintish LuaItemStack|LuaRecord The blueprint being extracted.
---@field original_mapping table<uint32, LuaEntity> The original mapping from blueprint entity indices to world entity indices.
---@field new_entities BlueprintEntity[]? The new blueprint entities after splicing, if any.
---@field new_mapping table<uint32, LuaEntity>? The new mapping from blueprint entity indices to world entity indices after splicing, if any.
---@field readable boolean? Whether read operations on entries are allowed.
---@field writable boolean? Whether write operations on entries are allowed.
---@field spliced boolean? Whether an edit has been made that requires the blueprint to be altogether rewritten.
local extraction_state = {}

---@param blueprintish LuaItemStack|LuaRecord
---@param map table<uint32, LuaEntity>
local function begin_extraction(blueprintish, map)
	---@type CooperativeBlueprinting.Entry[]
	local entries = {}
	local bp_entities = blueprintish.get_blueprint_entities() or {}
	for i, bp_entity in ipairs(bp_entities) do
		local world_entity = map[bp_entity.entity_number]
		entries[i] = {
			blueprint_entity = bp_entity,
			world_entity = world_entity,
			index = i,
		}
	end
	extraction_state = {
		blueprint_key = math.random(1, INT32_MAX) --[[@as CooperativeBlueprinting.BlueprintKey]],
		entries = entries,
		blueprintish = blueprintish,
		original_mapping = map,
	}
end

local function end_extraction() extraction_state = {} end

local function fixup_extraction()
	if not extraction_state.spliced then return end

	-- Splice when needed. Keep track of entry index to new
	-- blueprint index mapping
	---@type BlueprintEntity[]
	local new_bp_entities = {}
	---@type table<uint32, LuaEntity>
	local new_mapping = {}
	---@type table<uint, uint>
	local old_to_new_index = {}
	for i, entry in ipairs(extraction_state.entries) do
		if not entry.deleted then
			local new_index = #new_bp_entities + 1
			new_bp_entities[new_index] = entry.blueprint_entity
			new_mapping[new_index] = entry.world_entity
			old_to_new_index[i] = new_index
		end
	end

	-- For each entry, fixup wire connectors that refer to old indices to refer to new indices. If the old index was deleted, remove the wire.
	for _, entity in ipairs(new_bp_entities) do
		if entity.wires and next(entity.wires) then
			---@type BlueprintWire[]
			local new_wires = {}
			for _, wire in pairs(entity.wires) do
				local new_source = old_to_new_index[wire[1]]
				local new_target = old_to_new_index[wire[3]]
				if new_source and new_target then
					new_wires[#new_wires + 1] = {
						new_source,
						wire[2],
						new_target,
						wire[4],
					}
				end
			end
			entity.wires = new_wires
		end
	end

	extraction_state.blueprintish.set_blueprint_entities(new_bp_entities)
	extraction_state.new_entities = new_bp_entities
	extraction_state.new_mapping = new_mapping
end

local function post_extraction()
	local post_ev = {
		blueprint = extraction_state.blueprintish,
	}
	if extraction_state.new_mapping then
		post_ev.mapping = extraction_state.new_mapping
	else
		post_ev.mapping = extraction_state.original_mapping
	end
	script.raise_event("cooperative-blueprinting-v1-on_post_extract", post_ev)
end

---@param blueprintish LuaItemStack|LuaRecord
---@param map table<uint32, LuaEntity>
local function extract(blueprintish, map)
	begin_extraction(blueprintish, map)

	local ev = {
		blueprint_key = extraction_state.blueprint_key,
	}
	extraction_state.readable = true
	extraction_state.writable = false
	script.raise_event("cooperative-blueprinting-v1-on_pre_extract", ev)

	extraction_state.writable = true
	script.raise_event("cooperative-blueprinting-v1-on_extract", ev)

	extraction_state.readable = false
	extraction_state.writable = false
	fixup_extraction()

	post_extraction()

	end_extraction()
end

---@param ev EventData.on_player_setup_blueprint
local function on_player_setup_blueprint(ev)
	local player = game.get_player(ev.player_index)
	if not player then return end
	local bp = get_actual_blueprint(player, ev.record, ev.stack)
	if not bp then return end
	local lazy_bp_to_world = ev.mapping
	if not lazy_bp_to_world or not lazy_bp_to_world.valid then return end
	local bp_to_world = lazy_bp_to_world.get() --[[@as table<uint32, LuaEntity>? ]]
	if not bp_to_world then return end
	extract(bp, bp_to_world)
end

--------------------------------------------------------------------------------
-- REMOTE
--------------------------------------------------------------------------------

local remote_interface = {}

---@return string
function remote_interface.get_host_name() return script.mod_name end

---Replaces the operation of `LuaItemStack|LuaRecord.build_blueprint` with a version that raises the `on_pre_build_blueprint` event before building the blueprint. This allows mods to inspect the blueprint before it is built.
---@param blueprintish LuaItemStack|LuaRecord
---@param build_blueprint_args LuaRecord.build_blueprint_param The arguments to pass to the native `build_blueprint` function. `raised_built` will be set to `true` unless explicitly passed as `false`.
---@return LuaEntity[]? entities The array of created ghosts returned by native `build_blueprint`.
function remote_interface.build_blueprint(blueprintish, build_blueprint_args)
	if build_blueprint_args.raise_built == nil then
		build_blueprint_args =
			---@diagnostic disable-next-line: missing-fields
			assign({} --[[@as LuaRecord.build_blueprint_param]], build_blueprint_args)
		build_blueprint_args.raise_built = true
	end

	---@type CooperativeBlueprinting.BlueprintOrientationData
	local orientation = {
		position = build_blueprint_args.position,
		direction = build_blueprint_args.direction or defines.direction.north,
	}

	local surface_index =
		surface_identification_to_index(build_blueprint_args.surface)
	if not surface_index then
		error("build_blueprint_args.surface must be a valid surface")
	end
	local force_index = force_identification_to_index(build_blueprint_args.force)
	if not force_index then
		error("build_blueprint_args.force must be a valid force")
	end
	local player_index =
		player_identification_to_index(build_blueprint_args.by_player)

	---@diagnostic disable-next-line: missing-fields
	---@type CooperativeBlueprinting.OnPreBuildBlueprint
	local ev = {
		blueprint = blueprintish,
		player_index = player_index,
		surface_index = surface_index,
		orientation = orientation,
		build_mode = build_blueprint_args.build_mode or defines.build_mode.normal,
		force_index = force_index,
	}
	script.raise_event("cooperative-blueprinting-v1-on_pre_build_blueprint", ev)

	return blueprintish.build_blueprint(build_blueprint_args)
end

---Replaces the operation of `LuaItemStack|LuaRecord.create_blueprint` with a version that performs the Cooperative Blueprinting extraction process.
---@param blueprintish LuaItemStack|LuaRecord The blueprint to setup. Note that this must be a blueprint in a setupable state (valid to call native `create_blueprint` on).
---@param create_blueprint_args LuaRecord.create_blueprint_param
function remote_interface.create_blueprint(blueprintish, create_blueprint_args)
	local entities = blueprintish.create_blueprint(create_blueprint_args)
	extract(blueprintish, entities)
end

---Get the entries of the blueprint being extracted. (Read)
---@param key CooperativeBlueprinting.BlueprintKey
---@param filter? CooperativeBlueprinting.EntryFilter Filter to select which entries to return. If omitted, all entries are returned.
---@return CooperativeBlueprinting.Entry[] entries The entries of the blueprint being extracted.
function remote_interface.get_entries(key, filter)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"get_entries can only be called synchronously for the blueprint being extracted"
		)
	end
	return extraction_state.entries
end

---Get the number of entries in the blueprint being extracted. (Read)
---@param key CooperativeBlueprinting.BlueprintKey
---@return uint num_entries The number of entries in the blueprint being extracted.
function remote_interface.get_num_entries(key)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"get_num_entries can only be called synchronously for the blueprint being extracted"
		)
	end
	return #extraction_state.entries
end

---Get a specific entry of the blueprint being extracted. (Read)
---and can ONLY be called SYNCHRONOUSLY during `on_pre_extract` or `on_extract`
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to retrieve.
---@return CooperativeBlueprinting.Entry? entry The entry at the given index, or `nil` if the index is out of bounds.
function remote_interface.get_entry(key, index)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"get_entry can only be called synchronously for the blueprint being extracted"
		)
	end
	return extraction_state.entries[index]
end

---Get a tag of a specific entry of the blueprint being extracted. (Read)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to retrieve.
---@param tag string The tag to retrieve from the entry.
---@return AnyBasic? value The value of the tag, or `nil` if the entity or tag does not exist.
function remote_interface.get_tag(key, index, tag)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"get_tag can only be called during on_pre_extract or on_extract for the blueprint being extracted"
		)
	end
	if not extraction_state.readable then
		error(
			"get_tag can only be called during on_pre_extract or on_extract for the blueprint being extracted"
		)
	end
	local entry = extraction_state.entries[index] --[[@as CooperativeBlueprinting.Entry? ]]
	if (not entry) or entry.deleted then return nil end
	local entry_tags = entry.blueprint_entity.tags or EMPTY
	return entry_tags[tag]
end

---Get the tags of a specific entry of the blueprint being extracted. (Read)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to retrieve.
function remote_interface.get_tags(key, index)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"get_tags can only be called during on_pre_extract or on_extract for the blueprint being extracted"
		)
	end
	if not extraction_state.readable then
		error(
			"get_tags can only be called during on_pre_extract or on_extract for the blueprint being extracted"
		)
	end
	local entry = extraction_state.entries[index] --[[@as CooperativeBlueprinting.Entry? ]]
	if (not entry) or entry.deleted then return nil end
	return entry.blueprint_entity.tags or {}
end

---Set a tag on a specific entry of the blueprint being extracted. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to modify.
---@param tag string The tag to set on the entry.
---@param value AnyBasic? The value to set for the tag. If `nil`, the tag is removed.
---@return boolean success Whether the tag was set successfully. Returns `false` if the entry does not exist or has been deleted.
function remote_interface.set_tag(key, index, tag, value)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"set_tag can only be called during on_extract for the blueprint being extracted"
		)
	end
	if not extraction_state.writable then
		error(
			"set_tag can only be called during on_extract for the blueprint being extracted"
		)
	end
	local entry = extraction_state.entries[index] --[[@as CooperativeBlueprinting.Entry? ]]
	if (not entry) or entry.deleted then return false end
	local entry_tags = entry.blueprint_entity.tags or {}
	entry_tags[tag] = value
	if next(entry_tags) then
		entry.blueprint_entity.tags = entry_tags
	else
		entry.blueprint_entity.tags = nil
	end

	if not entry.spliced then
		extraction_state.blueprintish.set_blueprint_entity_tags(
			entry.index,
			entry_tags
		)
	end

	entry.retagged = true
	return true
end

---Set the tags on a specific entry of the blueprint being extracted. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to modify.
---@param tags Tags? The tags to set on the entry. If `nil`, all tags are removed.
---@return boolean success Whether the tags were set successfully. Returns `false` if the entry does not exist or has been deleted.
function remote_interface.set_tags(key, index, tags)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"set_tags can only be called during on_extract for the blueprint being extracted"
		)
	end
	if not extraction_state.writable then
		error(
			"set_tags can only be called during on_extract for the blueprint being extracted"
		)
	end
	local entry = extraction_state.entries[index] --[[@as CooperativeBlueprinting.Entry? ]]
	if (not entry) or entry.deleted then return false end
	entry.blueprint_entity.tags = tags

	if not entry.spliced then
		extraction_state.blueprintish.set_blueprint_entity_tags(
			entry.index,
			tags or {}
		)
	end

	entry.retagged = true
	return true
end

---Shallow merge the given tags with the entry's existing tags. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to modify.
---@param tags Tags The tags to merge with the entry's existing tags.
---@return boolean success Whether the tags were merged successfully. Returns `false` if the entry does not exist or has been deleted.
function remote_interface.merge_tags(key, index, tags)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"merge_tags can only be called during on_extract for the blueprint being extracted"
		)
	end
	if not extraction_state.writable then
		error(
			"merge_tags can only be called during on_extract for the blueprint being extracted"
		)
	end
	local entry = extraction_state.entries[index] --[[@as CooperativeBlueprinting.Entry? ]]
	if (not entry) or entry.deleted then return false end
	local entry_tags = entry.blueprint_entity.tags or {}
	for k, v in pairs(tags) do
		entry_tags[k] = v
	end
	entry.blueprint_entity.tags = entry_tags

	if not entry.spliced then
		extraction_state.blueprintish.set_blueprint_entity_tags(
			entry.index,
			entry_tags
		)
	end

	entry.retagged = true
	return true
end

---Delete a specific entry of the blueprint being extracted. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to delete.
---@return boolean success Whether the entry was deleted successfully. Returns `false` if the entry does not exist or has already been deleted.
function remote_interface.delete(key, index)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"delete can only be called during on_extract for the blueprint being extracted"
		)
	end
	if not extraction_state.writable then
		error(
			"delete can only be called during on_extract for the blueprint being extracted"
		)
	end
	local entry = extraction_state.entries[index] --[[@as CooperativeBlueprinting.Entry? ]]
	if (not entry) or entry.deleted then return false end
	entry.deleted = true
	entry.spliced = true
	extraction_state.spliced = true
	return true
end

---Insert a new entry into the blueprint being extracted. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param blueprint_entity BlueprintEntity The blueprint entity to insert.
---@param world_entity LuaEntity? The world entity to associate with the blueprint entity if any. If `nil`, the entry will be considered to have no associated world entity.
---@return boolean success Whether the entry was inserted successfully. Returns `false` if the entry could not be inserted.
function remote_interface.insert(key, blueprint_entity, world_entity)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"insert can only be called during on_extract for the blueprint being extracted"
		)
	end
	if not extraction_state.writable then
		error(
			"insert can only be called during on_extract for the blueprint being extracted"
		)
	end
	local new_entity = assign({}, blueprint_entity) --[[@as BlueprintEntity ]]
	local new_index = #extraction_state.entries + 1
	extraction_state.entries[new_index] = {
		blueprint_entity = new_entity,
		world_entity = world_entity,
		index = new_index,
		spliced = true,
		retagged = true,
	}
	extraction_state.spliced = true
	return true
end

---Replace the entity data of an entry without changing its index. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to replace.
---@param blueprint_entity Partial<BlueprintEntity> The new blueprint entity to set. If new values for position, orientation and wiring are not given, the old values will be preserved.
---@param world_entity LuaEntity? The new world entity to associate with the blueprint entity if any. If `nil`, the entry will be considered to have no associated world entity.
function remote_interface.replace(key, index, blueprint_entity, world_entity)
	local current_key = extraction_state.blueprint_key
	if (not current_key) or (current_key ~= key) then
		error(
			"replace can only be called during on_extract for the blueprint being extracted"
		)
	end
	if not extraction_state.writable then
		error(
			"replace can only be called during on_extract for the blueprint being extracted"
		)
	end
	local entry = extraction_state.entries[index] --[[@as CooperativeBlueprinting.Entry? ]]
	if (not entry) or entry.deleted then return false end
	local old_bp_entity = entry.blueprint_entity
	local bp_entity = assign({}, blueprint_entity) --[[@as BlueprintEntity ]]
	bp_entity.entity_number = old_bp_entity.entity_number
	if not bp_entity.position then bp_entity.position = old_bp_entity.position end
	if not bp_entity.direction then
		bp_entity.direction = old_bp_entity.direction
	end
	if (not bp_entity.wires) and old_bp_entity.wires then
		bp_entity.wires = old_bp_entity.wires
	end

	entry.blueprint_entity = bp_entity
	entry.world_entity = world_entity
	entry.spliced = true
	entry.retagged = true
	extraction_state.spliced = true
	return true
end

--------------------------------------------------------------------------------
-- HOST REGISTRATION
--------------------------------------------------------------------------------

---Implement the control side of the Cooperative Blueprinting spec.
---You only need to call this function if your mod is volunteering to Host.
---You must first have called `cooperative_blueprinting_data_phase()` in the data phase to register your mod as a potential Host.
---This function MUST be called UNCONDITIONALLY at the TOP of control.lua.
---If your mod is not the chosen Host, this function will return `nil`.
---If your mod is the chosen Host, this function will return a set of
---event bindings. Your mod MUST attach these event bindings to the given
---game events using `script.on_event` or other appropriate means. Your mod
---MUST NOT filter these events.
---@return table<defines.events, function>? event_bindings
function lib.cooperative_blueprinting_control_phase()
	local cb_data_proto = prototypes.mod_data["cooperative-blueprinting"]
	local cb_data = cb_data_proto and cb_data_proto.data
	if not cb_data then
		log({
			"",
			"WARNING: Cooperative Blueprinting: '",
			script.mod_name,
			"' is volunteering to host in the control phase, but no one volunteered to host in the data phase. Did you forget to call cooperative_blueprinting_data_phase() in data.lua?",
		})
		return
	end

	if cb_data.host_name ~= script.mod_name then
		log({
			"",
			"Cooperative Blueprinting control phase: host is '",
			cb_data.host_name,
			"'; eliding '",
			script.mod_name,
			"' control host registration.",
		})
		return
	end

	-- OK, I am the host.
	log({
		"",
		"Cooperative Blueprinting control phase: host is '",
		cb_data.host_name,
		"'; that's me! Registering control host.",
	})

	remote.add_interface("cooperative-blueprinting-v1", remote_interface)

	return {
		[defines.events.on_player_setup_blueprint] = on_player_setup_blueprint,
		[defines.events.on_pre_build] = on_pre_build,
	}
end

return lib
