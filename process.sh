#!/usr/bin/env bash
# parse-export.sh
# Usage:
#   ./parse-export.sh \
#     -i export.xml \
#     -o downloaded_media \
#     -b igayze.dream-dev.net \
#     -n https://cdn.example.com \
#     -w export-rewritten.xml
#
# Requirements: xmlstarlet, perl, curl, sed, mkdir, dirname, basename, grep, sort, uniq
set -euo pipefail

# --- helper / usage ---
usage() {
  cat <<EOF
Usage: $0 -i INPUT_WXR -o DOWNLOAD_DIR -b OLD_HOST -n NEW_BASE -w OUTPUT_WXR [-K]
  - INPUT_WXR    : input WXR file (e.g. export.xml)
  - DOWNLOAD_DIR : directory to save downloaded media (preserves original path)
  - OLD_HOST     : old host to replace (host only, e.g. igayze.dream-dev.net)
  - NEW_BASE     : new base URL (must include protocol). You may append a path prefix
                   that will be inserted before each original relative path.
                   Examples:
                      https://cdn.example.com
                      https://cdn.example.com/siteA
                      https://cdn.example.com/media/library
  - OUTPUT_WXR   : output rewritten WXR file (a safe backup is created automatically)
  - -K           : keep attachment items in the output XML (disable automatic removal).
                   By default, all attachment items are removed.

Note: Content media rewrite (<img src> URLs in post content) is now always performed
automatically using the attachment mapping.

Example:
  ./parse-export.sh \
    -i export.xml \
    -o downloaded_media \
    -b igayze.dream-dev.net \
    -n https://cdn.example.com \
    -w export-rewritten.xml

  # To keep attachment items in output (disable removal):
  ./parse-export.sh \
    -i export.xml \
    -o downloaded_media \
    -b igayze.dream-dev.net \
    -n https://cdn.example.com \
    -w export-rewritten.xml -K
EOF
  exit 1
}

# parse args
IN=""
OUTDIR=""
OLD_HOST=""
NEW_BASE=""
OUTWXR=""
REMOVE_ATTACHMENTS=1

while getopts "i:o:b:n:w:hK" opt; do
  case "$opt" in
    i) IN="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    b) OLD_HOST="$OPTARG" ;;
    n) NEW_BASE="$OPTARG" ;;
    w) OUTWXR="$OPTARG" ;;
  K) REMOVE_ATTACHMENTS=0 ;;
    *) usage ;;
  esac
done

if [[ -z "$IN" || -z "$OUTDIR" || -z "$OLD_HOST" || -z "$NEW_BASE" || -z "$OUTWXR" ]]; then
  usage
fi

# set defaults if not provided
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="./assets"
fi

# create directories
mkdir -p "$OUTDIR"
mkdir -p "./build/tmp"
mkdir -p "./build/logs"

