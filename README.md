
# MPV-SyncBangumi

A Lua script for [MPV Player](https://mpv.io/) that automatically syncs your local anime viewing progress to your [Bangumi](https://bgm.tv) account.

[**中文文档 (Chinese Documentation)**](README_zh-CN.md)

## ✨ Features

- **Automatic Matching**: Intelligently searches and matches anime series and episodes on Bangumi based on your local video filenames.
- **Automatic Status Updates**:
    - When you start playing an episode, the script automatically updates the series status to "Watching" (`在看`) if it was previously "Wish" (`想看`) or "Uncollected" (`未收藏`).
    - When playback progress exceeds 80%, the current episode is automatically marked as "Watched" (`看过`).
- **Automatic Completion**: Once all main episodes of a series are marked as "Watched", the script will automatically update the entire series' status to "Completed" (`看过`).
- **On-Screen Display (OSD)**: Provides real-time feedback on the current sync status, matched anime information, and operation results.
- **Flexible Control**: Easily toggle the sync functionality on or off for the current video with a hotkey.
- **Debug Mode**: A built-in debug mode to log detailed API request/response information for troubleshooting or development.

## 🚀 Installation & Configuration

### 1. Installation

Clone this repository into your MPV `scripts` directory.

```bash
git clone https://github.com/witcheng1024/synbangumi.git
```

This will create a `synbangumi` folder inside your `scripts` directory containing `synbangumi.lua` and other necessary files.

*(Note: Ensure you have `json.lua` available in a subdirectory like `scripts/bin` if it's not included in the repository.)*

### 2. Get Your Access Token

1.  Visit your [Bangumi API Applications](https://bgm.tv/dev/app) page.
2.  Create a new application if you don't have one already.
3.  Copy your personal `Access Token`.

### 3. Create the Configuration File

1.  In your MPV `script-opts` directory, create a new file named `synbangumi.conf`.
2.  Add the following content to the file, and fill in your `Access Token` and Bangumi username:

    ```ini
    # Your Bangumi Access Token (Required)
    access_token=PASTE_YOUR_ACCESS_TOKEN_HERE

    # Your Bangumi Username (Optional, but recommended)
    username=your_bangumi_username

    # Enable debug mode (Optional, true or false, defaults to false)
    # This will print detailed API logs to the console.
    debug_mode=false
    ```

## ⌨️ Usage

- **Start Playback**: Simply open your anime video file in MPV. The script will automatically start working when the file loads.
- **Hotkey `Ctrl+g`**:
    - **Press once**: Enables the sync functionality for the currently playing video. The script will match the anime and update your status.
    - **Press again**: Manually disables the sync functionality for the current session.
- **Automatic Sync**: Once enabled, the script handles all progress updates in the background. Sit back and enjoy your show!

## 📝 ToDo / Future Features

- **Manual Matching**: Implement a feature to manually input the anime title (subject) and episode number when filename parsing fails or is incorrect.

## ⚠️ Notes

- **Filename Conventions**: For the best matching accuracy, use reasonably standard filenames that include the anime title and episode number. Examples:
    - `[SubsPlease] Boku no Hero Academia - 01 (1080p) [F02B9616].mkv`
    - `Mahou Shoujo ni Akogarete_S1E12.mkv`
    - `【Nekomoe kissaten】★2023-04★[Skip and Loafer][01][1080p][CHT&JPN].mp4`
- **Internet Connection**: The script requires a working internet connection to access the Bangumi API.
- **First-Time Use**: It is recommended to run MPV from a terminal or console for the first time to ensure the script initializes correctly and the API test is successful.

---
Enjoy your synced anime life!
