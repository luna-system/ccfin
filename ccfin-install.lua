local files = {
  ["aukit.lua"] = "https://raw.githubusercontent.com/MCJack123/AUKit/master/aukit.lua",
  ["austream.lua"] = "https://raw.githubusercontent.com/MCJack123/AUKit/master/austream.lua",
}

local args = {...}
local force = false
for _, arg in ipairs(args) do
  if arg == "--force" or arg == "-f" then force = true end
end

local cacheBuster = tostring(os.epoch("utc"))

for path, url in pairs(files) do
  if fs.exists(path) and not force then
    print(path .. " already exists; keeping it")
  else
    write("Downloading " .. path .. "... ")
    local response, err = http.get(url .. "?ccfin=" .. cacheBuster, nil, true)
    if not response then error(err, 0) end
    local body = response.readAll()
    response.close()
    local file = assert(fs.open(path, "wb"))
    file.write(body)
    file.close()
    print("done")
  end
end

print("AUKit installed. Put ccfin.lua on this computer, attach a speaker,")
print("and run: ccfin")
if not force then
  print("To replace existing AUKit files, run: ccfin-install --force")
end
