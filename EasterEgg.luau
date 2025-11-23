--// oh look you found  the version that remakes  x86 asm but with lua!
--// HAVE FUN!!!!!!
local LuaC_VM = {}
LuaC_VM.__index = LuaC_VM

function LuaC_VM.new(env)
	local self = setmetatable({}, LuaC_VM)
	self.stack = {}
	self.registry = {}
	self.globals = env or {}
	self.env = env or {}
	self.labels = {}
	self.pc = 1  -- Program Counter (Instruction pointer)
	self.sp = 0  -- Stack Pointer (points to the top element)
	self.instructions = {}
	self.callStack = {}

	-- General-Purpose Registers (EAX, EBX, ECX, EDX, EBP)
	self.registers = {
		EAX = nil, -- Accumulator
		EBX = nil, -- Base
		ECX = nil, -- Counter
		EDX = nil, -- Data
        EBP = 0,   -- Base Pointer (for local frame access)
	}
    
    -- Status Flags Register (EFLAGS simplification)
    self.flags = {
        ZF = false, -- Zero Flag (Result of operation is zero)
        SF = false, -- Sign Flag (Result is negative)
        EQ = false, -- Equality Flag (Result of last CMP)
        LT = false, -- Less Than Flag (Result of last CMP)
    }
    
	return self
end

--- Stack and Value Helpers ---

function LuaC_VM:push(v)
    self.sp = self.sp + 1
    self.stack[self.sp] = v
end

function LuaC_VM:pop()
    if self.sp < 1 then return nil end
    local v = self.stack[self.sp]
    self.stack[self.sp] = nil -- clear old value
    self.sp = self.sp - 1
    return v
end

-- Helper to get a value from a source (Register, Stack Index, Global, or Immediate value)
function LuaC_VM:getValue(source)
    if source == nil then return nil end

    -- 1. Register Name
    if self.registers[source] ~= nil then
        return self.registers[source]
    end

    -- 2. Immediate Values (Number, nil, true, false)
    local numSource = tonumber(source)
    if numSource ~= nil then return numSource end
    if source == "nil" then return nil end
    if source == "true" then return true end
    if source == "false" then return false end
    
    -- 3. Stack Access: [SP+N] or [EBP+N] (e.g., [SP-1], [EBP+4])
    local stack_offset = source:match("^%[(SP|EBP)%s*([%+%-]?%d+)%]$")
    if stack_offset then
        local base_reg, offset = stack_offset:match("^(SP|EBP)%s*([%+%-]?%d+)$")
        local base_ptr = (base_reg == "SP") and self.sp or self.registers.EBP
        local idx = base_ptr + tonumber(offset)
        return self.stack[idx]
    end

    -- 4. String Literal (Must be quoted)
    if source:match('^"(.*)"$') then
        return source:match('^"(.*)"$')
    end
    
    -- 5. Global variable name
    return self.globals[source]
end

-- Helper to set a value to a destination (Register, Stack Index, or Global)
function LuaC_VM:setValue(destination, value)
    -- 1. Register Name
    if self.registers[destination] ~= nil then
        self.registers[destination] = value
        return
    end

    -- 2. Stack Access: [SP+N] or [EBP+N]
    local stack_offset = destination:match("^%[(SP|EBP)%s*([%+%-]?%d+)%]$")
    if stack_offset then
        local base_reg, offset = stack_offset:match("^(SP|EBP)%s*([%+%-]?%d+)$")
        local base_ptr = (base_reg == "SP") and self.sp or self.registers.EBP
        local idx = base_ptr + tonumber(offset)

        -- Allow implicit stack growth if writing past current SP
        if idx > self.sp and base_reg == "SP" then self.sp = idx end
        self.stack[idx] = value
        return
    end
    
    -- 3. Global variable name
    self.globals[destination] = value
end

-- Helper to update ZF/SF flags based on a resulting number
local function update_flags(self, result)
    self.flags.ZF = (result == 0)
    self.flags.SF = (result < 0)
end

function LuaC_VM:printState()
	--print("\n--- VM STATE ---")
	--print(string.format("PC: %d, SP: %d, EBP: %d", self.pc, self.sp, self.registers.EBP or 0))
	--print("Registers:")
    for k, v in pairs(self.registers) do
        --print(string.format("  %s: %s (%s)", k, tostring(v), type(v)))
    end
    --print("Flags:")
    --print(string.format("  ZF: %s, SF: %s, EQ: %s, LT: %s", self.flags.ZF, self.flags.SF, self.flags.EQ, self.flags.LT))
	--print("Stack:")
	if self.sp == 0 then
		--print("  [Empty]")
		return
	end
    
	for i = 1, self.sp do
		local val = self.stack[i]
		local typeStr = type(val)
		local displayStr = tostring(val)
		--print(string.format("  [%d / SP%+d]: %s (%s)", i, i - self.sp, displayStr, typeStr))
	end
    --print("----------------")
end

--- Execution Core ---

