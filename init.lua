--[[
    This is a part of "Perfect City".
    Copyright (C) 2023 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

---------------------------------------------
---- Mapchunk shepherd
---------------------------------------------

-- Globals
mapchunk_shepherd = {}

local modpath = minetest.get_modpath('mapchunk_shepherd')
local S = minetest.get_translator("mapchunk_shepherd")

mapchunk_shepherd.S = S

dofile(modpath.."/labels.lua")
dofile(modpath.."/chunk_utils.lua")
dofile(modpath.."/dogs.lua")
dofile(modpath.."/shepherd.lua")
