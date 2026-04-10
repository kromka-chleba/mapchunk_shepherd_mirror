--[[
    This is a part of "Mapchunk Shepherd".
    Copyright (C) 2025 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
--]]

--[[
    DATABASE FORMAT DOCUMENTATION
    =============================

    This file manages the Mapchunk Shepherd database stored in mod storage.
    The database tracks mapchunks and their labels.

    DATABASE FORMAT VERSION 1 (Current)
    -----------------------------------

    Mod Storage Keys:
    1. "shepherd_db_version" (integer) - The version of the database format
    2. "chunksize" (integer) - The mapchunk size setting (in mapblocks)
    3. "<mapchunk_hash>" (string) - Serialized label data for each mapchunk
       - Hash is obtained via core.hash_node_position(mapchunk_min_pos)
       - Value is core.serialize of an array of {tag, timestamp} pairs
       - Example: "return {{\"chunk_tracked\", 1234}, {\"scanned\", 5678}}"

    Labels Format:
    - Each mapchunk can have multiple labels
    - Each label consists of:
      * tag (string): describes mapchunk property (e.g., "chunk_tracked", "scanned")
      * timestamp (integer): game time when label was created/modified

    Future Database Versions:
    - Version 2+: To be defined when breaking changes are needed
    - Conversion functions should be added in ms.database.convert_from_v<N>()
--]]

-- Globals
local ms = mapchunk_shepherd

local mod_path = core.get_modpath("mapchunk_shepherd")
local sizes = dofile(mod_path.."/sizes.lua")
local mod_storage = core.get_mod_storage()

-- Returns version of the Mapchunk Shepherd mod
function ms.mod_version()
    return "0.0.1"
end

ms.database = {}
local purge_callbacks = {}
local next_purge_callback_id = 0
local last_purge_event_data
local valid_purge_reasons = {
    initialize = true,
    manual = true,
    migration = true,
    unknown = true,
}
local purge_state_seq_key = "shepherd_purge_seq"
local purge_state_reason_key = "shepherd_last_purge_reason"
local purge_state_event_key = "shepherd_last_purge_event"

-- Returns the version of the shepherd database API. The value needs
-- to be adjusted every time a breaking change in the labeling system
-- is introduced.
function ms.database.version()
    return 1
end

-- Returns the version of the actual shepherd database in mod storage.
-- Returns 0 if no version is stored (uninitialized or ancient database).
function ms.database.stored_version()
    return mod_storage:get_int("shepherd_db_version")
end

-- Updates the version of the shepherd database in mod storage.
-- Should be called after successful database initialization or conversion.
function ms.database.update_version()
    mod_storage:set_int("shepherd_db_version", ms.database.version())
end

-- Checks if the database version is out of date with the API
-- version. Returns a boolean.
function ms.database.outdated()
    return ms.database.version() ~= ms.database.stored_version()
end

-- Checks if the database was properly initialized. Will return
-- `false` for new worlds or worlds created prior to this
-- compatibility mechanism. Returns `true` if the database was
-- properly initialized.
function ms.database.valid()
    return ms.database.stored_version() ~= 0
end

-- Classifies unversioned database state to distinguish a truly new world
-- from legacy/corrupt storage containing keys without a version marker.
-- Returns:
--  - "initialized" when shepherd_db_version is set
--  - "new_world" when storage is fully empty
--  - "legacy_or_corrupt" when storage has keys but no version marker
function ms.database.bootstrap_state()
    if ms.database.stored_version() ~= 0 then
        return "initialized"
    end
    local keys = mod_storage:get_keys()
    if #keys == 0 then
        return "new_world"
    end
    return "legacy_or_corrupt"
end

-- Checks if the database is too new for this version of the shepherd.
-- Returns true if stored version is higher than supported version.
function ms.database.too_new()
    local stored = ms.database.stored_version()
    return stored > 0 and stored > ms.database.version()
end

-- Reads persisted purge event data from mod storage.
-- Returns event table or nil if missing/corrupt.
local function read_stored_purge_event()
    local serialized = mod_storage:get_string(purge_state_event_key)
    if serialized == "" then
        return nil
    end
    local event = core.deserialize(serialized)
    if type(event) ~= "table" then
        core.log("warning",
                 "Mapchunk Shepherd: Stored purge event is corrupted and will be ignored.")
        return nil
    end
    return event
