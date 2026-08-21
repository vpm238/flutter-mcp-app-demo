# app — the Flutter web view

The view half of Showtime. See the [root README](../README.md) for what this is,
how the two-frame architecture works, and how to run and deploy it.

```bash
flutter test                                   # widget, controller and parity tests
flutter run -d chrome                          # the app on local fixtures
flutter build web --release --pwa-strategy=none \
  --no-web-resources-cdn --base-href /app/     # what the server bundles
```

`--no-web-resources-cdn` matters: it self-hosts CanvasKit instead of fetching it
from `gstatic.com`, which keeps the view to a single declared origin.
`--pwa-strategy=none` matters too — a sandboxed frame cannot register a service
worker.
