-- AES-256-CBC secret-at-rest helper, used to cache the Fable password so an
-- expired session can silently re-authenticate instead of forcing the user
-- to retype it (see fable/api.lua's login()/request()). Every KOReader
-- LuaJIT build we target already links libcrypto (LuaSec/HTTPS depends on
-- it, and koreader-base's own ffi/crypto.lua loads the exact same
-- `ffi.loadlib("crypto", "57")` handle for its DRM key unwrapping), so this
-- reuses that instead of shipping a pure-Lua cipher.
--
-- There's no OS keystore available to a KOReader plugin, so the AES key
-- below is itself just another local file (kept separate from the
-- ciphertext's settings file only so a leak of one alone isn't enough) --
-- this stops the password sitting in cleartext in a settings file someone
-- pastes for support/backup, but it is NOT protection against an attacker
-- who already has full access to the device's filesystem. Every entry point
-- degrades to nil (never raises) if libcrypto can't be loaded -- e.g. under
-- the plain-Lua busted test runner, which has no `ffi` module at all --
-- callers fall back to storing the secret in plaintext, per the plugin's
-- "encrypt if possible, plaintext otherwise" contract.
local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then ffi = nil end

local CryptoUtil = {}

local KEYRING_FILENAME = "shelfsync_keyring.lua"
local KEY_SETTING = "fable_aes_key"

local libcrypto -- nil = not yet resolved, false = resolution failed
local cdef_done = false

local function ensure_cdef()
  if cdef_done then return end
  cdef_done = true
  ffi.cdef([[
    typedef struct engine_st ENGINE;
    typedef struct evp_cipher_st EVP_CIPHER;
    typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
    EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
    void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *);
    int EVP_EncryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
    int EVP_EncryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
    int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
    int EVP_DecryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
    int EVP_DecryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
    int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
    const EVP_CIPHER *EVP_aes_256_cbc(void);
    int RAND_bytes(unsigned char *, int);
  ]])
end

local function get_libcrypto()
  if libcrypto ~= nil then
    return libcrypto or nil
  end
  if not ffi then
    libcrypto = false
    return nil
  end

  local ok, result = pcall(function()
    ensure_cdef()
    return ffi.loadlib("crypto", "57")
  end)

  if ok and result then
    libcrypto = result
  else
    libcrypto = false
    local logger_ok, logger = pcall(require, "logger")
    if logger_ok then
      logger.warn("crypto_util: libcrypto unavailable, secrets will be stored in plaintext: " .. tostring(result))
    end
  end

  return libcrypto or nil
end

local function random_bytes(lib, n)
  local buf = ffi.new("unsigned char[?]", n)
  if lib.RAND_bytes(buf, n) ~= 1 then
    return nil
  end
  return ffi.string(buf, n)
end

local function to_hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function from_hex(s)
  if not s:match("^%x*$") or #s % 2 ~= 0 then
    return nil
  end
  return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

-- AES-256-CBC encrypt, PKCS7-padded (OpenSSL's EVP default -- left enabled),
-- random 16-byte IV prepended to the ciphertext. Returns a hex string, or
-- nil if libcrypto is unavailable or the operation fails.
function CryptoUtil.aesEncrypt(plaintext, key)
  local lib = get_libcrypto()
  if not lib or not plaintext or plaintext == "" or not key or #key ~= 32 then
    return nil
  end

  local iv = random_bytes(lib, 16)
  if not iv then return nil end

  local ctx = lib.EVP_CIPHER_CTX_new()
  if ctx == nil then return nil end

  local ok = lib.EVP_EncryptInit_ex(ctx, lib.EVP_aes_256_cbc(), nil, key, iv) == 1
  local output, output_len

  if ok then
    output = ffi.new("unsigned char[?]", #plaintext + 16)
    local len1 = ffi.new("int[1]")
    ok = lib.EVP_EncryptUpdate(ctx, output, len1, plaintext, #plaintext) == 1
    if ok then
      local len2 = ffi.new("int[1]")
      ok = lib.EVP_EncryptFinal_ex(ctx, output + len1[0], len2) == 1
      if ok then
        output_len = len1[0] + len2[0]
      end
    end
  end

  lib.EVP_CIPHER_CTX_free(ctx)
  if not ok then return nil end

  return to_hex(iv .. ffi.string(output, output_len))
end

-- Inverse of aesEncrypt. Returns nil (never raises) on a bad key, corrupt
-- blob, or missing libcrypto.
function CryptoUtil.aesDecrypt(blob_hex, key)
  local lib = get_libcrypto()
  if not lib or not blob_hex or blob_hex == "" or not key or #key ~= 32 then
    return nil
  end

  local raw = from_hex(blob_hex)
  if not raw or #raw <= 16 then
    return nil
  end

  local iv = raw:sub(1, 16)
  local ciphertext = raw:sub(17)

  local ctx = lib.EVP_CIPHER_CTX_new()
  if ctx == nil then return nil end

  local ok = lib.EVP_DecryptInit_ex(ctx, lib.EVP_aes_256_cbc(), nil, key, iv) == 1
  local output, output_len

  if ok then
    output = ffi.new("unsigned char[?]", #ciphertext + 16)
    local len1 = ffi.new("int[1]")
    ok = lib.EVP_DecryptUpdate(ctx, output, len1, ciphertext, #ciphertext) == 1
    if ok then
      local len2 = ffi.new("int[1]")
      ok = lib.EVP_DecryptFinal_ex(ctx, output + len1[0], len2) == 1
      if ok then
        output_len = len1[0] + len2[0]
      end
    end
  end

  lib.EVP_CIPHER_CTX_free(ctx)
  if not ok then return nil end

  return ffi.string(output, output_len)
end

local keyring

-- Opened lazily (not at module load) so requiring this file never touches
-- disk under environments without DataStorage (e.g. the busted test suite).
local function get_keyring()
  if keyring then return keyring end

  local ok_ds, DataStorage = pcall(require, "datastorage")
  local ok_ls, LuaSettings = pcall(require, "luasettings")
  if not (ok_ds and ok_ls) then
    return nil
  end

  local ok, result = pcall(function()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. KEYRING_FILENAME)
  end)
  if not ok then
    return nil
  end

  keyring = result
  return keyring
end

-- Random 32-byte AES-256 key, created once and reused for every secret this
-- module encrypts (kept in its own settings file, deliberately apart from
-- the ciphertext -- see file header). Returns nil if libcrypto or the
-- keyring file isn't available.
function CryptoUtil.getOrCreateKey()
  local lib = get_libcrypto()
  if not lib then return nil end

  local kr = get_keyring()
  if not kr then return nil end

  local hex_key = kr:readSetting(KEY_SETTING)
  if hex_key and #hex_key == 64 then
    local key = from_hex(hex_key)
    if key then return key end
  end

  local key = random_bytes(lib, 32)
  if not key then return nil end

  kr:saveSetting(KEY_SETTING, to_hex(key))
  kr:flush()
  return key
end

-- High-level helpers used by callers that just want "encrypt this secret if
-- at all possible" without touching key management themselves.
function CryptoUtil.encryptSecret(plaintext)
  local key = CryptoUtil.getOrCreateKey()
  if not key then return nil end
  return CryptoUtil.aesEncrypt(plaintext, key)
end

function CryptoUtil.decryptSecret(blob_hex)
  local key = CryptoUtil.getOrCreateKey()
  if not key then return nil end
  return CryptoUtil.aesDecrypt(blob_hex, key)
end

return CryptoUtil