end

-- Returns durable purge state for migration-aware mods.
-- Contract:
-- {
--   seq = number,        -- monotonic sequence, 0 means no purge recorded yet
--   reason = string|nil, -- last purge reason
--   event = table|nil,   -- last purge event payload
-- }
function ms.database.get_purge_state()
    local seq = mod_storage:get_int(purge_state_seq_key)
    if seq < 0 then
        seq = 0
    end
    local reason = mod_storage:get_string(purge_state_reason_key)
    if reason == "" then
        reason = nil
    end
    local event = read_stored_purge_event()
    if not reason and event and type(event.reason) == "string" then
        reason = event.reason
    end
    return {
        seq = seq,
        reason = reason,
        event = event and table.copy(event) or nil,
    }
end

-- Persists durable purge marker and metadata.
local function persist_purge_state(seq, reason, event_data)
    mod_storage:set_int(purge_state_seq_key, seq)
    mod_storage:set_string(purge_state_reason_key, reason)
    mod_storage:set_string(purge_state_event_key, core.serialize(event_data))
end

-- Returns next unique numeric ID for purge callback registrations.
local function next_callback_id()
    next_purge_callback_id = next_purge_callback_id + 1
    return next_purge_callback_id
end

-- Registers callback to run after database purge.
-- callback receives one argument: purge event payload.
-- Returns callback ID that can be passed to unregister_on_purged.
function ms.database.register_on_purged(callback)
    assert(type(callback) == "function",
           "Mapchunk Shepherd: register_on_purged callback must be a function, got "..
               type(callback)..".")
    local callback_id = next_callback_id()
    purge_callbacks[callback_id] = callback
    return callback_id
end

-- Unregisters purge callback by ID returned from register_on_purged.
-- Returns true if callback existed and was removed.
function ms.database.unregister_on_purged(callback_id)
    if purge_callbacks[callback_id] == nil then
        return false
    end
    purge_callbacks[callback_id] = nil
    return true
end

-- Returns data of the most recently emitted purge event.
-- Returns nil if no purge event has been emitted yet.
function ms.database.last_purge_event()
    if not last_purge_event_data then
        local state = ms.database.get_purge_state()
        if state.event then
            last_purge_event_data = table.copy(state.event)
        else
            return nil
        end
    end
    return table.copy(last_purge_event_data)
end

-- Emits "database_purged" event to all registered purge callbacks.
-- event_data is forwarded to callbacks and stored as last purge event.
function ms.database.emit_purged(event_data)
    last_purge_event_data = table.copy(event_data)
    for callback_id, callback in pairs(purge_callbacks) do
        local ok, err = pcall(callback, table.copy(last_purge_event_data))
        if not ok then
            core.log("error",
                     "Mapchunk Shepherd: Purge callback "..callback_id..
                     " failed: "..tostring(err))
        end
    end
end

-- Builds standardized "database_purged" payload with before/after
-- compatibility metadata and purge statistics.
local function build_purge_event(reason, removed_key_count, old_db_version, old_chunksize, purge_seq)
    return {
        event = "database_purged",
        purge_seq = purge_seq,
        reason = reason,
        removed_key_count = removed_key_count,
        old_db_version = old_db_version,
        new_db_version = ms.database.stored_version(),
        old_chunksize = old_chunksize,
        new_chunksize = ms.database.chunksize(),
        gametime = core.get_gametime(),
    }
end

-- Validates and normalizes purge reason to supported contract values.
-- Unsupported, missing or non-string reasons are converted to "unknown".
local function normalize_purge_reason(reason)
    if type(reason) ~= "string" then
        if reason ~= nil then
            core.log("warning",
                     "Mapchunk Shepherd: Unsupported purge reason type '"..
                     type(reason).."', falling back to 'unknown'.")
        end
        return "unknown"
    end
    if not valid_purge_reasons[reason] then
        core.log("warning",
                 "Mapchunk Shepherd: Unsupported purge reason '"..
                 reason.."', falling back to 'unknown'.")
        return "unknown"
    end
    return reason
