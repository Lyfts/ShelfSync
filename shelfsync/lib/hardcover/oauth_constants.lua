-- Public OAuth client configuration for ShelfSync's native KOReader app.
-- Device Authorization Grant clients do not use a client secret.
return {
  API_BASE = "https://api.hardcover.app",
  DEVICE_ENDPOINT = "/oauth2/device",
  TOKEN_ENDPOINT = "/oauth2/token",
  REVOKE_ENDPOINT = "/oauth2/revoke",
  CLIENT_ID = "5ec829c1-5ad8-4788-9e5c-989283966a6b",
  SCOPES = "read:me:content read:catalog read:library write:library write:reviews",
  -- Increment this whenever SCOPES changes so existing OAuth grants are
  -- cleared and users are prompted to sign in again.
  SCOPE_REVISION = 1,
}
