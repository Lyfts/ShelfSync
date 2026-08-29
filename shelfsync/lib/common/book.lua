local Book = {}
local reading_format_labels = {
  "Physical Book",
  "Audiobook",
  nil,
  "E-Book"
}

function Book:readingFormat(format_id)
  if not format_id then
    return
  end

  return reading_format_labels[format_id]
end

function Book:editionFormatName(edition_format, format_id)
  if edition_format and edition_format ~= "" then
    return edition_format
  end

  return self:readingFormat(format_id)
end

function Book:parseIdentifiers(identifiers)
  local result = {}

  if not identifiers then
    return result
  end

  for line in string.lower(identifiers):gmatch("%s*([^%s]+)%s*") do
    -- Goodreads' own book id, as surfaced by Calibre's standard "goodreads"
    -- OPF identifier scheme (see goodreads.koplugin's goodreads_identifiers.lua).
    local gr = string.match(line, "goodreads:(%d+)") or
               string.match(line, "goodreads%-id:(%d+)") or
               string.match(line, "gr:(%d+)")
    if gr then
      result.goodreads_id = gr
    end

    -- Hardcover's own scheme, kept as book_slug -- consumed only by
    -- HardcoverApi:findBookByIdentifiers.
    local hc = string.match(line, "hardcover:([%w_-]+)") or
               string.match(line, "hardcover%-slug:([%w_-]+)")
    if hc then
      result.book_slug = hc
    end

    local hc_edition = string.match(line, "hardcover%-edition:(%d+)")
    if hc_edition then
      result.book_slug = hc_edition
    end


    local sg = string.match(line, "storygraph:([%w_-]+)")
    local sg_edition = string.match(line, "storygraph%-edition:(%d+)")
    if sg_edition then
      result.storygraph_slug = sg_edition
    elseif sg then
      result.storygraph_slug = sg
    end

    if not hc and not hc_edition and not sg and not sg_edition and not gr then
      -- strip prefix
      local str = string.gsub(line, "^[^%s]+%s*:%s*", "")
      str = string.gsub(str, "-", "")

      if str and string.find(str, "^%d+$") then
        local len = #str

        if len == 13 then
          result.isbn_13 = str
        elseif len == 10 then
          result.isbn_10 = str
        end
      end
    end
  end
  return result
end

return Book