end

-- Removes *ALL* keys stored in mod storage for the shepherd.
-- WARNING: This permanently deletes all mapchunk data!
-- Only call this for fresh initialization or when explicitly requested.
function ms.database.purge(reason)
    local purge_reason = normalize_purge_reason(reason)
    local old_db_version = ms.database.stored_version()
    local old_chunksize = ms.database.chunksize()
    local old_purge_state = ms.database.get_purge_state()
    local next_purge_seq = old_purge_state.seq + 1
    local removed_key_count = 0
    core.log("warning", "Mapchunk Shepherd: Purging all database keys from mod storage.")
    for _, key in pairs(mod_storage:get_keys()) do
        mod_storage:set_string(key, "")
        removed_key_count = removed_key_count + 1
    end
    local event_data = build_purge_event(
        purge_reason, removed_key_count, old_db_version, old_chunksize, next_purge_seq
    )
    persist_purge_state(next_purge_seq, purge_reason, event_data)
    ms.database.emit_purged(event_data)
    return event_data
end

-- Explicit/admin purge entry point.
-- Purges database with reason "manual".
function ms.database.purge_manual()
    return ms.database.purge("manual")
end

-- Migration-triggered purge entry point.
-- Purges database with reason "migration".
function ms.database.purge_for_migration()
    return ms.database.purge("migration")
end

-- Initializes shepherd database metadata during bootstrap state handling.
-- Behavior:
--   * new_world          -> runs initialize purge once, then stores version/chunksize
--   * legacy_or_corrupt  -> runs migration purge once, then stores version/chunksize
--   * initialized        -> no-op (function exits via ms.database.valid() guard)
function ms.database.initialize()
    if ms.database.valid() then
        return
    end
    local bootstrap_state = ms.database.bootstrap_state()
    local purge_state = ms.database.get_purge_state()

    -- Only purge once for unversioned databases.
    if purge_state.seq == 0 then
        if bootstrap_state == "new_world" then
            ms.database.purge("initialize")
        elseif bootstrap_state == "legacy_or_corrupt" then
            core.log("warning",
                     "Mapchunk Shepherd: Unversioned database contains keys. "..
                     "This may indicate corrupted storage or an upgrade from a very old version. "..
                     "Shepherd mod-storage data will be purged and rebuilt via migration purge.")
            ms.database.purge_for_migration()
        end
    end
    ms.database.update_version()
    ms.database.update_chunksize()
    core.log("action", "Mapchunk Shepherd: Database initialized with version "..
                 ms.database.version().." and chunksize "..sizes.mapchunk.in_mapblocks..".")
end

-- Returns the chunksize stored in mod storage.
-- Returns 0 if not set (uninitialized database).
function ms.database.chunksize()
    return mod_storage:get_int("chunksize")
end

-- Updates the chunksize stored in the database to the current
-- chunksize.
function ms.database.update_chunksize()
    mod_storage:set_int("chunksize", sizes.mapchunk.in_mapblocks)
end

-- Checks if the chunksize stored in the database is different from
-- the chunksize which is active in mapgen.
-- Returns false if chunksize is not set (0) - meaning fresh database.
function ms.chunksize_changed()
    local stored_chunksize = ms.database.chunksize()
    -- If chunksize is 0, database is uninitialized, so no change occurred
    return stored_chunksize ~= 0 and stored_chunksize ~= sizes.mapchunk.in_mapblocks
end

-- Database format conversion functions
-- These functions convert from one database version to another.
-- Each function should handle all necessary data transformations.

-- Placeholder for future conversion from version 1 to version 2
-- function ms.database.convert_from_v1()
--     core.log("action", "Mapchunk Shepherd: Converting database from version 1 to 2...")
--     -- Conversion logic here
--     ms.database.update_version()
--     core.log("action", "Mapchunk Shepherd: Database conversion to version 2 complete.")
-- end