-- Execute single line (raw opcode)
function LuaC_VM:exec(line)
	local op, args = line:match("^(%S+)%s*(.*)$")
	if args == "" then args = nil end

    -- Parse operands (up to three)
    local dest, src1, src2 = args:match("([^,]+)%s*,%s*([^,]+)%s*,%s*(.+)")
    if not dest then dest, src1 = args:match("([^,]+)%s*,%s*(.+)") end
    if not dest then dest = args:match("(.+)") end
    
    local trim = function(s) return s and s:match("^%s*(.-)%s*$") end
    dest, src1, src2 = trim(dest), trim(src1), trim(src2)

	-- 1. Data Movement and Addressing
	if op == "MOV" then
		self:setValue(dest, self:getValue(src1))

    elseif op == "LEA" then
        -- LEA destination, [Base+offset] (Loads the memory address/index)
        local stack_offset = src1:match("^%[(SP|EBP)%s*([%+%-]?%d+)%]$")
        if stack_offset then
            local base_reg, offset = stack_offset:match("^(SP|EBP)%s*([%+%-]?%d+)$")
            local base_ptr = (base_reg == "SP") and self.sp or self.registers.EBP
            local idx = base_ptr + tonumber(offset)
            self:setValue(dest, idx)
        else
            self:setValue(dest, nil) 
        end

	-- 2. Stack Operations
    elseif op == "PUSH" then
        self:push(self:getValue(dest))
    elseif op == "POP" then
        local val = self:pop()
        self:setValue(dest, val)

	-- 3. Arithmetic (Two-Operand: dest = dest OP src1)
	elseif op == "ADD" then
		local dest_val = self:getValue(dest)
		local src1_val = self:getValue(src1)
		local result = (tonumber(dest_val) or 0) + (tonumber(src1_val) or 0)
		self:setValue(dest, result)
        update_flags(self, result)

	elseif op == "SUB" then
		local dest_val = self:getValue(dest)
		local src1_val = self:getValue(src1)
		local result = (tonumber(dest_val) or 0) - (tonumber(src1_val) or 0)
		self:setValue(dest, result)
        update_flags(self, result)

    elseif op == "INC" then
        local dest_val = self:getValue(dest)
        local result = (tonumber(dest_val) or 0) + 1
        self:setValue(dest, result)
        update_flags(self, result)
        
    elseif op == "DEC" then
        local dest_val = self:getValue(dest)
        local result = (tonumber(dest_val) or 0) - 1
        self:setValue(dest, result)
        update_flags(self, result)

    -- 4. Comparison (Sets Flags only)
	elseif op == "CMP" then
		local a = tonumber(self:getValue(dest) or 0)
		local b = tonumber(self:getValue(src1) or 0)
		local diff = a - b

        self.flags.ZF = (diff == 0)
        self.flags.SF = (diff < 0)
        self.flags.EQ = (diff == 0)
        self.flags.LT = (diff < 0)

    -- 5. Table/Memory Access
    elseif op == "LOAD" then
        -- LOAD destination, table_reg, key_source (dest = table_reg[key_source])
        local tbl = self:getValue(src1)
        local key = self:getValue(src2)
        local val = (type(tbl) == "table" and tbl[key])
        self:setValue(dest, val)
        
    elseif op == "STORE" then
        -- STORE table_reg, key_source, value_source (table_reg[key_source] = value_source)
        local tbl = self:getValue(dest)
        local key = self:getValue(src1)
        local val = self:getValue(src2)
        if type(tbl) == "table" then
            tbl[key] = val
        end
        
    elseif op == "NEWTABLE" then
        self:setValue(dest, {})

    -- 6. Function Call (Highly simplified)
    elseif op == "CALL" then
        -- CALL nargs, nresults
        local nargs = tonumber(dest) or 0
        local nresults = tonumber(src1) or 0
        local func_idx = self.sp - nargs
        local func = self.stack[func_idx]
        
        local args = {}
        for i = 1, nargs do
            args[i] = self.stack[func_idx + i]
        end
        
        -- Clean up stack (Function + Args)
        self.sp = func_idx - 1
        
        local results = {}
        if type(func) == "function" then
            local success, res = pcall(func, unpack(args))
            if success then
                local unpacked = table.pack(res)
                for i = 1, nresults do results[i] = unpacked[i] end
            else
                self.flags.SF = true -- Use sign flag as a simple 'Error' flag
                for i = 1, nresults do results[i] = nil end
            end
        end

        -- push return values
        for i = 1, nresults do
            self:push(results[i])
        end
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

-- Main Execution Loop
function LuaC_VM:run(scriptString)
	self:preprocessLabels(scriptString)
	self.pc = 1
    
	while self.pc <= #self.instructions do
		local line = self.instructions[self.pc]
		local op, arg = line:match("^(%S+)%s*(.*)$")
		if arg == "" then arg = nil end
        
        -- print(string.format("PC:%d | Executing: %s", self.pc, line))
        
        local jump_needed = false
        local target_label = arg

		-- Conditional Jump Checks (Based on EFLAGS)
		if op == "JMP" then jump_needed = true -- Unconditional
		elseif op == "JE" or op == "JZ" then jump_needed = self.flags.EQ -- Jump if Equal / Zero
		elseif op == "JNE" or op == "JNZ" then jump_needed = not self.flags.EQ -- Jump if Not Equal / Not Zero
        elseif op == "JL" then jump_needed = self.flags.LT -- Jump if Less Than
        elseif op == "JLE" then jump_needed = self.flags.LT or self.flags.EQ -- Jump if Less Than or Equal
        elseif op == "JG" then jump_needed = not (self.flags.LT or self.flags.EQ) -- Jump if Greater Than
        elseif op == "JGE" then jump_needed = not self.flags.LT -- Jump if Greater Than or Equal
		end
        
        -- Execute Jump or Next Instruction
		if jump_needed then
			if self.labels[target_label] then
				self.pc = self.labels[target_label]
			else
				-- If label is not found, treat it as a NOP and increment PC
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
        
	end
    self:printState()
end

return LuaC_VM
