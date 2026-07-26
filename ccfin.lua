-- ccfin: a tiny Jellyfin music client for CC:Tweaked.
local APP_VERSION = "0.1.0"
local CONFIG_PATH = ".ccfin"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function urlEncode(s)
  return tostring(s):gsub("\n", "\r\n"):gsub("([^%w%-_%.~])", function(c)
    return ("%%%02X"):format(c:byte())
  end)
end

local function query(params)
  local out = {}
  for k, v in pairs(params or {}) do
    if v ~= nil then out[#out + 1] = urlEncode(k) .. "=" .. urlEncode(v) end
  end
  table.sort(out)
  return table.concat(out, "&")
end

local function loadConfig()
  if not fs.exists(CONFIG_PATH) then return {} end
  local h = fs.open(CONFIG_PATH, "r")
  local value = textutils.unserialize(h.readAll())
  h.close()
  return type(value) == "table" and value or {}
end

local function saveConfig(config)
  local h = assert(fs.open(CONFIG_PATH, "w"))
  h.write(textutils.serialize(config))
  h.close()
end

local config = loadConfig()

local function authHeader(token)
  local fields = {
    'MediaBrowser Client="ccfin"',
    'Device="CC:Tweaked Computer"',
    'DeviceId="' .. (config.device_id or os.getComputerID()) .. '"',
    'Version="' .. APP_VERSION .. '"',
  }
  if token then fields[#fields + 1] = 'Token="' .. token .. '"' end
  return "MediaBrowser " .. table.concat(fields, ", ")
end

local function request(method, path, body, unauthenticated)
  local authorization = authHeader(unauthenticated and nil or config.token)
  local headers = {
    ["Accept"] = "application/json",
    -- Jellyfin accepts both names. Some CC/server combinations appear to lose
    -- X-Emby-Authorization, while the standard Authorization header survives.
    ["Authorization"] = authorization,
    ["X-Emby-Authorization"] = authorization,
  }
  local encoded
  if body then
    headers["Content-Type"] = "application/json"
    encoded = textutils.serializeJSON(body)
  end
  local url = config.server .. path
  local handle, err, failed
  if method == "POST" then
    handle, err, failed = http.post(url, encoded, headers)
  else
    handle, err, failed = http.get(url, headers, true)
  end
  if not handle then
    if failed and failed.readAll then
      local code = failed.getResponseCode()
      local detail = failed.readAll()
      failed.close()
      if path == "/Users/AuthenticateByName" and (code == 400 or code == 401) then
        error(("Jellyfin login failed (HTTP %d). Check the username and password."):format(code), 0)
      end
      error(err .. (detail ~= "" and (": " .. detail) or ""), 0)
    end
    error(err or "HTTP request failed", 0)
  end
  local code = handle.getResponseCode()
  local raw = handle.readAll()
  handle.close()
  if code < 200 or code >= 300 then
    if code == 401 and path == "/Users/AuthenticateByName" then
      error("Invalid Jellyfin username or password.", 0)
    end
    local detail = trim(raw)
    if detail ~= "" and #detail <= 160 then
      error(("Jellyfin returned HTTP %d: %s"):format(code, detail), 0)
    end
    error("Jellyfin returned HTTP " .. code, 0)
  end
  return raw ~= "" and textutils.unserializeJSON(raw) or {}
end

local function normalizeServer(server)
  server = trim(server):gsub("/+$", "")
  if not server:match("^https?://") then server = "http://" .. server end
  return server
end

local function prompt(label, hidden)
  write(label)
  return read(hidden and "*" or nil)
end

local function login()
  term.clear()
  term.setCursorPos(1, 1)
  print("ccfin setup")
  print()
  config.server = normalizeServer(prompt("Jellyfin URL: "))
  local username = trim(prompt("Username: "))
  local password = prompt("Password: ", true)
  config.device_id = config.device_id or ("ccfin-" .. os.getComputerID())
  local result = request("POST", "/Users/AuthenticateByName", {
    Username = username,
    Pw = password,
  }, true)
  config.token = assert(result.AccessToken, "Login response had no access token")
  config.user_id = assert(result.User and result.User.Id, "Login response had no user")
  config.username = result.User.Name
  config.profile = config.profile or "wav"
  saveConfig(config)
end

local function ensureLogin()
  if not config.server or not config.token or not config.user_id then login() end
end

local function choose(title, items, label, allowSearch)
  local page, perPage = 1, math.max(3, select(2, term.getSize()) - 5)
  while true do
    local pages = math.max(1, math.ceil(#items / perPage))
    if page > pages then page = pages end
    term.clear()
    term.setCursorPos(1, 1)
    print(title .. ("  [%d/%d]"):format(page, pages))
    print(("="):rep(math.min(#title, select(1, term.getSize()))))
    local first = (page - 1) * perPage + 1
    local last = math.min(#items, first + perPage - 1)
    if #items == 0 then print("(nothing found)") end
    for i = first, last do
      print(("%d. %s"):format(i - first + 1, label(items[i])))
    end
    print()
    write("[number] select  [n/p] page  [b] back")
    if allowSearch then write("  [/] search") end
    print()
    local input = trim(read()):lower()
    local number = tonumber(input)
    if number and number >= 1 and first + number - 1 <= last then
      return items[first + number - 1]
    elseif input == "n" and page < pages then page = page + 1
    elseif input == "p" and page > 1 then page = page - 1
    elseif input == "b" or input == "q" then return nil
    elseif input == "/" and allowSearch then
      return false
    end
  end
end

local function getItems(params)
  params.UserId = config.user_id
  params.Fields = params.Fields or "PrimaryImageAspectRatio,RunTimeTicks,AlbumArtist"
  local result = request("GET", "/Users/" .. config.user_id .. "/Items?" .. query(params))
  return result.Items or {}
end

local profiles = {
  wav = {
    extension = "wav",
    params = {
      Container = "wav", TranscodingContainer = "wav",
      AudioCodec = "pcm_s16le", EnableDirectPlay = "false",
      EnableDirectStream = "false", TranscodingProtocol = "http",
      AudioSampleRate = 48000, MaxAudioChannels = 2,
    },
    -- Jellyfin's universal endpoint emits headerless little-endian PCM for this
    -- profile, despite reporting audio/wav as its content type.
    options = "type=pcm,streamData=true,bitDepth=16,dataType=signed,channels=2,sampleRate=48000,bigEndian=false,interpolation=cubic",
  },
  flac = {
    extension = "flac",
    params = {
      Container = "flac", TranscodingContainer = "flac",
      AudioCodec = "flac", EnableDirectPlay = "false",
      EnableDirectStream = "false", TranscodingProtocol = "http",
      AudioSampleRate = 48000, MaxAudioChannels = 2,
    },
    options = "type=flac,streamData=true,interpolation=cubic",
  },
  original = {
    extension = "flac",
    direct = true,
    options = "type=flac,streamData=true,interpolation=cubic",
  },
}

local function playbackUrl(item)
  local profile = profiles[config.profile] or profiles.wav
  if profile.direct then
    return config.server .. "/Items/" .. item.Id .. "/Download?" .. query {
      api_key = config.token,
    }, profile.options
  end
  local params = {}
  for k, v in pairs(profile.params) do params[k] = v end
  params.UserId = config.user_id
  params.DeviceId = config.device_id
  params.api_key = config.token
  params.MaxStreamingBitrate = config.bitrate or 1536000
  return config.server .. "/Audio/" .. item.Id .. "/universal?" ..
    query(params), profile.options
end

local function play(item)
  if not fs.exists("austream.lua") or not fs.exists("aukit.lua") then
    error("Missing aukit.lua/austream.lua. Run: ccfin-install", 0)
  end
  local url, options = playbackUrl(item)
  term.clear()
  term.setCursorPos(1, 1)
  print("Now playing")
  print(item.Name or "Unknown")
  print((item.AlbumArtist or item.Artists and item.Artists[1]) or "")
  print()
  print("Profile: " .. config.profile .. "  (hold Ctrl+T to stop)")
  local ok, err = pcall(shell.run, "austream.lua", url, options)
  if not ok then
    printError(err)
    print("Try another profile in Settings.")
    print("Press any key.")
    os.pullEvent("key")
  end
end

local function settings()
  local items = {
    { key = "wav", name = "PCM - server-decoded stereo (recommended)" },
    { key = "flac", name = "FLAC - server-transcoded" },
    { key = "original", name = "Original FLAC - direct download" },
  }
  local picked = choose("Playback profile (current: " .. config.profile .. ")", items,
    function(v) return v.name end)
  if picked then config.profile = picked.key; saveConfig(config) end
end

local function browseTracks(album)
  local tracks = getItems {
    ParentId = album.Id, IncludeItemTypes = "Audio",
    Recursive = "true", SortBy = "ParentIndexNumber,IndexNumber,SortName",
  }
  while true do
    local track = choose(album.Name, tracks, function(v)
      local number = v.IndexNumber and (v.IndexNumber .. ". ") or ""
      return number .. (v.Name or "Unknown")
    end)
    if not track then return end
    play(track)
  end
end

local function search()
  term.clear()
  term.setCursorPos(1, 1)
  local text = prompt("Search music: ")
  if trim(text) == "" then return end
  local items = getItems {
    SearchTerm = text, IncludeItemTypes = "Audio",
    Recursive = "true", SortBy = "SortName", Limit = 200,
  }
  while true do
    local track = choose("Search: " .. text, items, function(v)
      return (v.Name or "Unknown") .. (v.AlbumArtist and (" - " .. v.AlbumArtist) or "")
    end)
    if not track then return end
    play(track)
  end
end

local function browseLibrary(library)
  local albums = getItems {
    ParentId = library.Id, IncludeItemTypes = "MusicAlbum",
    Recursive = "true", SortBy = "AlbumArtist,SortName", Limit = 1000,
  }
  while true do
    local album = choose(library.Name, albums, function(v)
      return (v.Name or "Unknown") .. (v.AlbumArtist and (" - " .. v.AlbumArtist) or "")
    end, true)
    if album == false then search()
    elseif not album then return
    else browseTracks(album) end
  end
end

local function main()
  ensureLogin()
  while true do
    local views = request("GET", "/Users/" .. config.user_id .. "/Views").Items or {}
    local music = {}
    for _, view in ipairs(views) do
      if view.CollectionType == "music" then music[#music + 1] = view end
    end
    local menu = {
      { special = "search", Name = "Search all music" },
      { special = "settings", Name = "Settings" },
      { special = "logout", Name = "Log out" },
    }
    for _, view in ipairs(music) do table.insert(menu, #menu - 2, view) end
    local picked = choose("ccfin - " .. (config.username or "Jellyfin"), menu,
      function(v) return v.Name end)
    if not picked then return
    elseif picked.special == "search" then search()
    elseif picked.special == "settings" then settings()
    elseif picked.special == "logout" then
      config.token, config.user_id, config.username = nil, nil, nil
      saveConfig(config)
      login()
    else browseLibrary(picked) end
  end
end

local ok, err = pcall(main)
term.setCursorBlink(false)
if not ok then printError(err) end
