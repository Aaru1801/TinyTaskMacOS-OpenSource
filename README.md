# MiniTinyTask (macOS)

A lightweight **macro recorder and player** inspired by TinyTask, rebuilt in **Python + Tkinter** with a modern UI for macOS.  
You can record your mouse and keyboard actions, save them as macros, replay them, and manage favorites. Made with the help of ChatGPT

---

## ✨ Features

- 🎥 **Record & Play** mouse + keyboard macros  
- 💾 **Save / Load** macros as JSON  
- ⭐ **Favorites** manager (store, replay, delete macros quickly)  
- ⚙️ **Settings** to configure keyboard shortcuts  
- 🎨 **Modern card-style UI** with ttk themes and custom colors  
- ⌨️ **Unregistered global shortcuts** (safe defaults, low collision risk):  
  - Record       → `F3` (Fn+F3 on mac) (same to stop recording)  
  - Play         → `F7` (Fn+F7 on mac)  
  - Save         → `F4` (Fn+F4 on mac)  
  - Open Saved   → `F6` (Fn+F6 on mac)  

---

## 📥 Download (Recommended for Users)

Grab the latest version from [Releases](https://github.com/Aaru1801/TinyTaskMacOS-OpenSource/releases/latest).

### macOS Installation
1. Download the **TinyTask-MacOS.dmg** from the Assets.  
2. Open the DMG and drag **TinyTask-MacOS.app** into your **Applications** folder.  
3. On first launch, right-click → **Open** (to bypass Gatekeeper warning).  
4. Grant **Accessibility** & **Input Monitoring** when prompted.  

✅ That’s it! You’re ready to record and play macros.

---

## 📦 Development Setup (For Contributors)

1. **Clone the repo**
   ```bash
   git clone https://github.com/yourusername/minitinytask.git
   cd minitinytask
   ```

2. **Install dependencies**  
   Requires Python 3.9+.
   ```bash
   pip install pynput
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

## 📦 Packaging (For Developers)

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
