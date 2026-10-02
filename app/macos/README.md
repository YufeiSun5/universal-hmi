# macOS runner

Runner files are based on the Flutter 3.35.4 `app/macos.tmpl` Swift Package Manager
templates, with pinned `flutter_template_images` 5.0.0 default icons. Template
placeholders were rendered locally; native Xcode compilation is verified in CI.
Flutter templates are BSD-3-Clause (see FLUTTER-LICENSE.txt).

Before resolving dependencies on macOS, run
`flutter config --enable-swift-package-manager`. The pinned plugins are local
Swift packages resolved by `pubspec.lock`; no CocoaPods integration or build-time
mutation of the tracked Xcode project is required.

The universal app is `Universal HMI.app`, with a stable executable named
`Contents/MacOS/universal_hmi`. `ci/package_desktop.py macos` installs the
universal Go sidecar beside it. `ci/package_final.py --targets macos` installs
the same-source Web build in `Contents/Resources/web`. User data lives outside
the app in `~/Library/Application Support/universal-hmi`.

This direct-distribution development package disables App Sandbox and identity
signing. It is not notarized or App Store-ready; no signing certificate or
account is configured. Flutter/Go toolchains may retain intrinsic ad-hoc Mach-O
signatures required by Apple silicon, without a developer identity.

Release builds explicitly include arm64 and x86_64. The packaging gates reject
a missing architecture, changed artifact, escaping symlink, or mismatched
desktop/Web provenance. macOS-native build and launch checks are still required;
Linux packaging unit tests do not establish macOS runtime compatibility.
