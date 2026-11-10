# languagetool-check: checks the selected text with the local LanguageTool
# server and lists the problems it finds in a window. Nothing is changed.
#
#   languagetool-check     select text, press the hotkey (Super+Alt+C)
#
# German is checked as Swiss German (de-CH: "ss", never "ß"), English as
# British English. Change `variants` below for others (e.g. en-US).

server="http://localhost:8081/v2"
variants="de-CH,en-GB"
# Rule categories to skip: Oxford spelling hints ("realize" for "realise").
disabled_categories="BRE_STYLE_OXFORD_SPELLING"

# Selected text (primary selection), or the clipboard if nothing is selected.
text="$(wl-paste --primary --no-newline 2>/dev/null || true)"
[ -z "${text//[[:space:]]/}" ] && text="$(wl-paste --no-newline 2>/dev/null || true)"
if [ -z "${text//[[:space:]]/}" ]; then
  notify-send -a LanguageTool "LanguageTool" "No text selected"
  exit 0
fi

nid="$(notify-send -a LanguageTool -p -t 0 "LanguageTool" "Checking ...")"

if ! response="$(curl -sS --fail --max-time 60 "$server/check" \
  --data-urlencode "text=$text" \
  --data-urlencode "language=auto" \
  --data-urlencode "preferredVariants=$variants" \
  --data-urlencode "disabledCategories=$disabled_categories")"; then
  notify-send -a LanguageTool -r "$nid" -u critical "LanguageTool" \
    "Server not reachable (systemctl status languagetool)"
  exit 1
fi

language="$(jq -r '.language.name' <<<"$response")"
count="$(jq '.matches | length' <<<"$response")"

if [ "$count" -eq 0 ]; then
  notify-send -a LanguageTool -r "$nid" -t 3000 "LanguageTool" "No problems found ($language)"
  exit 0
fi

# One block per problem: the context with the problem marked »like this«, the
# explanation, and up to five suggestions.
report="$(jq -r '
  .matches | to_entries[] |
  .key as $i | .value as $m | $m.context as $c |
  ($c.text[0:$c.offset] + "»" + $c.text[$c.offset:$c.offset + $c.length] + "«"
    + $c.text[$c.offset + $c.length:]) as $ctx |
  ([$m.replacements[0:5][].value | "\"" + . + "\""] | join("  ")) as $sugg |
  "\($i + 1). \($ctx | gsub("\n"; " "))\n"
  + "   \($m.message)\n"
  + (if $sugg == "" then "" else "   → \($sugg)\n" end)
  + "   [\($m.rule.category.name)]\n"
' <<<"$response")"

notify-send -a LanguageTool -r "$nid" -t 1 "LanguageTool" "$count problem(s) found"

if [ "$count" -eq 1 ]; then
  title="LanguageTool: 1 problem ($language)"
else
  title="LanguageTool: $count problems ($language)"
fi

# Mango floats this window (window_rule on the title in mango/settings.conf).
printf '%s\n' "$report" |
  zenity --text-info --title="$title" --width=720 --height=480 \
    --ok-label=Close --cancel-label=Close >/dev/null 2>&1 || true
