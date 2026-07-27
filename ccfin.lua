-- ccfin: a tiny Jellyfin music client for CC:Tweaked.
local APP_VERSION = "0.2.0"
local CONFIG_PATH = ".ccfin"
local DEBUG_PATH = ".ccfin-debug"
local argv = {...}
local VERBOSE = false
local PROBE = false
for _, arg in ipairs(argv) do
  if arg == "--verbose" or arg == "-v" then VERBOSE = true end
  if arg == "--probe" then PROBE = true end
  if arg == "--version" then
    print("ccfin " .. APP_VERSION)
    return
  end
end

if VERBOSE then
  local file = fs.open(DEBUG_PATH, "w")
  if file then
    file.writeLine("ccfin " .. APP_VERSION .. " verbose log")
    file.close()
  end
end

local function debug(message)
  if not VERBOSE then return end
  local line = "[ccfin] " .. tostring(message)
  print(line)
  local file = fs.open(DEBUG_PATH, "a")
  if file then
    file.writeLine(line)
    file.close()
  end
end

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
    'Client="ccfin"',
    -- Keep values deliberately conservative. Some HTTP/auth parsers reject the
    -- entire structured header when a quoted value contains punctuation.
    'Device="CCTweaked"',
    'DeviceId="' .. (config.device_id or os.getComputerID()) .. '"',
    'Version="' .. APP_VERSION .. '"',
  }
  if token then fields[#fields + 1] = 'Token="' .. token .. '"' end
  return "MediaBrowser " .. table.concat(fields, ", ")
end

local function request(method, path, body, unauthenticated, debugBody)
  local authorization = authHeader(unauthenticated and nil or config.token)
  local headers = {
    ["Accept"] = "application/json",
    -- Use Jellyfin's native header. Authorization is a reserved header in some
    -- Java HTTP clients and is unnecessary now redirects are handled manually.
    ["X-Emby-Authorization"] = authorization,
  }
  local encoded
  if body then
    headers["Content-Type"] = "application/json"
    encoded = type(body) == "string" and body or textutils.serializeJSON(body)
  end
  local url = config.server .. path
  debug(method .. " " .. url)
  debug("request headers: Accept, X-Emby-Authorization (" ..
    #authorization .. " bytes)" .. (body and ", Content-Type" or ""))
  if encoded then
    debug("request body (" .. #encoded .. " bytes): " ..
      (debugBody or "<redacted>"))
  end

  local function origin(target)
    return target:match("^(https?://[^/]+)")
  end

  local function mayForwardCredentials(from, to)
    local fromScheme, fromHost = from:match("^(https?)://([^/]+)")
    local toScheme, toHost = to:match("^(https?)://([^/]+)")
    if not fromHost or not toHost or fromHost:lower() ~= toHost:lower() then
      return false
    end
    return fromScheme == toScheme or
      (fromScheme == "http" and toScheme == "https")
  end

  local function resolveRedirect(current, location)
    if location:match("^https?://") then return location end
    local currentOrigin = assert(origin(current), "Invalid redirect source URL")
    if location:sub(1, 1) == "/" then return currentOrigin .. location end
    return current:match("^(.*/)") .. location
  end

  local function send(target, redirects)
    local options = {
      url = target,
      headers = headers,
      binary = method == "GET",
      redirect = false,
      method = method,
      body = encoded,
    }
    local handle, err, failed
    if method == "POST" then
      handle, err, failed = http.post(options)
    else
      handle, err, failed = http.get(options)
    end

    local response = handle or failed
    if response and response.getResponseCode then
      local code = response.getResponseCode()
      if code == 301 or code == 302 or code == 307 or code == 308 then
        local responseHeaders = response.getResponseHeaders()
        local location = responseHeaders.Location or responseHeaders.location
        if location then
          response.close()
          if redirects >= 5 then error("Too many HTTP redirects", 0) end
          local redirected = resolveRedirect(target, location)
          debug(("redirect: HTTP %d -> %s"):format(code, redirected))
          if not mayForwardCredentials(target, redirected) then
            error("Refusing to forward Jellyfin credentials to another origin: " ..
              redirected, 0)
          end
          return send(redirected, redirects + 1)
        end
      end
    end
    return handle, err, failed
  end

  local handle, err, failed = send(url, 0)
  if not handle then
    if failed and failed.readAll then
      local code, message = failed.getResponseCode()
      local responseHeaders = failed.getResponseHeaders()
      local detail = failed.readAll()
      failed.close()
      debug(("response: HTTP %s %s"):format(tostring(code), tostring(message)))
      debug("response Content-Type: " ..
        tostring(responseHeaders["Content-Type"] or responseHeaders["content-type"]))
      debug("response body: " .. (detail ~= "" and detail or "<empty>"))
      if path == "/Users/AuthenticateByName" and code == 400 then
        error("Jellyfin rejected the login request format (HTTP 400).", 0)
      elseif path == "/Users/AuthenticateByName" and code == 401 then
        error("Invalid Jellyfin username or password (HTTP 401).", 0)
      end
      error(err .. (detail ~= "" and (": " .. detail) or ""), 0)
    end
    error(err or "HTTP request failed", 0)
  end
  local code, message = handle.getResponseCode()
  local responseHeaders = handle.getResponseHeaders()
  local raw = handle.readAll()
  handle.close()
  debug(("response: HTTP %s %s"):format(tostring(code), tostring(message)))
  debug("response Content-Type: " ..
    tostring(responseHeaders["Content-Type"] or responseHeaders["content-type"]))
  debug("response body: " .. (code >= 200 and code < 300 and "<redacted>" or raw))
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
  if not server:match("^https?://") then server = "https://" .. server end
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
  debug("normalized server: " .. config.server)
  debug("username: " .. textutils.serializeJSON(username) ..
    " (" .. #username .. " bytes); password: <redacted> (" ..
    #password .. " bytes)")
  local usernameJSON = textutils.serializeJSON(username)
  local passwordJSON = textutils.serializeJSON(password)
  local loginBody = '{"Username":' .. usernameJSON .. ',"Pw":' .. passwordJSON .. '}'
  local redactedBody = '{"Username":' .. usernameJSON .. ',"Pw":"<redacted>"}'
  config.device_id = config.device_id or ("ccfin-" .. os.getComputerID())
  debug("device ID: " .. config.device_id)
  local allowed, reason = http.checkURL(config.server .. "/Users/AuthenticateByName")
  debug("http.checkURL: " .. tostring(allowed) ..
    (reason and (" (" .. reason .. ")") or ""))
  local result = request("POST", "/Users/AuthenticateByName",
    loginBody, true, redactedBody)
  config.token = assert(result.AccessToken, "Login response had no access token")
  config.user_id = assert(result.User and result.User.Id, "Login response had no user")
  config.username = result.User.Name
  config.profile = config.profile or "flac"
  saveConfig(config)
end

local function ensureLogin()
  if not config.server or not config.token or not config.user_id then login() end
end

local function probeHeaders()
  local marker = authHeader(nil)
  print("Testing CC:Tweaked request headers via httpbin.org...")
  local handle, err, failed = http.post(
    "https://httpbin.org/anything",
    '{"probe":true}',
    {
      ["Accept"] = "application/json",
      ["Content-Type"] = "application/json",
      ["Authorization"] = marker,
      ["X-Emby-Authorization"] = marker,
    }
  )
  if not handle then
    local detail = failed and failed.readAll and failed.readAll() or ""
    if failed and failed.close then failed.close() end
    error("Header probe failed: " .. tostring(err) ..
      (detail ~= "" and (": " .. detail) or ""), 0)
  end
  local response = textutils.unserializeJSON(handle.readAll())
  handle.close()
  local headers = response and response.headers or {}
  local authorization = headers.Authorization or headers.authorization
  local emby = headers["X-Emby-Authorization"] or
    headers["x-emby-authorization"]
  print("Authorization transmitted: " .. tostring(authorization == marker))
  print("X-Emby-Authorization transmitted: " .. tostring(emby == marker))
  if authorization and authorization ~= marker then
    print("Authorization arrived altered (" .. #authorization .. " bytes)")
  end
  if emby and emby ~= marker then
    print("X-Emby-Authorization arrived altered (" .. #emby .. " bytes)")
  end
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
    decoder = "pcm",
    extension = "wav",
    params = {
      Container = "wav", TranscodingContainer = "wav",
      AudioCodec = "pcm_s16le", EnableDirectPlay = "false",
      EnableDirectStream = "false", TranscodingProtocol = "http",
      AudioSampleRate = 48000, MaxAudioChannels = 2,
    },
  },
  flac = {
    decoder = "flac",
    extension = "flac",
    params = {
      Container = "flac", TranscodingContainer = "flac",
      AudioCodec = "flac", EnableDirectPlay = "false",
      EnableDirectStream = "false", TranscodingProtocol = "http",
      AudioSampleRate = 48000, MaxAudioChannels = 2,
    },
  },
  original = {
    decoder = "flac",
    extension = "flac",
    direct = true,
  },
}

local function playbackUrl(item)
  local profile = profiles[config.profile] or profiles.wav
  if profile.direct then
    return config.server .. "/Items/" .. item.Id .. "/Download", profile
  end
  local params = {}
  for k, v in pairs(profile.params) do params[k] = v end
  params.UserId = config.user_id
  params.DeviceId = config.device_id
  params.MaxStreamingBitrate = config.bitrate or 1536000
  return config.server .. "/Audio/" .. item.Id .. "/universal?" ..
    query(params), profile
end

local function play(item)
  if not fs.exists("aukit.lua") then
    error("Missing aukit.lua. Run: ccfin-install", 0)
  end
  local aukitOk, aukit = pcall(require, "aukit")
  local aukitVersion = aukitOk and aukit and aukit._VERSION or "unknown"
  if not aukitOk then error("Could not load AUKit: " .. tostring(aukit), 0) end
  local url, profile = playbackUrl(item)
  local speakers = {peripheral.find("speaker")}
  if #speakers == 0 then error("No speaker attached", 0) end
  local speakerNames = {}
  for i, speaker in ipairs(speakers) do
    speakerNames[i] = peripheral.getName(speaker)
  end
  debug("playback item: " .. tostring(item.Id) .. " / " ..
    tostring(item.Name))
  debug("playback profile: " .. tostring(config.profile))
  debug("AUKit file: aukit.lua=" .. tostring(fs.exists("aukit.lua")))
  debug("AUKit loaded: " .. tostring(aukitOk) ..
    ", version=" .. tostring(aukitVersion))
  debug("speakers (" .. #speakers .. "): " ..
    (#speakerNames > 0 and table.concat(speakerNames, ", ") or "<none>"))
  debug("stream URL: " .. url)
  debug("decoder: " .. profile.decoder)
  term.clear()
  term.setCursorPos(1, 1)
  print("Now playing")
  print(item.Name or "Unknown")
  print((item.AlbumArtist or item.Artists and item.Artists[1]) or "")
  print()
  print("Profile: " .. config.profile .. "  (hold Ctrl+T to stop)")
  local callOk, playbackError = pcall(function()
    local response, err, failed = http.get({
      url = url,
      headers = {
        ["X-Emby-Authorization"] = authHeader(config.token),
      },
      binary = true,
      redirect = false,
    })
    if not response then
      local detail = ""
      if failed and failed.readAll then
        detail = failed.readAll()
        failed.close()
      end
      error(tostring(err) .. (detail ~= "" and (": " .. detail) or ""), 0)
    end

    local code, message = response.getResponseCode()
    local responseHeaders = response.getResponseHeaders()
    debug(("audio response: HTTP %s %s"):format(
      tostring(code), tostring(message)))
    debug("audio Content-Type: " .. tostring(
      responseHeaders["Content-Type"] or responseHeaders["content-type"]))
    debug("audio Content-Length: " .. tostring(
      responseHeaders["Content-Length"] or responseHeaders["content-length"]))
    if code < 200 or code >= 300 then
      local detail = response.readAll()
      response.close()
      error(("Jellyfin audio request returned HTTP %d: %s"):format(
        code, detail), 0)
    end

    local data = response.readAll()
    response.close()
    debug("audio bytes received: " .. #data)

    aukit.defaultInterpolation = "cubic"
    local mono = #speakers == 1
    local iterator
    if profile.decoder == "pcm" then
      iterator = aukit.stream.pcm(
        data, 16, "signed", 2, 48000, false, mono)
    else
      -- AUKit's chunked FLAC reader is currently broken. Passing the complete
      -- compressed response as a string uses its reliable decoder path.
      iterator = aukit.stream.flac(data, mono)
    end

    local playOptions = {callback = iterator}
    for i, speaker in ipairs(speakers) do playOptions[i] = speaker end
    aukit.play(playOptions)
  end)
  debug("AUKit playback completed: ok=" .. tostring(callOk) ..
    (callOk and "" or (", error=" .. tostring(playbackError))))
  if not callOk then
    printError(playbackError)
    printError("AUKit playback failed.")
    print("Run ccfin --verbose for playback diagnostics.")
    print("Try another profile in Settings.")
    print("Press any key.")
    os.pullEvent("key")
  end
end

local function settings()
  local items = {
    { key = "wav", name = "PCM - server-decoded stereo (large)" },
    { key = "flac", name = "FLAC - compressed (recommended)" },
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
  if PROBE then return probeHeaders() end
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
if not ok then
  printError(err)
  if VERBOSE then print("Verbose log: " .. DEBUG_PATH) end
end
