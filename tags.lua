--[[
    This is a part of "Perfect City".
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
local ms = mapchunk_shepherd

ms.tag = {}
local tag = ms.tag

local registered_tags = {}

-- Registers a new tag
function tag.register(name)
    assert(type(name) == "string",
           "Tag 'name' should be string but is "..type(name).." instead.")
    assert(not registered_tags[name],
           "Mapchunk shepherd: Tag with name \""..name.."\" already exists!")
    registered_tags[name] = true
end

-- Checks if the tag is registered, returns a boolean.
function tag.check(name)
    return registered_tags[name]
end

-- Returns a list of names of registered tags.
function tag.get_registered()
    local registered = {}
    for name, _ in pairs(registered_tags) do
        table.insert(registered, name)
    end
    return registered
end

tag.register("worker_failed")
