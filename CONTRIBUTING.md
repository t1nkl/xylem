# Contributing to Xylem

Thanks for wanting to help. Bug reports, ideas and pull requests are all
welcome.
Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting a bug

Open an [issue](https://github.com/t1nkl/xylem/issues) with:

- the Xylem version (Xylem > About Xylem) and your macOS version, Apple
  silicon or Intel;
- the Claude Code version (`claude --version`);
- what you did, what you expected, and what happened instead.

Please leave out your prompts, project names and paths unless they matter for
the bug.

## Before a pull request

For anything bigger than a small fix, open an issue first so we can agree on
the approach. Xylem is opinionated about its look and stays small on purpose,
so not every feature will fit - better to find out before you write it.

## Contributor License Agreement

Every contributor signs the [CLA](CLA.md) once, by adding this comment to
their first pull request:

> I have read the Xylem CLA (CLA.md) and I agree to it. - @your-username

You keep the copyright in your work. The CLA lets the maintainer move the
project, including your contribution, to another open-source license in the
future (for example a later GPL version) without having to find every past
contributor. It never allows a closed-source or commercial version: your code
stays open source. Pull requests can't be merged without it. Please don't
edit or delete the signing comment later: it is the record of your agreement.

## Code

- Swift, SwiftUI and AppKit; the project builds with Xcode 26 (see the README).
- Follow the code around you: domain folders, readers behind protocols and off
  the main thread, `@Observable` view models, presentational views.
- Keep the app cheap at rest: no polling or animation that runs when nothing
  changes. Measure idle CPU if you touch a loop or a view that refreshes.
- Comments explain why, not what. English everywhere, and plain hyphens rather
  than em dashes.
- Add tests for logic (`XylemTests/`, Swift Testing). They must not touch the
  real `~/.claude` or `~/.xylem`: inject directories and stores.
- Run the tests before you open the pull request:

  ```
  xcodebuild -project Xylem.xcodeproj -scheme Xylem -configuration Debug test \
    -only-testing:XylemTests -skipPackagePluginValidation \
    DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=-
  ```

- For UI changes, add a screenshot to the pull request.

## License

By contributing you agree that your contribution is licensed as described in
the [CLA](CLA.md), and is distributed as part of Xylem under the GNU GPL v3.
