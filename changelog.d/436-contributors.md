### For contributors
- The app's scene body (`Pi2App.body`) reads nothing that changes while the app runs. A development build writes a line to `app.log` when it does (`BodyWatch` in `WindowKit`), `pi2-window-check` checks that watch, and `perf.log` counts how many times the body was worked out.
