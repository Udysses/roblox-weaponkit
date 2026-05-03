--!strict
-- Maid.lua
-- Tracks connections, instances, threads, and cleanup functions,
-- destroying them all in one :Destroy() call.
--
-- Solves:
--   • Memory leaks from RBXScriptConnections never being disconnected
--   • Lag that accumulates across equip/unequip cycles
--   • AnimationTracks leaking and playing after unequip

export type Task = RBXScriptConnection | Instance | thread | () -> ()

export type Maid = {
	Give: (self: Maid, task: Task) -> Task,
	Destroy: (self: Maid) -> (),
	_tasks: { Task },
}

local Maid = {}
Maid.__index = Maid

--- Create a new Maid.
function Maid.new(): Maid
	return setmetatable({ _tasks = {} }, Maid) :: any
end

--- Register a task for cleanup. Returns the task so you can inline it:
---   local conn = maid:Give(event:Connect(fn))
function Maid:Give(task: Task): Task
	table.insert(self._tasks, task)
	return task
end

--- Destroy all registered tasks and reset the list.
function Maid:Destroy()
	local tasks = self._tasks
	self._tasks = {}
	for _, task in tasks do
		if typeof(task) == "RBXScriptConnection" then
			task:Disconnect()
		elseif typeof(task) == "Instance" then
			pcall(function()
				task:Destroy()
			end)
		elseif typeof(task) == "thread" then
			pcall(task.cancel or function() end, task)
		elseif type(task) == "function" then
			pcall(task)
		end
	end
end

return Maid