# normalize
OLD_HOST="${OLD_HOST#http://}"
OLD_HOST="${OLD_HOST#https://}"
OLD_HOST="${OLD_HOST%/}"
if [[ ! "$NEW_BASE" =~ ^https?:// ]]; then
  echo "ERROR: NEW_BASE must include protocol (e.g. https://cdn.example.com or https://cdn.example.com/prefix)" >&2
  exit 2
fi

# normalize NEW_BASE: remove trailing slash and dot; collapse duplicate slashes ONLY in path portion (do not touch protocol separator)
NEW_BASE="${NEW_BASE%/}"
NEW_BASE="${NEW_BASE%.}"
if [[ "$NEW_BASE" =~ ^(https?://[^/]+)(/.*)?$ ]]; then
  _hostpart="${BASH_REMATCH[1]}"
  _pathpart="${BASH_REMATCH[2]}"
  # collapse multiple slashes in path portion
  if [[ -n "$_pathpart" ]]; then
    _pathpart="$(echo "$_pathpart" | sed -E 's#/+#/#g')"
    _pathpart="${_pathpart%/}"
    _pathpart="${_pathpart%.}"
  fi
  NEW_BASE="${_hostpart}${_pathpart}"
fi

# helper to join base + relative ensuring single slash
join_url() {
  local base="$1" rel="$2"
  base="${base%/}"; base="${base%.}"; rel="${rel#/}"
  printf '%s/%s' "$base" "$rel"
}

# check dependencies
for cmd in xmlstarlet perl curl sed mkdir dirname basename grep sort uniq date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: $cmd" >&2
    exit 2
  fi
done

# prepare working files and backups
TS="$(date +%Y%m%d%H%M%S)"
BACKUP="./build/tmp/$(basename "$IN").backup.${TS}"
cp -- "$IN" "$BACKUP"
echo "Backup created: $BACKUP"

WORKING="./build/tmp/$(basename "$IN").working.${TS}.xml"
cp -- "$IN" "$WORKING"

mkdir -p "$OUTDIR"
MAPLOG="./build/logs/download_mapping_${TS}.tsv"
ERRORLOG="./build/logs/download_errors_${TS}.log"
URLS_ALL="./build/logs/urls_to_download_${TS}.txt"
ATT_LIST="./build/logs/attachment_urls_${TS}.txt"

: > "$MAPLOG"
: > "$ERRORLOG"
: > "$URLS_ALL"
: > "$ATT_LIST"

# --- 1) extract <wp:attachment_url> from attachment items ---
echo "1) Extracting <wp:attachment_url> values..."
xmlstarlet sel -N wp="http://wordpress.org/export/1.2/" \
  -t -m "//item[wp:post_type='attachment']" -v "wp:attachment_url" -n "$IN" \
  | sed '/^\s*$/d' > "$ATT_LIST" || true

# --- 1.5) extract thumbnail attachment IDs and add their URLs to download list ---
echo "1.5) Processing thumbnail attachments from _thumbnail_id metadata..."
THUMB_IDS_FILE="./build/logs/thumbnail_ids_${TS}.txt"
THUMB_URLS_FILE="./build/logs/thumbnail_urls_${TS}.txt"
: > "$THUMB_IDS_FILE"
: > "$THUMB_URLS_FILE"

# Extract thumbnail IDs from postmeta
xmlstarlet sel -N wp="http://wordpress.org/export/1.2/" \
  -t -m "//item[wp:post_type!='attachment']/wp:postmeta[wp:meta_key='_thumbnail_id']" \
  -v "wp:meta_value" -n "$IN" \
  | sed '/^\s*$/d' | sort -u > "$THUMB_IDS_FILE" || true

# For each thumbnail ID, find the corresponding attachment URL
while IFS= read -r thumb_id; do
  [[ -z "$thumb_id" ]] && continue
  thumb_url=$(xmlstarlet sel -N wp="http://wordpress.org/export/1.2/" \
    -t -v "//item[wp:post_type='attachment' and wp:post_id='$thumb_id']/wp:attachment_url" "$IN" 2>/dev/null || true)
  if [[ -n "$thumb_url" ]]; then
    echo "$thumb_url" >> "$THUMB_URLS_FILE"
    echo "Found thumbnail: ID=$thumb_id URL=$thumb_url"
  else
    echo "Warning: Thumbnail attachment not found for ID: $thumb_id"
  fi
done < "$THUMB_IDS_FILE"

# Add thumbnail URLs to main attachment list (avoid duplicates)
if [[ -s "$THUMB_URLS_FILE" ]]; then
  cat "$ATT_LIST" "$THUMB_URLS_FILE" | sort -u > "${ATT_LIST}.tmp" && mv "${ATT_LIST}.tmp" "$ATT_LIST"
fi

NUM_THUMB_IDS=$(wc -l < "$THUMB_IDS_FILE" 2>/dev/null || echo 0)
NUM_THUMB_URLS=$(wc -l < "$THUMB_URLS_FILE" 2>/dev/null || echo 0)
echo "Found $NUM_THUMB_IDS thumbnail ID(s), resolved $NUM_THUMB_URLS URL(s)"

# --- 2) extract http(s) URLs inside CDATA blocks (safe: only URLs that include OLD_HOST) ---
echo "2) Extracting URLs from content that contain $OLD_HOST..."
CONTENT_URLS="./build/logs/content_urls_${TS}.txt"
xmlstarlet sel -N wp="http://wordpress.org/export/1.2/" \
  -t -m "//content:encoded" -v "." "$IN" \
  | grep -oE "https?://$OLD_HOST[^\"'<> ]*" \
  | sort -u > "$CONTENT_URLS" || true

# Start download list with ONLY attachment URLs (no other content URLs)
cp "$ATT_LIST" "$URLS_ALL"

# Extract referenced imageIDs from svg-inline blocks (non-attachment items)
echo "2.x) Scanning for referenced svg-inline imageIDs..."
REF_IDS_FILE="./build/logs/referenced_image_ids_${TS}.txt"
: > "$REF_IDS_FILE"
# Extract only from Gutenberg wp:wpbbe/svg-inline blocks using proper namespaces.
# Some earlier runs failed because content namespace was not declared; fix by adding -N content=...
xmlstarlet sel \
  -N wp="http://wordpress.org/export/1.2/" \
  -N content="http://purl.org/rss/1.0/modules/content/" \
  -t -m "//channel/item[wp:post_type!='attachment']/content:encoded" -v "." -n "$IN" \
  | perl -ne '
        while(/<!--\s*wp:wpbbe\/svg-inline\b(.*?)\/-->/g){
          my $blk=$1;
          if($blk =~ /"imageID"\s*:\s*([0-9]+)/){
            print "$1\n";
          }
        }
      ' | sort -u > "$REF_IDS_FILE" || true

# Fallback: if none found, scan entire file (in case XPath failed or blocks outside expected structure)
if [[ ! -s "$REF_IDS_FILE" ]]; then
  echo "No IDs via XPath; fallback scanning whole file..."
  perl -0777 -ne '
     while(/<!--\s*wp:wpbbe\/svg-inline\b(.*?)\/-->/gs){
       my $blk=$1;
       if($blk =~ /"imageID"\s*:\s*([0-9]+)/){
         print "$1\n";
       }
     }
  ' "$IN" | sort -u > "$REF_IDS_FILE" || true
fi

# Merge thumbnail IDs with referenced IDs to ensure all are kept
if [[ -s "$THUMB_IDS_FILE" ]]; then
  cat "$REF_IDS_FILE" "$THUMB_IDS_FILE" | sort -u > "${REF_IDS_FILE}.tmp" && mv "${REF_IDS_FILE}.tmp" "$REF_IDS_FILE"
fi

NUM_REF_IDS=$(wc -l < "$REF_IDS_FILE" 2>/dev/null || echo 0)
echo "Found $NUM_REF_IDS total referenced attachment imageID(s) (including thumbnails)."
# Debug preview
if [[ "$NUM_REF_IDS" -gt 0 ]]; then
  echo "First IDs: $(head -n 10 "$REF_IDS_FILE" | paste -sd, -)"
fi
echo

# --- 2.5) identify WordPress resized images ---
echo "2.5) Identifying valid WordPress resized images (only those whose original is an attachment)..."
RESIZED_URLS="./build/logs/resized_urls_${TS}.txt"
: > "$RESIZED_URLS"
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  filename=$(basename "$url")
  # Match pattern base-WxH.ext
  if [[ "$filename" =~ ^(.+)-([0-9]+)x([0-9]+)\.([a-zA-Z0-9]+)$ ]]; then
    base_name="${BASH_REMATCH[1]}"
    extension="${BASH_REMATCH[4]}"
    original_url="${url%/*}/${base_name}.${extension}"
    # Only accept resized URL if original is an attachment
    if grep -Fxq "$original_url" "$ATT_LIST"; then
      echo "$url" >> "$RESIZED_URLS"
      echo "Valid resized: $filename (original present)"
    else
      echo "Skip resized (original not an attachment): $filename"
    fi
  fi
done < "$CONTENT_URLS"
if [[ -s "$RESIZED_URLS" ]]; then
  cat "$RESIZED_URLS" >> "$URLS_ALL"
  sort -u "$URLS_ALL" > "${URLS_ALL}.tmp" && mv "${URLS_ALL}.tmp" "$URLS_ALL"
fi
NUM_ATTACHMENTS=$(wc -l < "$ATT_LIST" || echo 0)
NUM_RESIZED=$(wc -l < "$RESIZED_URLS" || echo 0)
NUM_URLS=$(wc -l < "$URLS_ALL" || echo 0)
echo "Prepared $NUM_URLS URL(s) to download ($NUM_ATTACHMENTS attachments + $NUM_RESIZED resized). Preview (top 20):"
head -n 20 "$URLS_ALL" || true
echo

# --- 3) download preserving path ---
echo "3) Downloading files to $OUTDIR ..."
while IFS= read -r url; do
  [[ -z "$url" ]] && continue

  # Skip directory-like URLs (those that end with a slash). These are not media files.
  if [[ "$url" == */ ]]; then
    echo "SKIP (directory URL): $url"
    continue
  fi

  # compute relative path after host
  # remove scheme and old host
  rel="${url#*://$OLD_HOST/}"
  if [[ "$rel" == "$url" ]]; then
    # fallback remove first host+scheme
    rel="$(echo "$url" | sed -E 's|https?://[^/]+/||')"
  fi
  if [[ -z "$rel" || "$rel" == "$url" ]]; then
    # last-resort fallback
    rel="_unknown_path/$(basename "$url")"
  fi

  dest="$OUTDIR/$rel"
  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    echo "SKIP (exists): $dest"
    echo -e "$url\t$(join_url "$NEW_BASE" "$rel")\t$dest" >> "$MAPLOG"
    continue
  fi

  echo -n "Downloading: $url -> $dest ... "
  if curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
    echo "OK"
  echo -e "$url\t$(join_url "$NEW_BASE" "$rel")\t$dest" >> "$MAPLOG"
  else
    echo "FAILED"
    echo "$url" >> "$ERRORLOG"
  fi
done < "$URLS_ALL"

if [[ -s "$ERRORLOG" ]]; then
  echo
  echo "Some downloads failed; see $ERRORLOG"
else
  echo "Downloads finished without errors."
fi
echo

# --- 4) rewrite <wp:attachment_url> nodes only (exact node text) ---
echo "4) Rewriting <wp:attachment_url> nodes to point to $NEW_BASE ..."
# We'll create a temp file for iterative updates
TMP_WORK="./build/tmp/$(basename "$WORKING").tmp"
cp -- "$WORKING" "$TMP_WORK"

# Replace each exact <wp:attachment_url>content</wp:attachment_url> where content contains old host
# Use perl to perform safe targeted tag content replacement (preserves spacing/newlines)
if [[ -s "$ATT_LIST" ]]; then
  while IFS= read -r oldurl; do
    [[ -z "$oldurl" ]] && continue
    rel="${oldurl#*://$OLD_HOST/}"
    if [[ "$rel" == "$oldurl" ]]; then
      rel="$(echo "$oldurl" | sed -E 's|https?://[^/]+/||')"
    fi
    if [[ -z "$rel" || "$rel" == "$oldurl" ]]; then
      rel="_unknown_path/$(basename "$oldurl")"
    fi
    newurl="$(join_url "$NEW_BASE" "$rel")"
    # Updated: support optional CDATA wrapper
    perl -0777 -pe "s{(<wp:attachment_url>\s*(?:<!\[CDATA\[)?)\Q$oldurl\E((?:\]\]>)?\s*</wp:attachment_url>)}{\$1$newurl\$2}g" "$TMP_WORK" > "${TMP_WORK}.new" && mv "${TMP_WORK}.new" "$TMP_WORK"
    # Optional: warn if not replaced (URL still present inside same tag)
    if grep -q "<wp:attachment_url><!\[CDATA\[$oldurl\]\]></wp:attachment_url>" "$TMP_WORK"; then
      echo "WARNING: attachment_url not rewritten (CDATA form) for: $oldurl" >&2
    fi
    echo "rewrote: $oldurl -> $newurl"
  done < "$ATT_LIST"
else
  echo "No <wp:attachment_url> nodes to rewrite."
fi

# After attachment_url rewrite, update <guid> for referenced attachment items
if [[ -s "$REF_IDS_FILE" ]]; then
  echo "Updating <guid> of referenced attachment items (including thumbnails) to NEW_BASE..."
  while IFS= read -r aid; do
    [[ -z "$aid" ]] && continue
    guid_val="$(xmlstarlet sel -N wp="http://wordpress.org/export/1.2/" \
      -t -v "//item[wp:post_type='attachment' and wp:post_id='$aid']/guid" "$TMP_WORK" 2>/dev/null || true)"
    [[ -z "$guid_val" ]] && continue
    if [[ "$guid_val" == https://$OLD_HOST* || "$guid_val" == http://$OLD_HOST* ]]; then
      rel="${guid_val#*://$OLD_HOST/}"
      if [[ "$rel" == "$guid_val" || -z "$rel" ]]; then
        rel="$(echo "$guid_val" | sed -E 's|https?://[^/]+/||')"
      fi
      [[ -z "$rel" || "$rel" == "$guid_val" ]] && rel="_unknown_path/$(basename "$guid_val")"
      new_guid="$(join_url "$NEW_BASE" "$rel")"
      if [[ "$new_guid" != "$guid_val" ]]; then
        xmlstarlet ed -N wp="http://wordpress.org/export/1.2/" \
          -u "//item[wp:post_type='attachment' and wp:post_id='$aid']/guid" \
          -v "$new_guid" "$TMP_WORK" > "${TMP_WORK}.new" && mv "${TMP_WORK}.new" "$TMP_WORK"
        echo "guid updated (post_id=$aid): $guid_val -> $new_guid"
      fi
    fi
  done < "$REF_IDS_FILE"
  echo
fi

# --- 5) rewrite URLs inside CDATA blocks only (preserve CDATA wrapper) ---
echo "Skipping CDATA URL rewrite (attachments-only mode)."

# --- 6) finalise: save output and create backup of working copy ---
mv "$TMP_WORK" "$OUTWXR"
echo "Rewritten WXR written to: $OUTWXR"
WORKING_BAK="./build/tmp/$(basename "$WORKING").backup.${TS}"
cp -- "$WORKING" "$WORKING_BAK"
echo "Working-copy backup: $WORKING_BAK"

# --- 7) summary & sanity checks ---
echo
echo "=== Summary ==="
echo "Original WXR backup: $BACKUP"
echo "Rewritten WXR   : $OUTWXR"
echo "Downloaded attachments: $OUTDIR"
echo "Temporary files  : ./build/tmp/"
echo "Logs             : ./build/logs/"
echo "Mapping log      : $MAPLOG"
echo "Download errors  : $ERRORLOG (if non-empty)"
echo "Resized images   : $NUM_RESIZED (only those with original attachment)"
echo "Thumbnail attachments: $NUM_THUMB_URLS (from _thumbnail_id metadata)"
echo "Referenced imageIDs: $NUM_REF_IDS (these attachment items will be kept)"

# check for remaining occurrences of OLD_HOST in output (quick sanity)
REMAINING="$(grep -oE "https?://$OLD_HOST[^\"'<> ]*" "$OUTWXR" | wc -l || true)"
if [[ "$REMAINING" -eq 0 ]]; then
  echo "Sanity check: no remaining occurrences of $OLD_HOST found in $OUTWXR."
else
  echo "WARNING: found $REMAINING remaining occurrence(s) of $OLD_HOST in $OUTWXR. Inspect manually:"
  grep -nE "https?://$OLD_HOST[^\"'<> ]*" "$OUTWXR" | sed -n '1,40p'
fi


# --- 8) content media rewrite: apply mapping to <img src> URLs in <content:encoded> ---
echo "Content media rewrite: applying mapping to <img src> URLs in post content..."
TMP_CONTENT="./build/tmp/$(basename "$OUTWXR").content.tmp"
cp -- "$OUTWXR" "$TMP_CONTENT"
# Build a perl script to replace old URLs with new in <content:encoded> CDATA
PERL_SCRIPT="./build/tmp/replace_$$.pl"
cat > "$PERL_SCRIPT" << 'EOF'
use strict;
use warnings;
my %map;
EOF
# Add mappings to the perl script
while IFS=$'\t' read -r old new local; do
  [[ -z "$old" || -z "$new" ]] && continue
  # Remove newlines from old and new
  old=$(printf '%s' "$old" | tr -d '\n')
  new=$(printf '%s' "$new" | tr -d '\n')
  oesc=$(printf '%s' "$old" | sed 's|[\\"]|\\\\&|g')
  nesc=$(printf '%s' "$new" | sed 's|[\\"]|\\\\&|g')
  echo "\$map{qq{$oesc}} = qq{$nesc};" >> "$PERL_SCRIPT"
done < "$MAPLOG"
cat >> "$PERL_SCRIPT" << 'EOF'
local $/;
my $content = <>;
$content =~ s{<content:encoded><!\[CDATA\[(.*?)\]\]></content:encoded>}{
  my $inner = $1;
  foreach my $old (keys %map) {
    $inner =~ s/\Q$old\E/$map{$old}/g;
  }
  "<content:encoded><![CDATA[$inner]]></content:encoded>"
}gse;
print $content;
EOF
echo "Running perl script: $PERL_SCRIPT"
perl "$PERL_SCRIPT" "$TMP_CONTENT" > "${TMP_CONTENT}.new" && mv "${TMP_CONTENT}.new" "$TMP_CONTENT"
mv "$TMP_CONTENT" "$OUTWXR"
rm -f "$PERL_SCRIPT"

# --- 9) remove attachment items (default behavior) ---
if [[ $REMOVE_ATTACHMENTS -eq 1 ]]; then
  echo "Removing attachment items (except those referenced by svg-inline imageID)..."
  CLEANED_TMP="./build/tmp/$(basename "$OUTWXR").no_attachments.tmp"
  if [[ -s "$REF_IDS_FILE" ]]; then
    # Build OR condition for referenced IDs
    OR_EXPR="$(awk 'NF{printf "wp:post_id=%c%s%c or ",39,$1,39}' "$REF_IDS_FILE")"
    OR_EXPR="${OR_EXPR% or }"
    if [[ -n "$OR_EXPR" ]]; then
      xmlstarlet ed -N wp="http://wordpress.org/export/1.2/" \
        -d "//item[wp:post_type='attachment' and not($OR_EXPR)]" \
        "$OUTWXR" > "$CLEANED_TMP" && mv "$CLEANED_TMP" "$OUTWXR"
      KEPT_ATTACH_REF="$NUM_REF_IDS"
    else
      xmlstarlet ed -N wp="http://wordpress.org/export/1.2/" \
        -d "//item[wp:post_type='attachment']" \
        "$OUTWXR" > "$CLEANED_TMP" && mv "$CLEANED_TMP" "$OUTWXR"
      KEPT_ATTACH_REF=0
    fi
  else
    xmlstarlet ed -N wp="http://wordpress.org/export/1.2/" \
      -d "//item[wp:post_type='attachment']" \
      "$OUTWXR" > "$CLEANED_TMP" && mv "$CLEANED_TMP" "$OUTWXR"
    KEPT_ATTACH_REF=0
  fi
  echo "Kept referenced attachment items: $KEPT_ATTACH_REF"
fi

# --- 10) normalize kept attachment item URLs (host + path rewrite) ---
REMAIN_ATTACH_COUNT=$(xmlstarlet sel -N wp="http://wordpress.org/export/1.2/" -t -v "count(//item[wp:post_type='attachment'])" "$OUTWXR")
if [[ "$REMAIN_ATTACH_COUNT" -gt 0 ]]; then
  echo "Normalizing URLs inside $REMAIN_ATTACH_COUNT kept attachment item(s)..."
  perl -0777 -e '
    use strict; use warnings;
    my ($mapfile,$old_host,$new_base,$xmlfile)=@ARGV;
    my %map;
    if (-s $mapfile){
      open my $m,"<",$mapfile or die $!;
      while(<$m>){
        chomp;
        my ($old,$new)=split(/\t/);
        next unless $old && $new;
        $map{$old}=$new;
      }
      close $m;
    }
    local $/;
    open my $fh,"<",$xmlfile or die $!;
    my $xml=<$fh>; close $fh;

    $xml =~ s{(<item>.*?<wp:post_type>attachment</wp:post_type>.*?</item>)}{
      my $block=$1;
      # Apply explicit old->new mapping (downloaded originals + validated resized)
      for my $o (keys %map){
        my $n=$map{$o};
        $block =~ s/\Q$o\E/$n/g;
      }
      # Generic fallback: any remaining URL still pointing to old host
      $block =~ s{https?://\Q$old_host\E/([^"<>\s]+)}{
        my $rel=$1;
        $rel =~ s{//+}{/}g;
        "$new_base/$rel"
      }ge;
      $block;
    }gse;

    open my $out,">",$xmlfile or die $!;
    print $out $xml;
    close $out;
  ' "$MAPLOG" "$OLD_HOST" "$NEW_BASE" "$OUTWXR"
  echo "Kept attachment items normalized."
fi

echo
echo "Done. Tip: upload the contents of $OUTDIR to your CDN/storage preserving paths, then import $OUTWXR (or use it to generate a Blueprint)."
