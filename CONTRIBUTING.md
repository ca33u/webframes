# Contributing

Thanks for looking. Web Frames is maintained by one person, so please open an
issue to discuss a change before sending a large pull request.

- Build and test as described in the [README](README.md); `npm test --prefix Tools`
  and the `webframesTests` suite must pass.
- Match the surrounding code. The app is AppKit with main-actor isolation by
  default; tests use Swift Testing (`@Test`, `#expect`).
- Add a line to `CHANGELOG.md` for user-visible changes. It feeds the Sparkle
  release notes, so write it for users.
- Do not commit `.codex-bridge/`, signing identities, notarization profiles or
  Sparkle keys.
