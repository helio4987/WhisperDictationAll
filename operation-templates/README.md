# Custom Operation Templates

This file (`templates.json`) is fetched directly by the app from GitHub —
pushing a commit to `main` here makes a new template available to every
install the next time they tap "Refresh" in Settings → Custom Operations.
No app update or release is needed.

## Why this exists

Custom Operations (hotkey → local LLM → replace selection) are entirely
user-defined — there's no built-in "Improve Text" mode. Templates are a
distributable starting point for an operation's prompt framing (prepend/
append text), so a useful idea can be shared without a code change. A
template is **not** a full operation: it never includes a hotkey or a
model, since those depend on what the installing user has downloaded and
which keys are free on their machine. Adding a template to the app via
"Use Template" always leaves the hotkey and model unassigned.

## Schema

```json
{
  "schemaVersion": 1,
  "templates": [
    {
      "id": "fix-grammar",
      "name": "Fix Grammar",
      "description": "Corrects grammar and spelling without changing tone or meaning.",
      "prependEnabled": true,
      "prependText": "Fix the grammar and spelling in the following text. Keep the tone and meaning unchanged. Respond with only the corrected text.",
      "appendEnabled": false,
      "appendText": "",
      "recommendedModelHint": "Works well with any Q4_K_M instruct model, even 1-3B."
    }
  ]
}
```

Field notes:

- `id` — stable, unique, kebab-case. Never reuse an id for a different
  template; if a template's prompt changes, keep the same `id` so an app
  that already fetched the old version replaces it cleanly on next refresh.
- `name` — short, shown as the template's title in Settings.
- `description` — one sentence explaining what the operation does.
- `prependEnabled`/`prependText` — text placed before the selection in the
  prompt sent to the model. Leave `prependEnabled: false` and
  `prependText: ""` if unused.
- `appendEnabled`/`appendText` — same shape, placed after the selection.
- `recommendedModelHint` — optional, freeform. Shown as a hint string in
  the UI; never used to auto-select a model.

`schemaVersion` is a top-level field (not per-template). The app skips
the whole fetch if it doesn't recognize the version, rather than
mis-rendering templates it can't understand — bump it only if you make a
breaking change to the template shape above (adding a new optional field
is not breaking and doesn't need a bump).

## Adding a template

1. Add an entry to the `templates` array with a unique `id`.
2. Keep `prependText`/`appendText` as a complete, self-contained
   instruction — the model only sees this text plus the user's selection,
   with no other context.
3. Open a PR or push directly if you're the only maintainer.

Templates are fetched over HTTPS and only ever populate local prompt
text fields — nothing here is executed as code.
