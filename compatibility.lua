--[[
    This is a part of "Mapblock Shepherd".
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

-- Globals
local ms = mapchunk_shepherd

local mod_path = minetest.get_modpath("mapchunk_shepherd")
local sizes = dofile(mod_path.."/sizes.lua")
local mod_storage = minetest.get_mod_storage()

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
function ms.database.stored_version()
    return mod_storage:get_int("shepherd_db_version")
end

-- Updates the version of the shepherd database in mod storage.
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

-- Removes *ALL* keys stored in mod storage for the shepherd.
function ms.database.purge()
    for _, key in pairs(mod_storage:get_keys()) do
        mod_storage:set_string(key, "")
    end
end

-- Checks if the database was properly initialized, if not it will
-- purge all database keys and set the database version and chunksize in
-- mod storage.
function ms.database.initialize()
    if not ms.database.valid() then
        ms.database.purge()
        ms.database.update_version()
        ms.database.update_chunksize()
    end
end

-- Returns the chunksize stored in mod storage.
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
function ms.chunksize_changed()
    local chunksize = ms.database.chunksize()
    return chunksize ~= 0 and chunksize ~= sizes.mapchunk.in_mapblocks
end

-- Checks if the database format stored in mod storage is compatible with this version of the shepherd. Runs code for database initialization and upgrade. Returns a boolean - `true` if compatibility was ensured and `false` if not.
function ms.ensure_compatibility()
    if ms.chunksize_changed() then
        minetest.log("error", "Mapblock Shepherd: chunksize changed to "..
                     sizes.mapchunk.in_mapblocks.." from "..ms.database.chunksize()..".")
        minetest.log("error", "Mapblock Shepherd: Changing chunksize can corrupt stored data."..
                     " Refusing to start.")
        return false
    end
    -- init runs only for fresh mod storage or ancient shepherd releases
    ms.database.initialize()
    if ms.database.outdated() then
        -- TODO: put some actual upgrade code here, for now just bump version
        ms.database.update_version()
    end
    return true
end
