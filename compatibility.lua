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

-- Checks if the database is too new for this version of the shepherd.
-- Returns true if stored version is higher than supported version.
function ms.database.too_new()
    local stored = ms.database.stored_version()
    return stored > 0 and stored > ms.database.version()
end

-- Removes *ALL* keys stored in mod storage for the shepherd.
-- WARNING: This permanently deletes all mapchunk data!
-- Only call this for fresh initialization or when explicitly requested.
function ms.database.purge()
    core.log("warning", "Mapchunk Shepherd: Purging all database keys from mod storage.")
    for _, key in pairs(mod_storage:get_keys()) do
        mod_storage:set_string(key, "")
    end
end

-- Initializes a fresh database. This should only be called for new worlds
-- or when mod storage is empty. Sets version and chunksize.
function ms.database.initialize()
    if not ms.database.valid() then
        -- Only purge if we're really starting fresh (version is 0)
        if ms.database.stored_version() == 0 then
            ms.database.purge()
        end
        ms.database.update_version()
        ms.database.update_chunksize()
        core.log("action", "Mapchunk Shepherd: Database initialized with version "..
                     ms.database.version().." and chunksize "..sizes.mapchunk.in_mapblocks..".")
    end
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
        core.log("error", "Mapchunk Shepherd: Chunksize changed from "..
                     ms.database.chunksize().." to "..sizes.mapchunk.in_mapblocks..".")
        core.log("error", "Mapchunk Shepherd: Changing chunksize invalidates all stored mapchunk data.")
        core.log("error", "Mapchunk Shepherd: Stored labels use mapchunk hashes based on old chunksize,")
        core.log("error", "Mapchunk Shepherd: which would cause data corruption and incorrect behavior.")
        core.log("error", "Mapchunk Shepherd: To use the new chunksize, you must:")
        core.log("error", "Mapchunk Shepherd:   1. Delete the mod storage for this mod (typically <worlddir>/mod_storage_<modname>)")
        core.log("error", "Mapchunk Shepherd:   2. Or restore the old chunksize setting")
        core.log("error", "Mapchunk Shepherd: Refusing to start.")
        return false
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
