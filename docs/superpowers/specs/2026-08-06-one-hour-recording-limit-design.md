# One-hour recording limit

## Goal

Allow one microphone recording to run for up to one hour instead of stopping
after five minutes.

## Design

Keep the recorder's existing fixed safety limit and change it from 300 seconds
to 3,600 seconds. The existing recording flow remains unchanged: the user may
stop at any time, and reaching the limit automatically stops, saves the WAV to
the outbox, closes the microphone, and tells the user that the time limit was
reached.

The limit stays as a single `RecorderService.MAX_SECONDS` constant. The pet's
completion message already derives its displayed minute count from that
constant, so it will say 60 minutes without duplicating the value. No settings
screen or unlimited mode is added.

## Storage trade-off

The recorder writes uncompressed 44.1 kHz, stereo, 16-bit WAV data. A full
one-hour recording can therefore use roughly 600 MB. The one-hour hard stop is
retained to prevent an accidentally forgotten recording from growing without
bound.

## Verification

- Add a regression check that expects the recording cap to be 3,600 seconds.
- Run the recorder-focused test and the existing headless test suite.
- Start the application and confirm the running process uses the updated build.

## Non-goals

- Making the duration configurable.
- Compressing or transcoding recordings.
- Changing recording controls, indicators, filenames, or save location.
