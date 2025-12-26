#!/bin/bash
# Calibre metadata fetcher - automatically adds books and fetches metadata
# Run via: systemctl start calibre-metadata.service
# Or manually: /home/anon/nas-media-server/scripts/calibre-metadata.sh

CALIBRE_LIBRARY="/var/lib/calibre"
EBOOK_SOURCE="/tank/media/ebooks"
LOG_FILE="/var/log/calibre-metadata.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Starting Calibre metadata fetch..."

# Find all ebook files and add them to Calibre
find "$EBOOK_SOURCE" -type f \( -name "*.epub" -o -name "*.pdf" -o -name "*.mobi" -o -name "*.azw" -o -name "*.azw3" \) | while read -r book; do
    # Check if book already exists in library (by filename)
    filename=$(basename "$book")

    # Add book if not already in library
    if ! calibredb --with-library="$CALIBRE_LIBRARY" search "title:\"$filename\"" 2>/dev/null | grep -q "[0-9]"; then
        log "Adding: $filename"
        calibredb --with-library="$CALIBRE_LIBRARY" add "$book" 2>/dev/null
    fi
done

# Fetch metadata for all books without covers or with minimal metadata
log "Fetching metadata for books..."

# Get list of book IDs
book_ids=$(calibredb --with-library="$CALIBRE_LIBRARY" list --fields=id 2>/dev/null | tail -n +2 | awk '{print $1}')

for id in $book_ids; do
    # Check if book has cover
    book_info=$(calibredb --with-library="$CALIBRE_LIBRARY" show_metadata "$id" 2>/dev/null)
    has_cover=$(echo "$book_info" | grep -c "Cover")
    title=$(echo "$book_info" | grep "Title" | cut -d: -f2- | xargs)

    if [ "$has_cover" -eq 0 ] || echo "$book_info" | grep -q "Comments.*:$"; then
        log "Fetching metadata for ID $id: $title"

        # Fetch metadata from online sources
        calibredb --with-library="$CALIBRE_LIBRARY" embed_metadata "$id" 2>/dev/null

        # Try to download cover
        ebook-meta --get-cover="/tmp/cover_$id.jpg" "$CALIBRE_LIBRARY"/*/"$title"/*.epub 2>/dev/null
        if [ -f "/tmp/cover_$id.jpg" ]; then
            calibredb --with-library="$CALIBRE_LIBRARY" set_metadata --field cover:"/tmp/cover_$id.jpg" "$id" 2>/dev/null
            rm -f "/tmp/cover_$id.jpg"
        fi
    fi
done

# Export covers to source folders for Jellyfin
log "Exporting covers to source folders..."
calibredb --with-library="$CALIBRE_LIBRARY" list --fields=id,title,authors 2>/dev/null | tail -n +2 | while read -r line; do
    id=$(echo "$line" | awk '{print $1}')

    # Export cover
    cover_path=$(calibredb --with-library="$CALIBRE_LIBRARY" show_metadata "$id" 2>/dev/null | grep "Cover" | awk '{print $NF}')

    if [ -n "$cover_path" ] && [ -f "$cover_path" ]; then
        # Find matching book in source and copy cover
        title=$(calibredb --with-library="$CALIBRE_LIBRARY" show_metadata "$id" 2>/dev/null | grep "Title" | cut -d: -f2- | xargs)
        author=$(calibredb --with-library="$CALIBRE_LIBRARY" show_metadata "$id" 2>/dev/null | grep "Author" | cut -d: -f2- | xargs | cut -d'&' -f1 | xargs)

        dest_dir="$EBOOK_SOURCE/$author/$title"
        if [ -d "$dest_dir" ] && [ ! -f "$dest_dir/cover.jpg" ]; then
            cp "$cover_path" "$dest_dir/cover.jpg" 2>/dev/null && log "Exported cover: $author/$title"
        fi
    fi
done

log "Calibre metadata fetch complete!"
