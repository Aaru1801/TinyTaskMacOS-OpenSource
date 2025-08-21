# MiniTinyTask (macOS)

A lightweight **macro recorder and player** inspired by TinyTask, rebuilt in **Python + Tkinter** with a modern UI for macOS.  
You can record your mouse and keyboard actions, save them as macros, replay them, and manage favorites.

---

## ✨ Features

- 🎥 **Record & Play** mouse + keyboard macros  
- 💾 **Save / Load** macros as JSON  
- ⭐ **Favorites** manager (store, replay, delete macros quickly)  
- ⚙️ **Settings** to configure keyboard shortcuts  
- 🎨 **Modern card-style UI** with ttk themes and custom colors  
- ⌨️ **Unregistered global shortcuts** (safe defaults, low collision risk):  
  - Record → `⌥⇧R` (Option+Shift+R)  
  - Play   → `⌥⇧P` (Option+Shift+P)  
  - Save   → `⌥⇧S`  
  - Open   → `⌥⇧O`  

---

## 📦 Installation

1. **Clone the repo**
   ```bash
   git clone https://github.com/yourusername/minitinytask.git
   cd minitinytask
   ```

2. **Install dependencies**  
   Requires Python 3.9+.
   ```bash
   pip install -r requirements.txt
   ```

   > Note: `tkinter` comes preinstalled with Python on macOS.

3. **Run the app**
   ```bash
   python main.py
   ```

---

## 🔑 Accessibility Permissions

On macOS, recording mouse and keyboard events requires:

1. **System Settings → Privacy & Security → Accessibility**  
   Add your terminal or the app’s built `.app` here.  
2. **System Settings → Privacy & Security → Input Monitoring**  
   Enable for the same app/terminal.  

Without these, recording will not work.

---

## 📁 Storage

All user data is stored under:

```
~/.minitinytask/
├── config.json      # stores user shortcut preferences
└── favorites.json   # stores saved macros
```

---

## 🖥️ Usage

### Main Window

- **Start Recording** → records a macro until stopped  
- **Stop Recording** → ends recording  
- **Play Macro** → replays events with current speed/loops  
- **Add to Favorites** → save the current macro  
- **My Favorites** → open and manage saved macros  
- **Settings (⚙️)** → edit shortcuts  

---

## 📦 Packaging

You can package the app into a `.app` with **PyInstaller**:

```bash
pip install pyinstaller
pyinstaller --onefile --windowed main.py
```

This will generate a standalone macOS app under `dist/`.

---

## 📜 License

Licensed under the **GPL-3.0-or-later**.  
See [LICENSE](LICENSE) for details.
