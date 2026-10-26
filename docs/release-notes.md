<p align="center">
  <img src="https://raw.githubusercontent.com/LoginPro/faircopy-mac/main/Branding/logo.png" width="360" alt="FairCopy">
</p>

**A private, offline AI editor for any text field on your Mac.** Select text, press <kbd>⌃⌥R</kbd>, get a clean copy — typos and punctuation fixed, your casual tone, slang and emoji untouched. Runs entirely on your Mac through LM Studio.

<p align="center">
  <img src="https://raw.githubusercontent.com/LoginPro/faircopy-mac/main/docs/editor.png" width="460" alt="FairCopy editor">
</p>

### 🛠 What's new in 1.0.1

- **Fixed empty results with reasoning models.** Some models (e.g. Gemma 4 26B-A4B) ignored the "don't think" switch and spent the whole answer on hidden reasoning, so the editor came back empty. FairCopy now also sends `reasoning_effort: none` — with Gemma 4 26B-A4B a fix takes ~2 s instead of ~15 s.
- If a model still answers with reasoning only, FairCopy shows a clear error instead of an empty window.

### ✨ What's inside

- **Fix** — spelling, punctuation, run-on sentences. Never makes your text formal.
- **Restyle** — Short, Friendly, Formal, No Fillers, Corporate, Viking and more, or describe your own.
- **Translate** into 10 languages, optionally with a style on top.
- **Edits you can read** — hover any highlighted edit to see the rule.
- **My Voice** — a style built from your own Telegram messages that writes like *you*.
- **Per-app memory**, **personal dictionary**, **style editor**, **model warm-up / unload** from the menu bar.
- Liquid Glass UI in English and Russian.

### 📦 Install

1. Download the **.dmg** below, open it and drag **FairCopy** to **Applications**.
2. **First launch.** FairCopy isn't notarized by Apple, so macOS will block it once. Open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. **Accessibility.** Enable FairCopy in **System Settings → Privacy & Security → Accessibility** — it reads the selected text and pastes the result back.
4. **Model.** Install [LM Studio](https://lmstudio.ai) and download a model — Gemma 4 12B is the default:
   ```bash
   ~/.lmstudio/bin/lms get https://huggingface.co/mlx-community/gemma-4-12B-it-qat-OptiQ-4bit
   ```
   FairCopy starts the LM Studio server by itself. If your server requires a token, add it in the FairCopy menu → *LM Studio Token…*

### 💻 Requirements

macOS 26 or later · Apple Silicon · ~9 GB free memory for the model (16 GB RAM or more recommended)

<p align="center">
  <img src="https://raw.githubusercontent.com/LoginPro/faircopy-mac/main/docs/install.png" width="460" alt="Installer window">
</p>
