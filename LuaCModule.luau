local LuaC_VM = {}
LuaC_VM.__index = LuaC_VM

function LuaC_VM.new(env)
	local self = setmetatable({}, LuaC_VM)
	self.stack = {}
	self.registry = {}
	self.globals = env or {}
	self.env = env or {}
	self.labels = {}
	self.pc = 1 -- program counter
	self.instructions = {}
	self.callStack = {} -- for function calls
	self.functions = {} -- store function labels
	return self
end

-- Stack helpers
function LuaC_VM:push(v)
	table.insert(self.stack, v)
end

function LuaC_VM:pop()
	return table.remove(self.stack)
end

function LuaC_VM:getRelative(idx)
	idx = tonumber(idx)
	if idx >= 1 then return self.stack[idx] end
	if idx == -10000 then return self.registry end
	if idx == -10001 or idx == -10002 then return self.globals end
	return self.stack[#self.stack + idx + 1]
end

function LuaC_VM:setRelative(idx, value)
	idx = tonumber(idx)
	if idx >= 1 then
		self.stack[idx] = value
	elseif idx == -10000 or idx == -10001 or idx == -10002 then
		-- ERROR PREVENTION: These indices should only be used for GET, not SET.
		-- If you must allow modification, it should be to a field, not the table itself.
		error("Attempt to reassign VM globals/registry table reference.", 2)
	else
		-- Normal relative stack access
		local stack_idx = #self.stack + idx + 1
		if stack_idx >= 1 and stack_idx <= #self.stack then
			self.stack[stack_idx] = value
		else
			error("Stack index out of bounds (" .. idx .. ")", 2)
		end
	end
end

-- NEW: Debug function to print the current stack state
function LuaC_VM:printStack()
	print("--- STACK (" .. #self.stack .. " Items) ---")
	if #self.stack == 0 then
		print("  [Empty]")
		return
	end

	for i = 1, #self.stack do
		local val = self.stack[i]
		local typeStr = type(val)
		local displayStr = ""

		if typeStr == "string" then
			displayStr = '"' .. val .. '"'
		elseif typeStr == "number" or typeStr == "boolean" then
			displayStr = tostring(val)
		elseif typeStr == "function" then
			displayStr = "<function>"
		elseif typeStr == "table" or typeStr == "userdata" then
			-- Attempt to print a useful representation for tables/userdata (like Instances)
			local name = tostring(val)
			if name:match(":%s*%x+$") then name = name:match("([^:]+)") end -- Clean up memory address if present
			displayStr = "<" .. name .. ", size/ptr>"
		else
			displayStr = "<" .. typeStr .. ">"
		end

		local relativeIdx = i - #self.stack - 1
		print(string.format("  [%d / %d]: %s (%s)", i, relativeIdx, displayStr, typeStr))
	end
end


-- Lua-C style function call
-- Lua-C style function call
function LuaC_VM:callFunc(nargs, nresults)
	nargs = tonumber(nargs or 0)
	nresults = tonumber(nresults or 0)
	local func_idx = #self.stack - nargs
	local func = self.stack[func_idx]
	local args = {}
	for i = 1, nargs do
		args[i] = self.stack[func_idx + i]
	end
	local results = {}
	if type(func) == "function" then
		local success, res = pcall(func, unpack(args))
		if success then
			-- Fix: Correctly collect multiple results from pcall
			local unpacked = table.pack(res)

			-- If pcall worked, collect the correct number of results
			for i = 1, nresults do
				table.insert(results, unpacked[i])
			end
		else
			-- On failure, return nil for all results
			for i = 1, nresults do
				table.insert(results, nil)
			end
		end
	else
		-- If not a function, return nil for all results
		for i = 1, nresults do
			table.insert(results, nil)
		end
	end

	-- remove function + args (nargs + 1 items)
	for i = 1, nargs + 1 do table.remove(self.stack, func_idx) end

	-- push return values
	for i = 1, nresults do
		self:push(results[i] or nil)
	end
end
-- Execute single line (raw opcode)
function LuaC_VM:exec(line)
	local op, arg = line:match("^(%S+)%s*(.*)$")
	if arg == "" then arg = nil end

	-- Original opcodes
	if op == "getglobal" then
		self:push(self.globals[arg])

	elseif op == "setglobal" then
		self.globals[arg] = self:pop()

	elseif op == "getfield" then
		local idx, key = arg:match("([%-0-9]+)%s*(.+)$")
		idx = tonumber(idx)
		key = key:match("^%s*(.-)%s*$") -- trim whitespace
		local obj = self:getRelative(idx)
		if type(obj) == "table" or type(obj) == "userdata" then
			self:push(obj[key])
		else
			self:push(nil)
		end

	elseif op == "setfield" then
		local idx, key = arg:match("([%-0-9]+)%s*(.+)$")
		idx = tonumber(idx)
		key = key:match("^%s*(.-)%s*$") -- trim whitespace
		local obj = self:getRelative(idx)
		local value = self:pop()
		if type(obj) == "table" or type(obj) == "userdata" then
			obj[key] = value
		end

	elseif op == "pushvalue" then
		self:push(self:getRelative(tonumber(arg)))

	elseif op == "pushstring" then
		self:push(arg)

	elseif op == "pushnumber" then
		self:push(tonumber(arg))

	elseif op == "pushboolean" then
		self:push(tonumber(arg) == 1)

	elseif op == "pushnil" then
		self:push(nil)

	elseif op == "pop" then
		self:pop()

	elseif op == "pcall" or op == "call" then
		local nargs, nresults = arg:match("(%d+)%s*(%d*)")
		self:callFunc(nargs, nresults)

	elseif op == "emptystack" then
		self.stack = {}

	elseif op == "gettop" then
		self:push(#self.stack)

	elseif op == "settop" then
		local newTop = tonumber(arg)
		local currentTop = #self.stack
		if newTop < currentTop then
			for i = currentTop, newTop + 1, -1 do
				table.remove(self.stack)
			end
		elseif newTop > currentTop then
			for i = currentTop + 1, newTop do
				self:push(nil)
			end
		end

		-- Table operations
	elseif op == "newtable" then
		self:push({})

	elseif op == "gettable" then
		local idx = tonumber(arg)
		local key = self:pop()
		local tbl = self:getRelative(idx)
		if type(tbl) == "table" then
			self:push(tbl[key])
		else
			self:push(nil)
		end

	elseif op == "settable" then
		local idx = tonumber(arg)
		local key = self:pop()
		local value = self:pop()
		local tbl = self:getRelative(idx)
		if type(tbl) == "table" then
			tbl[key] = value
		end

		-- Arithmetic operations
	elseif op == "add" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push((tonumber(a) or 0) + (tonumber(b) or 0))

	elseif op == "sub" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push((tonumber(a) or 0) - (tonumber(b) or 0))

	elseif op == "mul" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push((tonumber(a) or 0) * (tonumber(b) or 0))

	elseif op == "div" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push((tonumber(a) or 0) / (tonumber(b) or 1))

	elseif op == "mod" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push((tonumber(a) or 0) % (tonumber(b) or 1))

	elseif op == "pow" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push((tonumber(a) or 0) ^ (tonumber(b) or 1))

		-- Comparison operations
	elseif op == "eq" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push(a == b)

	elseif op == "lt" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push(a < b)

	elseif op == "le" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push(a <= b)

	elseif op == "gt" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push(a > b)

	elseif op == "ge" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push(a >= b)

		-- Logic operations
	elseif op == "not" then
		local idx = tonumber(arg)
		local val = self:getRelative(idx)
		self:push(not val)

	elseif op == "isnil" then
		local idx = tonumber(arg)
		local val = self:getRelative(idx)
		self:push(val == nil)

		-- String operations
	elseif op == "concat" then
		local idx1, idx2 = arg:match("([%-0-9]+)%s+([%-0-9]+)")
		local a = self:getRelative(tonumber(idx1))
		local b = self:getRelative(tonumber(idx2))
		self:push(tostring(a) .. tostring(b))

	elseif op == "len" then
		local idx = tonumber(arg)
		local val = self:getRelative(idx)
		if type(val) == "table" then
			self:push(#val)
		elseif type(val) == "string" then
			self:push(#val)
		else
			self:push(0)
		end

		-- Control flow (handled in run method)
	elseif op:match("^:") then
		-- Label, do nothing

	elseif op == "jump" then
		-- Handled in run method

	elseif op == "jumpif" then
		-- Handled in run method

	end
end

-- Preprocess to find labels
function LuaC_VM:preprocessLabels(scriptString)
	self.labels = {}
	self.instructions = {}
	local lineNum = 1

	for line in scriptString:gmatch("[^\r\n]+") do
		line = line:match("^%s*(.-)%s*$") -- trim
		if line ~= "" then
			local label = line:match("^:(.+)$")
			if label then
				self.labels[label] = lineNum
			end
			table.insert(self.instructions, line)
			lineNum = lineNum + 1
		end
	end
end

function LuaC_VM:run(scriptString)
	-- Preprocess to find all labels
	self:preprocessLabels(scriptString)

	-- Execute instructions
	self.pc = 1
	while self.pc <= #self.instructions do
		local line = self.instructions[self.pc]
		local op, arg = line:match("^(%S+)%s*(.*)$")
		if arg == "" then arg = nil end

		print("\n-- PC: " .. self.pc .. " | EXECUTING: " .. line .. " --")

		-- Handle control flow
		if op == "jump" then
			local label = arg
			if self.labels[label] then
				self.pc = self.labels[label]
			else
				self.pc = self.pc + 1
			end

		elseif op == "jumpif" then
			local condition, label = arg:match("(%d+)%s+(.+)")
			condition = tonumber(condition)
			local val = self:pop()

			-- Convert to boolean
			local boolVal = false
			if type(val) == "boolean" then
				boolVal = val
			elseif type(val) == "number" then
				boolVal = (val ~= 0)
			elseif val ~= nil then
				boolVal = true
			end

			if (condition == 1 and boolVal) or (condition == 0 and not boolVal) then
				if self.labels[label] then
					self.pc = self.labels[label]
				else
					self.pc = self.pc + 1
				end
			else
				self.pc = self.pc + 1
			end

		elseif op:match("^:") then
			-- Label, skip
			self.pc = self.pc + 1

		else
			-- Regular instruction
			self:exec(line)
			self.pc = self.pc + 1
		end

		-- Print stack state after execution
		self:printStack()
	end
end

return LuaC_VM
