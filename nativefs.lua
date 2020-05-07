local ffi, bit = require('ffi'), require('bit')
local C = ffi.C

ffi.cdef([[
	typedef struct FILE FILE;

	FILE* fopen(const char* pathname, const char* mode);
	size_t fread(void* ptr, size_t size, size_t nmemb, FILE* stream);
	size_t fwrite(const void* ptr, size_t size, size_t nmemb, FILE* stream);
	int fclose(FILE* stream);
	int fflush(FILE* stream);
	size_t fseek(FILE* stream, size_t offset, int whence);
	size_t ftell(FILE* stream);
	int setvbuf(FILE* stream, char* buffer, int mode, size_t size);
	int feof(FILE* stream);
]])

local fopen, fclose, ftell, fseek, fflush, feof = C.fopen, C.fclose, C.ftell, C.fseek, C.fflush
local fread, fwrite, feof = C.fread, C.fwrite, C.feof
local setvbuf = C.setvbuf
local getcwd, chdir, unlink

local BUFFERMODE = {
	full = ffi.os == 'Windows' and 0  or 0,
	line = ffi.os == 'Windows' and 64 or 1,
	none = ffi.os == 'Windows' and 4  or 2,
}

if ffi.os == 'Windows' then
	ffi.cdef([[
		typedef void* HANDLE;

		#pragma pack(push)
		#pragma pack(1)
		struct WIN32_FIND_DATAW {
			uint32_t dwFileWttributes;
			uint64_t ftCreationTime;
			uint64_t ftLastAccessTime;
			uint64_t ftLastWriteTime;
			uint32_t dwReserved[4];
			char cFileName[520];
			char cAlternateFileName[28];
		};
		#pragma(pop)

		int MultiByteToWideChar(unsigned int CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int cbMultiByte, const wchar_t* lpWideCharStr, int cchWideChar);
		int WideCharToMultiByte(unsigned int CodePage, uint32_t dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, const char* lpMultiByteStr, int cchMultiByte, const char* default, int* used);

		int GetLogicalDrives(void);
		void* FindFirstFileW(const wchar_t* lpFileName, struct WIN32_FIND_DATAW* lpFindFileData);
		bool FindNextFileW(HANDLE hFindFile, struct WIN32_FIND_DATAW* fd);
		bool FindClose(HANDLE hFindFile);

		int _wchdir(const wchar_t* path);
		wchar_t* _wgetcwd(wchar_t* buffer, int maxlen);
		FILE* _wfopen(const wchar_t* name, const wchar_t* mode);
		int _wunlink(const wchar_t* name);
	]])

	local function towidestring(str)
		local size = C.MultiByteToWideChar(65001, 0, str, #str, nil, 0)
		local buf = ffi.new("wchar_t[?]", size + 1)
		C.MultiByteToWideChar(65001, 0, str, #str, buf, size + 1)
		return buf
	end

	local function toutf8string(wstr)
		local size = C.WideCharToMultiByte(65001, 0, wstr, -1, nil, 0, nil, nil)
		local buf = ffi.new("char[?]", size + 1)
		size = C.WideCharToMultiByte(65001, 0, wstr, -1, buf, size, nil, nil)
		return ffi.string(buf)
	end

	local MAX_PATH = 260
	local nameBuffer = ffi.new("wchar_t[?]", MAX_PATH + 1)

	fopen = function(name, mode) return C._wfopen(towidestring(name), towidestring(mode)) end
	getcwd = function() return toutf8string(C._wgetcwd(nameBuffer, MAX_PATH)) end
	chdir = function(path) return C._wchdir(towidestring(path)) end
	unlink = function(name) return C._wunlink(towidestring(name)) end
else
	ffi.cdef([[
		char* getcwd(char *buffer, int maxlen);
		int chdir(const char* path);
		int unlink(const char* path);
	]])

	local MAX_PATH = 4096
	local nameBuffer = ffi.new("char[?]", MAX_PATH)

	unlink, chdir = C.unlink, C.chdir
	getcwd = function()
		local cwd = C.getcwd(nameBuffer, MAX_PATH)
		if cwd == nil then
			return nil
		end
		return ffi.string(cwd)
	end
end

-----------------------------------------------------------------------------
-- NOTE: nil checks on file handles MUST be explicit (_handle == nil)
-- due to ffi's NULL semantics!

local File = {}
File.__index = File

function File:open(mode)
	if self._mode ~= 'c' then
		return false, "File is already open"
	end

	mode = mode or 'r'
	local handle = fopen(self._name, mode .. 'b')
	if handle == nil then
		-- TODO: get error message
		return false, "Could not open " .. self._name .. " in mode " .. mode
	end

	if C.setvbuf(handle, nil, BUFFERMODE[self._bufferMode], self._bufferSize) ~= 0 then
		self._bufferMode, self._bufferSize = 'none', 0
	end

	self._handle, self._mode = ffi.gc(handle, C.fclose), mode
	return true
end

function File:close()
	if self._handle == nil or self._mode == 'c' then
		return false, "File is not open"
	end

	ffi.gc(self._handle, nil)
	fclose(self._handle)
	self._handle, self._mode = nil, 'c'
	return true
end

function File:setBuffer(mode, size)
	bufferMode = BUFFERMODE[mode]
	if not bufferMode then
		return false, "Invalid buffer mode: " .. mode .. " (expected 'none', 'full', or 'line')"
	end

	size = math.max(0, size or 0)
	self._bufferMode, self._bufferSize = mode, size
	if self._mode == 'c' then return true end

	if C.setvbuf(self._handle, nil, bufferMode, size) ~= 0 then
		-- TODO: get error message
		return false
	end

	return true
end

function File:getBuffer()
	return self._bufferMode, self._bufferSize
end

function File:getFilename()
	return self._name
end

function File:getMode()
	return self._mode
end

function File:getSize()
	-- NOTE: The correct way to do this would be a stat() call, which requires a
	-- lot more (system-specific) code. This is a shortcut that requires the file
	-- to be readable.
	local mustOpen = not self:isOpen()
	if mustOpen and not self:open('r') then
		return 0
	end

	local pos = mustOpen and 0 or self:tell()
	fseek(self._handle, 0, 2)
	local size = tonumber(self:tell())
	if mustOpen then
		self:close()
	else
		self:seek(pos)
	end
	return size;
end

function File:isEOF()
	return self:isOpen() and feof(self._handle) or false
end

function File:isOpen()
	return self._mode ~= 'c' and self._handle ~= nil
end

function File:read(containerOrBytes, bytes)
	if self._handle == nil or self._mode ~= 'r' then
		return nil, 0
	end

	local container = bytes ~= nil and containerOrBytes or 'string'
	bytes = bytes == nil and containerOrBytes or 'all'
	if bytes == 'all' then
		bytes = self:getSize() - self:tell()
	else
		bytes = math.min(self:getSize() - self:tell(), bytes)
	end

	if bytes <= 0 then
		local data = container == 'string' and '' or love.data.newByteData(0)
		return data, 0
	end

	local data = love.data.newByteData(bytes)
	local r = tonumber(fread(data:getFFIPointer(), 1, bytes, self._handle))

	if container == 'string' then
		local str = data:getString()
		data:release()
		data = str
	end
	return data, r
end

function File:lines()
end

function File:write(data, size)
	if self._mode ~= 'w' and self._mode ~= 'a' then
		return false, "File " .. self._name .. " not opened for writing"
	end
	if type(data) == 'string' then
		size = (size == nil or size == 'all') and #data or size
		local success = tonumber(fwrite(data, 1, size, self._handle)) == size
		if not success then
			return false, "Could not write data"
		end
	else
		size = (size == nil or size == 'all') and data:getSize() or size
		local success = tonumber(fwrite(data:getFFIPointer(), 1, size, self._handle)) == size
		if not success then
			return false, "Could not write data"
		end
	end
	return true
end

function File:seek(pos)
	if self._handle == nil then return false end
	return fseek(self._handle, pos, 0) == 0
end

function File:tell()
	if self._handle == nil then return -1 end
	return tonumber(ftell(self._handle))
end

function File:flush()
	if self._handle == nil then return end
	return fflush(self._handle)
end

function File:release()
	if self._mode ~= 'c' then
		self:close()
	end
	self._handle = nil
end

-----------------------------------------------------------------------------

local nativefs = {}

function nativefs.newFile(name)
	return setmetatable({
		_name = name,
		_mode = 'c',
		_handle = nil,
		_bufferSize = 0,
		_bufferMode = 'none'
	}, File)
end

function nativefs.newFileData(filepath)
	local f = nativefs.newFile(filepath)
	local ok, err = f:open('r')
	if not ok then return nil, err end

	local data = f:read()
	f:close()
	return love.filesystem.newFileData(data, filepath)
end

function nativefs.mount()
end

function nativefs.unmount()
end

function nativefs.read(containerOrName, nameOrSize, sizeOrNil)
	local container, name, size
	if sizeOrNil then
		container, name, size = containerOrName, nameOrSize, sizeOrNil
	elseif not nameOrSize then
		container, name, size = 'string', containerOrName, 'all'
	else
		if type(nameOrSize) == 'number' or nameOrSize == 'all' then
			container, name, size = 'string', containerOrName, nameOrSize
		else
			container, name, size = containerOrName, nameOrSize, 'all'
		end
	end

	local file = nativefs.newFile(name)
	if not file:open('r') then
		return nil, "Could not open file for reading: " .. name
	end

	local data, size = file:read(container, size)
	file:close()
	return data, size
end

function nativefs.write(name, data, size)
	local file = nativefs.newFile(name)
	if not file:open('w') then
		return nil, "Could not open file for writing: " .. name
	end

	local ok, err = file:write(data, size or 'all')
	file:close()
	return ok, err
end

function nativefs.append(name, data, size)
	local file = nativefs.newFile(name)
	if not file:open('a') then
		return nil, "Could not open file for writing: " .. name
	end

	local ok, err = file:write(data, size or 'all')
	file:close()
	return ok, err
end

function nativefs.lines(name)
	local f = nativefs.newFile(name)
	local ok, err = f:open('r')
	if not ok then return nil, err end
	return f:lines()
end

function nativefs.load(name)
	local chunk, err = nativefs.read(name)
	if not chunk then
		return nil, err
	end
	return loadstring(chunk, name)
end

function nativefs.getDirectoryItems(dir, callback)
end

function nativefs.getWorkingDirectory()
	return getcwd()
end

function nativefs.setWorkingDirectory(path)
	if chdir(path) ~= 0 then
		return false, "Could not set working directory"
	end
	return true
end

function nativefs.getDriveList()
	if ffi.os ~= 'Windows' then
		return { '/' }
	end

	local drives = {}
	local bits = C.GetLogicalDrives()
	for i = 0, 25 do
		if bit.band(bits, 2 ^ i) > 0 then
			table.insert(drives, string.char(65 + i) .. ':/')
		end
	end

	return drives
end

function nativefs.getInfo(name)
end

function nativefs.createDirectory(path)
end

function nativefs.remove(name)
	if unlink(name) ~= 0 then
		return false, "Could not remove file " .. name
	end
	return true
end

return nativefs