-- Attempts to convert the database from stored_version to the current version.
-- Returns true if conversion was successful or not needed, false otherwise.
-- Note: This should only be called when database is outdated (stored < current).
function ms.database.convert()
    local stored = ms.database.stored_version()
    local current = ms.database.version()
    
    -- Conversion chain: upgrade from stored version to current version
    -- For now, we only have version 1, so no conversions exist yet
    -- Future versions would add conversion calls here, e.g.:
    -- if stored == 1 then
    --     ms.database.convert_from_v1()
    --     stored = 2
    -- end
    -- if stored == 2 then
    --     ms.database.convert_from_v2()
    --     stored = 3
    -- end
    
    -- If we reach here, no actual data conversion was needed (structure unchanged)
    -- Just bump the version number to match the current API version
    core.log("action", "Mapchunk Shepherd: Updating database version from "..
                 stored.." to "..current.." (no data conversion needed).")
    ms.database.update_version()
    return true
end

-- Checks if the database format stored in mod storage is compatible with this 
-- version of the shepherd. Runs code for database initialization and upgrade.
-- Returns a boolean - `true` if compatibility was ensured and `false` if not.
function ms.ensure_compatibility()
    -- Check if database is too new
    if ms.database.too_new() then
        core.log("error", "Mapchunk Shepherd: Database version "..
                     ms.database.stored_version().." is newer than supported version "..
                     ms.database.version()..".")
        core.log("error", "Mapchunk Shepherd: This may happen if you downgraded the mod.")
        core.log("error", "Mapchunk Shepherd: Please check for mod updates or restore a newer version.")
        core.log("error", "Mapchunk Shepherd: Refusing to start to prevent data corruption.")
        return false
    end
    
    -- Check if chunksize changed (only relevant for initialized databases)
    if ms.chunksize_changed() then
        local stored_chunksize = ms.database.chunksize()
        local stored_version = ms.database.stored_version()
        
        -- Special case: migrate from old format where chunksize was stored in nodes (80)
        -- to new format where chunksize is stored in mapblocks (5)
        -- This only applies to databases with version < 1 and stored_chunksize of 80
        if stored_chunksize == 80 and stored_version < 1 then
            core.log("action", "Mapchunk Shepherd: Detected legacy chunksize format (80 nodes).")
            core.log("warning", "Mapchunk Shepherd: Legacy format migration requires purge to keep data consistent.")
            core.log("action", "Mapchunk Shepherd: Purging database and migrating to new format with chunksize "..
                         sizes.mapchunk.in_mapblocks.." mapblocks.")
            ms.database.purge_for_migration()
            -- Continue with normal initialization/conversion flow
        else
            -- Regular chunksize change error
            core.log("error", "Mapchunk Shepherd: Chunksize changed from "..
                         stored_chunksize.." to "..sizes.mapchunk.in_mapblocks..".")
            core.log("error", "Mapchunk Shepherd: Changing chunksize invalidates all stored mapchunk data.")
            core.log("error", "Mapchunk Shepherd: Stored labels use mapchunk hashes based on old chunksize,")
            core.log("error", "Mapchunk Shepherd: which would cause data corruption and incorrect behavior.")
            core.log("error", "Mapchunk Shepherd: To use the new chunksize, you must:")
            core.log("error", "Mapchunk Shepherd:   1. Delete the mod storage for this mod (typically <worlddir>/mod_storage_<modname>)")
            core.log("error", "Mapchunk Shepherd:   2. Or restore the old chunksize setting")
            core.log("error", "Mapchunk Shepherd: Refusing to start.")
            return false
        end
    end
    
    -- Initialize fresh database if needed
    ms.database.initialize()
    
    -- Convert database if outdated
    if ms.database.outdated() then
        if not ms.database.convert() then
            core.log("error", "Mapchunk Shepherd: Database conversion failed.")
            core.log("error", "Mapchunk Shepherd: Check logs above for conversion details.")
            core.log("error", "Mapchunk Shepherd: Refusing to start.")
            return false
        end
    end

    core.log("action", "Mapchunk Shepherd: Database compatibility check passed.")
    core.log("action", "Mapchunk Shepherd: Using database version "..ms.database.version()..
                 " with chunksize "..sizes.mapchunk.in_mapblocks..".")
    return true
end
