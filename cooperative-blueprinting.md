# Cooperative Blueprinting

Cooperative Blueprinting is an attempt to create community-driven fixes for a few gaps in the Factorio API for mods that deal with blueprints. Given that 2.1 is likely to be the last major revision of the Factorio API, it is down to us to fix these issues ourselves. Cooperative Blueprinting is **a specification for a documented and stable community API to solve the issues described in detail below.**

Cooperative Blueprinting is called *cooperative* because it relies on the voluntary participation of mod authors; mods that use scripts to edit or deploy blueprints without using the cooperative protocol can simply re-surface the issues the protocol is designed to fix.

I hope that affected mod authors (which should hopefully be very few in number) will consider and adopt this protocol.

## Do I need Cooperative Blueprinting?

The good news is that **99.99% of Factorio mods don't need to think about this at all** and that probably includes your mod. Unless your mod has a nontrivial control phase and:

1) calls one of the following Factorio API methods on a `LuaRecord` or `LuaItemStack`:

- `build_blueprint`
- `create_blueprint`
- `clear_blueprint`
- `set_blueprint_entities`
- `set_blueprint_entity_tag`
- `set_blueprint_entity_tags`

**-OR-**

2) listens to the following Factorio events:

- `on_pre_build` (but only if using it *specifically* to examine blueprints being built)
- `on_player_setup_blueprint`

*...you don't need Cooperative Blueprinting* and you need read no further.

## I *am* using these methods or events -- *why* do I need Cooperative Blueprinting?

Cooperative Blueprinting is designed to solve four very specific issues:

1) If one mod edits a blueprint during blueprint setup using `set_blueprint_entities`, this clobbers data for mods running later in the load order. In particular they will not be able to make use of the `mapping` from blueprint to world entities. (This issue is actually documented in the Factorio API docs.)

2) The `on_pre_build` event is a mod's only opportunity to calculate things like blueprint geometry, overlaps, and world positions. However, when a blueprint is built by a script using `build_blueprint` *there is no `pre_build` event.* This breaks mods that were doing important computations in pre_build.

3) The `on_player_setup_blueprint` event is a mod's only chance to make needed alterations to a blueprint before it becomes saved. However, as the name implies, this event only takes place when a *player* sets up a blueprint. Scripted blueprint creation, such as mods using `create_blueprint`, never calls this event and therefore data is lost whenever a scripted BP is created.

4) Mutations to a blueprint are non-atomic with respect to the entities in the blueprint and can cause invalidation or reordering of indices, which are unfortunately also the keys into the blueprint. Stable keys and atomic mutations are needed to ensure one mod doesn't clobber another mod's edits.

If all mods involved in the blueprinting chain are using the Cooperative Blueprinting protocol, *all of these issues are fixed.*

## Okay, you sold me, *how* do I use Cooperative Blueprinting?

Because Cooperative Blueprinting needs to respond to Factorio events and raise custom events of its own, it needs to run inside of exactly one mod's control phase. This mod is called the **Host**. There are three ways to obtain a Host:

1) **If your mod already depends on a Host mod, you already have a Host.** The following library mods are already Cooperative Blueprinting Hosts and if you are depending on any of them, you already have full access to Cooperative Blueprinting. Some of those libraries are: (Note to library authors: feel free to submit a PR on this file if you want to add your mod to the list)
- Things `0-things`
- BPLib `bplib`

2) **You can add a dependency on `0-cooperative-blueprinting`.** This is a minimal and efficient Cooperative Blueprinting Host that only implements the protocol with no excess fluff or on-tick code.

