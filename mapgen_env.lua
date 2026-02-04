--[[
    This is a part of "Mapchunk Shepherd".
    Copyright (C) 2024 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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
mapchunk_shepherd = {}
local ms = mapchunk_shepherd
local mod_name = core.get_current_modname()
local mod_path = core.get_modpath(mod_name)

dofile(mod_path.."/utils.lua")
dofile(mod_path.."/tags.lua")
dofile(mod_path.."/units.lua")
dofile(mod_path.."/labels.lua")
dofile(mod_path.."/label_store.lua")
dofile(mod_path.."/chunk_utils.lua")
dofile(mod_path.."/mapgen_scanners.lua")
