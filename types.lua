---Information given about the orientation of a blueprint when being placed.
---This matches e.g. the `on_pre_build` event data.
---@class (exact) CooperativeBlueprinting.BlueprintOrientationData
---@field position MapPosition The position where the blueprint is being built.
---@field direction defines.direction The direction in which the blueprint is being built.
---@field flip_horizontal? boolean Whether the blueprint is being flipped horizontally.
---@field flip_vertical? boolean Whether the blueprint is being flipped vertically.

---Opaque reference to a blueprint being edited.
---@class (exact) CooperativeBlueprinting.BlueprintKey

---Event fired when a blueprint is being prebuilt.
---@class CooperativeBlueprinting.OnPreBuildBlueprint
---@field name defines.events
---@field tick int64
---@field blueprint LuaItemStack|LuaRecord The blueprint being prebuilt.
---@field force_index int The force of the blueprint being prebuilt.
---@field player_index? int If present, the player who prebuilt the blueprint. If absent, the blueprint is built by script.
---@field surface_index int The index of the surface where the blueprint was built
---@field orientation CooperativeBlueprinting.BlueprintOrientationData The orientation in which the blueprint was built.
---@field build_mode defines.build_mode The build mode.

---Event fired at the beginning of the blueprint extraction process. The blueprint is read-only at this point.
---@class CooperativeBlueprinting.OnPreExtract
---@field name defines.events
---@field tick int64
---@field blueprint_key CooperativeBlueprinting.BlueprintKey You must pass this key unmodified to the edit API methods in order to access the blueprint.

---@class CooperativeBlueprinting.OnExtract
---@field name defines.events
---@field tick int64
---@field blueprint_key CooperativeBlueprinting.BlueprintKey You must pass this key unmodified to the edit API methods in order to access the blueprint.

---@class CooperativeBlueprinting.OnPostExtract
---@field name defines.events
---@field tick int64
---@field blueprint LuaItemStack|LuaRecord The blueprint that was extracted.

---@class CooperativeBlueprinting.Entry
---@field blueprint_entity BlueprintEntity The Factorio blueprint entity.
---@field world_entity LuaEntity? The entity in the world that this entry corresponds to, if it exists.
---@field index uint The fixed index of this entry among the entries
---@field deleted boolean? If `true`, this entry has been deleted and will not be present in the final blueprint.
---@field retagged boolean? If `true`, this entry's tags have been modified.
---@field spliced boolean? If `true`, this entry has been modified in a way that requires the blueprint to be rewritten. This will always be true when `deleted` is true, but may also be true for other modifications.

---@alias CooperativeBlueprinting.EventBindings table<defines.events, function>

---@class (exact) CooperativeBlueprinting.EntryFilter