3) **You can self-Host by embedding a Host implementation in your own mod.** Because everyone hates dependencies, right? This is a more advanced option and you **MUST** read [Technical: Hosting](#technical-hosting) to learn how to implement it properly.

Once you have a Host, you must **replace each use of the above API calls and events with Cooperative Blueprinting replacements, as documented below:**

## Blueprint Creation and Construction

If using `build_blueprint` or `create_blueprint`, you need only replace these method calls with the below remote API calls. These new API calls are very close to drop-in replacements for the native calls. They have the same arguments and effect as the base game calls, but will raise the "missing" events to allow other mods to recognize that your script is engaging with a blueprint.

```lua
---Replaces the operation of `LuaItemStack|LuaRecord.build_blueprint` with a version that raises the `on_pre_build_blueprint` event before building the blueprint. This allows mods to inspect the blueprint before it is built.
---@param blueprintish LuaItemStack|LuaRecord
---@param build_blueprint_args LuaRecord.build_blueprint_param The arguments to pass to the native `build_blueprint` function. `raised_built` will be set to `true` unless explicitly passed as `false`.
---@return LuaEntity[]? entities The array of created ghosts returned by native `build_blueprint`.
local entities = remote.call("cooperative-blueprinting-v1", "build_blueprint", blueprintish, build_blueprint_args)
```

```lua
---Replaces the operation of `LuaItemStack|LuaRecord.create_blueprint` with a version that performs the Cooperative Blueprinting extraction process.
---@param blueprintish LuaItemStack|LuaRecord The blueprint to setup. Note that this must be a blueprint in a setupable state (valid to call native `create_blueprint` on).
---@param create_blueprint_args LuaRecord.create_blueprint_param
remote.call("cooperative-blueprinting-v1", "create_blueprint", blueprintish, create_blueprint_args)
```

> [!NOTE]
> If you need to perform local edits on the blueprint created by `create_blueprint`, do not do so inline with this call.
> Instead, you must use the [extraction event](#event-cooperative-blueprinting-v1-on_extract) to perform your edits atomically.


## The `on_pre_build_blueprint` event

The Cooperative Blueprint Host raises a custom event named `cooperative-blueprinting-v1-on_pre_build_blueprint` when a blueprint is pre-built, whether by player or script. If you are using `on_pre_build` to read blueprint data, you must replace it with this event.

> [!WARNING]
> This event does NOT completely replace the `on_pre_build` event. It is ONLY called when a blueprint is being prebuilt. For pre-building of non-blueprint entities, you must continue to monitor Factorio's native `on_pre_build` event as you normally would.

```lua
---Information given about the orientation of a blueprint when being placed.
---This matches e.g. the `on_pre_build` event data.
---@class (exact) CooperativeBlueprinting.BlueprintOrientationData
---@field position MapPosition The position where the blueprint is being built.
---@field direction defines.direction The direction in which the blueprint is being built.
---@field flip_horizontal? boolean Whether the blueprint is being flipped horizontally.
---@field flip_vertical? boolean Whether the blueprint is being flipped vertically.

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

script.on_event("cooperative-blueprinting-v1-on_pre_build_blueprint",
  ---@param event CooperativeBlueprintEditing.OnPreBuildBlueprint
  function(event)
  end
)
```

## Blueprint editing events

In Cooperative Blueprinting, mods edit blueprints by calling atomic operations during a particular custom event sequence. During the below events, you MUST use ONLY the below-specified remote API calls to read or write the blueprint.

When editing a blueprint, you have access to a stable view of the blueprint composed of *entries*. Each entry generally corresponds to a Factorio `BlueprintEntity`, however, these entries have stable keys that never change during editing. Each entry also correctly preserves its corresponding world entity from the original blueprint `mapping`. You may atomically add, delete, change, or tag entries using the below remote APIs.

Once all mods have had a chance to atomically manipulate the entries, the Cooperative Blueprinting Host performs a fixup on the blueprint (removing deleted entities, fixing wiring pointers, etc) and then calls Factorio native `set_blueprint_entities` a single time to save the final edits to the real blueprint in game.

### Event: `cooperative-blueprinting-v1-on_pre_extract`

This event fires at the beginning of a blueprint extraction, giving mods a chance to examine the unmodified blueprint before changes are made. **The blueprint is read-only during this event.**

```lua
---Event fired at the beginning of the blueprint extraction process. The blueprint is read-only at this point.
---@class CooperativeBlueprinting.OnPreExtract
---@field name defines.events
---@field tick int64
---@field blueprint_key CooperativeBlueprinting.BlueprintKey You must pass this key unmodified to the edit API methods in order to access the blueprint.
```

### Event: `cooperative-blueprinting-v1-on_extract`

This is the primary event during which mods can perform atomic blueprint editing.

```lua
---@class CooperativeBlueprinting.OnExtract
---@field name defines.events
---@field tick int64
---@field blueprint_key CooperativeBlueprinting.BlueprintKey You must pass this key unmodified to the edit API methods in order to access the blueprint.
```

### Event: `cooperative-blueprinting-v1-on_post_extract`

This event is for infrastructure mods like Things to perform specialized blueprint fixup that depends on the final indices of blueprint entities.

> [!WARNING]
> Mods using this event incorrectly will defeat the purpose of cooperative editing. This is not "I want my mod to run after your mod." If you don't have a clear and complete understanding of why you need this event, you mustn't use it. This event will be removed from the public spec if it is abused in ways that break cooperating mods.

Atomic operations can no longer be used in this phase. `set_blueprint_entities` MUST NOT be used in this phase. Only `set_blueprint_entity_tag` and `set_blueprint_entity_tags` are permitted here.

```lua
---@class CooperativeBlueprinting.OnPostExtract
---@field name defines.events
---@field tick int64
---@field blueprint LuaItemStack|LuaRecord The blueprint that was extracted.
---@field mapping table<uint32, LuaEntity> The mapping from blueprint entity indices to world entity indices after extraction. This may be different from the original mapping if the blueprint was modified during extraction.
```

## Blueprint editing operations

The following operations may be called during `on_pre_extract` (read operations) and `on_extract` (both read and write operations) using the supplied `blueprint_key` to access and edit the blueprint.

The methods operate on `Entry`s that have the following type signature:
```lua
---@class CooperativeBlueprinting.Entry
---@field blueprint_entity BlueprintEntity The Factorio blueprint entity.
---@field world_entity LuaEntity? The entity in the world that this entry corresponds to, if it exists.
---@field index uint The fixed index of this entry among the entries
```
Every `Entry` has a stable index and mapping to its corresponding world entity.

These methods may not be called asynchronously and will raise errors if so. They MUST be called in-line with the corresponding extraction events.

These methods are all available on the remote interface `cooperative-blueprinting-v1`:

```lua
---Get the entries of the blueprint being extracted. (Read)
---@param key CooperativeBlueprinting.BlueprintKey
---@param filter? CooperativeBlueprinting.EntryFilter Filter to select which entries to return. If omitted, all entries are returned.
---@return CooperativeBlueprinting.Entry[] entries The entries of the blueprint being extracted.
function remote_interface.get_entries(key, filter)
end

---Get the number of entries in the blueprint being extracted. (Read)
---@param key CooperativeBlueprinting.BlueprintKey
---@return uint num_entries The number of entries in the blueprint being extracted.
function remote_interface.get_num_entries(key)
end

---Get a specific entry of the blueprint being extracted. (Read)
---and can ONLY be called SYNCHRONOUSLY during `on_pre_extract` or `on_extract`
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to retrieve.
---@return CooperativeBlueprinting.Entry? entry The entry at the given index, or `nil` if the index is out of bounds.
function remote_interface.get_entry(key, index)
end

---Get a tag of a specific entry of the blueprint being extracted. (Read)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to retrieve.
---@param tag string The tag to retrieve from the entry.
---@return AnyBasic? value The value of the tag, or `nil` if the entity or tag does not exist.
function remote_interface.get_tag(key, index, tag)
end

---Get the tags of a specific entry of the blueprint being extracted. (Read)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to retrieve.
function remote_interface.get_tags(key, index)
end

---Set a tag on a specific entry of the blueprint being extracted. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to modify.
---@param tag string The tag to set on the entry.
---@param value AnyBasic? The value to set for the tag. If `nil`, the tag is removed.
---@return boolean success Whether the tag was set successfully. Returns `false` if the entry does not exist or has been deleted.
function remote_interface.set_tag(key, index, tag, value)
end

---Set the tags on a specific entry of the blueprint being extracted. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to modify.
---@param tags Tags? The tags to set on the entry. If `nil`, all tags are removed.
---@return boolean success Whether the tags were set successfully. Returns `false` if the entry does not exist or has been deleted.
function remote_interface.set_tags(key, index, tags)
end

---Shallow merge the given tags with the entry's existing tags. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to modify.
---@param tags Tags The tags to merge with the entry's existing tags.
---@return boolean success Whether the tags were merged successfully. Returns `false` if the entry does not exist or has been deleted.
function remote_interface.merge_tags(key, index, tags)
end

---Delete a specific entry of the blueprint being extracted. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to delete.
---@return boolean success Whether the entry was deleted successfully. Returns `false` if the entry does not exist or has already been deleted.
function remote_interface.delete(key, index)
end

---Insert a new entry into the blueprint being extracted. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param blueprint_entity BlueprintEntity The blueprint entity to insert.
---@param world_entity LuaEntity? The world entity to associate with the blueprint entity if any. If `nil`, the entry will be considered to have no associated world entity.
---@return boolean success Whether the entry was inserted successfully. Returns `false` if the entry could not be inserted.
function remote_interface.insert(key, blueprint_entity, world_entity)
end

---Replace the entity data of an entry without changing its index. (Write)
---@param key CooperativeBlueprinting.BlueprintKey
---@param index uint The index of the entry to replace.
---@param blueprint_entity Partial<BlueprintEntity> The new blueprint entity to set. If new values for position, orientation and wiring are not given, the old values will be preserved.
---@param world_entity LuaEntity? The new world entity to associate with the blueprint entity if any. If `nil`, the entry will be considered to have no associated world entity.
function remote_interface.replace(key, index, blueprint_entity, world_entity)
end

```

## Technical: Hosting

**NOTE: You can stop reading here unless you are trying to write a Cooperative Blueprinting Host mod. Normal users of Cooperative Blueprinting need not worry about this.**

### Embedding the Code

You need two files from https://github.com/project-cybersyn/cooperative-blueprinting: `cooperative-blueprinting-data.lua` and `cooperative-blueprinting-control.lua`

I would recommend embedding the `cooperative-blueprinting` repo as a Git submodule so as to keep updated with fixes and features, but you may also embed the files directly.

### Data Phase

Because the Host is a "highlander", there is a protocol for choosing exactly one Host in the presence of multiple potentials. In general, the earlier the host is in the load order the better, so the protocol is basically "whoever loads first."

This is automatically handled by the data phase code. You can just call it from your `data.lua`:

```lua
-- data.lua
local cbp = require("cooperative-blueprinting-data")
cbp.cooperative_blueprinting_data_phase("your-mod-name")
```

### Control Phase

The control phase code will automatically determine if your mod was chosen to Host and implement the protocols accordingly. In your `control.lua`:

```lua
-- control.lua
local cbp = require("cooperative-blueprinting-control")
local binds = cbp.cooperative_blueprinting_control_phase()
if binds then
  for event, handler in pairs(binds) do
    script.on_event(event, handler)
  end
end
```

You may use other methods of binding events as appropriate. CBP's event handlers MUST recieve complete unfiltered event streams.
