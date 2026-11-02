# BlinkReminder Manual QA Checklist

Verify each item on a real Mac before shipping a release build.

## Overlay
- [ ] Menu > Trigger Break Now shows the overlay on all connected screens,
      even when paused/idle (manual triggers bypass the paused/idle guards).
- [ ] Waiting for the full interval fires the overlay automatically.
- [ ] Heads-up notification > Start now shows the overlay.
- [ ] Countdown runs 20 → 0 (or configured duration) then auto-dismisses.
- [ ] After auto-dismiss, keyboard focus returns to the previously active app.
- [ ] Skip button dismisses the overlay and records a skip.
- [ ] Snooze +5m dismisses and the next break fires ~5 minutes later.
- [ ] Strict Mode hides Skip/Snooze buttons ("Strict Mode On" shown).
- [ ] Max Skips reached shows "Skip Limit Reached" and hides buttons.
- [ ] Overlay appears above a fullscreen app.

## Menu / scheduling
- [ ] Menu bar shows the eye icon only; countdown appears in the opened menu.
- [ ] Menu shows "Next break in MM:SS" snapshot when opened.
- [ ] Menu shows "Paused" / "Paused (Xm left)" / "Paused (Video Call)" / "Idle" correctly.
- [ ] Pause / Resume toggles the schedule.
- [ ] Pause For > 15m / 30m / 1h pauses and auto-resumes after the duration.
- [ ] Changing Interval restarts the countdown.
- [ ] Changing Break Duration applies to the next overlay.

## Sensors
- [ ] Camera on pauses the timer ("Paused (Video Call)"); camera off resumes.
- [ ] Idle past the threshold resets the timer (no overlay on an empty desk).
- [ ] Sleep suspends, wake resumes the schedule.

## Notifications
- [ ] 30s heads-up appears for intervals longer than 35s.
- [ ] Heads-up +1m / +5m actions defer the break.
- [ ] Notification permission denied still shows the overlay fallback at fire time.

## Battery
- [ ] No 1s background timer: only the 2s camera check and 5s idle check run
      while idle (verify with Activity Monitor / `log stream`).

## UI self-test
- [ ] `./BlinkReminder.app/Contents/MacOS/BlinkReminder --test-overlay`
      prints `UI-TEST PASS` on a GUI Mac (`SKIP` when headless).
