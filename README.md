# BlinkReminder 👀

A minimal, native macOS menu bar application designed to reduce digital eye strain. It gently reminds you to blink and look away from your screen every 20 minutes (following the 20-20-20 rule).

## Features

- **Menu Bar Workflow:** Runs unobtrusively in your menu bar.
- **Smart Overlay:** A full-screen, dimming overlay guides you through a 20-second break.
- **Idle-aware scheduling (v1.1.0):** Uses `CGEventSource` to measure keyboard/mouse idle time. If you've been away longer than the Idle Threshold (default 60s, configurable), the break is skipped and the timer resets — your eyes already rested. Toggle via **Reset Timer When Idle**. No overlay ever pops onto an empty desk.
- **Focus restore (v1.1.0):** Captures the previously active app before a break and returns focus to it after Skip or countdown ends (like Time Out / Stretchly). Overlay now uses screen-saver window level so it stays above fullscreen apps.
- **Pause/Resume:** Easily pause reminders during meetings or movies.
- **Customizable Intervals:** Choose from 20, 10, or 5-minute intervals.
- **Notification Mode:** Fallback to system notifications if you prefer not to use the overlay.

## Installation

### Option 1: Homebrew (Easiest)

You can install BlinkReminder directly from this repository:

```bash
brew tap ntn0de/blink-reminder https://github.com/ntn0de/blink-reminder
brew install --cask blink-reminder
```

### Updating

To update BlinkReminder to the latest version via Homebrew:

```bash
brew update
brew upgrade --cask blink-reminder
```

### Option 2: Build from Source

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/ntn0de/blink-reminder.git
    cd blink-reminder
    ```

2.  **Build the app:**
    ```bash
    ./build.sh
    ```

3.  **Install:**
    Move the app to your Applications folder (critical for notifications to work):
    ```bash
    mv BlinkReminder.app /Applications/
    ```

4.  **Run:**
    Open `BlinkReminder` from your Applications folder.

## Usage

1.  **Start the App:** You will see a small "eye" icon (👀) in your menu bar.
2.  **Take a Break:** When the timer hits, a screen overlay will appear. Follow the breathing exercise and look away for 20 seconds.
3.  **Pause:** Click the menu bar icon and select **Pause** to temporarily stop the timer.
4.  **Settings:**
    - **Interval:** Change the frequency of breaks (default is 20 minutes).
    - **Use Screen Overlay:** Uncheck this to receive standard macOS notifications instead of the full-screen overlay.

## Troubleshooting

-   **"App is damaged" or can't open:**
    Because this is a self-signed app, macOS might flag it. You can fix this by running:
    ```bash
    xattr -cr /Applications/BlinkReminder.app
    ```
    Alternatively, right-click and select **Open** the first time, or go to **System Settings > Privacy & Security** to allow it.
-   **No Notifications:**
    Ensure the app is in the `/Applications` folder and that "BlinkReminder" is allowed in **System Settings > Notifications**.

## License

MIT License
