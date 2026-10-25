# Shared prompts and styles

These files are the single source of truth for every prompt FairCopy sends to the model and for the built-in styles. The macOS app bundles them as resources; a Windows (or any other) port should read the same files instead of copying the text into its code.

| File | Contents |
|---|---|
| `prompts.json` | System prompts, few-shot examples and small text templates |
| `styles.json` | Built-in styles (No Fillers, Formal, Short, …) |

Both files have a `format` number (currently `1`) and a `locales` object keyed by interface language (`ru`, `en`). Pick the locale matching the UI language and fall back to `en`.

## Text values

- A **string** is used as is.
- An **array of strings** is one multi-line text: join the items with `\n`. Long prompts are stored this way so they're readable and diff nicely in git.

## Placeholders

Templates contain `{name}` placeholders. Substitute them in **one pass**: text inserted for a placeholder must not be scanned again (user text may contain braces). Unknown placeholders are left untouched.

| Where | Placeholders |
|---|---|
| `input` (top level) | `{text}` — wraps every user message: `<text>{text}</text>` |
| `style.system` | `{instruction}` — the style's `prompt` |
| `style.custom` | `{description}` — what the user typed into "Custom style"; `customEmpty` when they typed nothing |
| `dictionary.note` | `{words}` — dictionary words, each formatted with `dictionary.word` (`{word}`) and joined with `dictionary.separator` |
| `translate.system` | `{language}`, `{tone}` — `{tone}` is `keepTone`, or `styledTone` with `{instruction}` when a style is applied on top |
| `explain.user` | `{original}`, `{result}`, `{edits}` — `{edits}` is lines of `explain.edit` (`{n}`, `{from}`, `{to}`), joined with `\n`; an empty side becomes `explain.empty` |
| `voice.stats` | `{count}`, `{capitalRule}`, `{capitalStart}`, `{periodRule}`, `{periodEnd}`, `{bracket}`, `{doubleBracket}`, `{emoji}`, `{ellipsis}`, `{medianWords}` |

`voice.capitalRule` / `voice.periodRule` pick a phrase by share of messages: ≥ 70% → `often`, ≥ 25% → `sometimes`, otherwise `rarely`.

## Building the chat

- **Fix:** `system = fix.system (+ dictionary)`, then each `fix.examples` item as a `user` (wrapped in `input`) / `assistant` pair, then the user's text wrapped in `input`.
- **Style:** same, with `style.system` and the style's own `examples`.
- **Translate:** `translate.system (+ dictionary)` and the wrapped text, no examples.
- **Dictionary** (if the user has any words): append `"\n\n" + dictionary.note` to the system prompt.
- **Explain edits:** `explain.system` + `explain.user`; the model answers with a JSON array of strings.
- **My Voice:** `voice.analysis` with messages joined by `\n`; `voice.neutralize` with a wrapped message; the final style prompt is `description + "\n\n" + stats + "\n\n" + voice.moderation`.

## Checking a port

`FairCopy.app/Contents/MacOS/AIEditor --dump-prompts` prints every assembled prompt for fixed inputs (set `FAIRCOPY_LANG=ru` or `en`). A port that produces byte-identical output for the same inputs builds prompts exactly like the Mac app. The fixed inputs are in `Sources/DumpPrompts.swift`.
