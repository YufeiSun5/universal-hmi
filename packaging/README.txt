Universal HMI: native desktop plus local Web

Install and launch
- Linux x64 / Ubuntu 24.04 or compatible newer system: install the .deb using
  your package manager. Launch Universal HMI from Applications, or universal-hmi.
  Alternative without administrator access: python3 universal-hmi-linux-x64.install.pyz
  --prefix /an/empty/absolute/path, then run PATH/launch-universal-hmi. Python 3.9+
  and the same GTK/EGL system libraries are required for this alternative.
- Windows x64: run universal-hmi-windows-x64-setup.exe. It installs for the current
  user, creates a Start menu shortcut and provides an Apps uninstall entry.
- macOS universal (Apple silicon and Intel): open the DMG and drag Universal HMI.app
  to Applications (or your own ~/Applications). Eject the DMG before launching.
  This development build is not Developer ID signed or notarized. Gatekeeper may
  require your explicit approval through macOS standard app-opening controls.
  The installer never changes security settings or removes quarantine attributes.

Close Universal HMI and its owned backend before updating/removing it. Installer
builds are unsigned development artifacts, not public production releases.
Nothing starts during installation. No login item, boot service, firewall rule,
network permission, user account or production source connection is created.

Web
Launch the desktop app normally. Its bundled backend serves the bundled offline
Web UI at http://127.0.0.1:18080. Keep the desktop app running while using its owned
backend. A compatible already-running local backend is reused rather than killed.
Remote LAN access is a separate explicit authenticated/TLS deployment; installers
never enable it. Browser and desktop use the same backend and data.

Data is stored outside application files and is preserved by upgrade/uninstall:
- Linux: $XDG_DATA_HOME/universal-hmi, or ~/.local/share/universal-hmi
- Windows: %LOCALAPPDATA%/universal-hmi
- macOS: ~/Library/Application Support/universal-hmi
Do not place personal documents in the installed application directory.

Update and uninstall
- Linux .deb: use the package manager to upgrade, remove or purge universal-hmi.
  Even purge does not remove personal app data. Stop the app before updating.
- Linux rootless: rerun the newer .install.pyz with the same --prefix. If files in
  the install directory were changed or added, the installer refuses to replace
  them. Back them up elsewhere first. Run PATH/uninstall-universal-hmi to remove
  verified application files. No desktop shortcut or PATH setting is changed.
- Windows: run the newer setup normally, using the same destination. Payloads are
  versioned so updating never overwrites running executable files. Remove through
  Windows Apps settings or the Start menu uninstall entry. User data is untouched.
- macOS: replace the old .app with the new .app while the old app is closed.
  Uninstall by moving Universal HMI.app to Trash. Personal app data stays in place.

Checksums and provenance
Verify SHA256SUMS-TARGET against the installer before use. The companion installer
manifest records the source revision and original bundle manifest hash. These
hashes detect accidental modification; unsigned manifests are not proof of author
identity. Desktop and bundled Web must come from identical verified source inputs.

macOS minimum: macOS 11 Big Sur (Go 1.24 runtime requirement).

Windows runtime redistribution
Windows 10+ is required. The Windows bundle includes the unmodified x64 Visual C++
release runtime DLLs from the installed Visual Studio VC/Redist/MSVC directory,
with version and hashes in build-manifest.json. No administrator rights, runtime
installer download, or System32 modification is needed. Debug runtimes are never
shipped. Universal CRT is supplied by supported Windows itself.
App-local runtime security updates are delivered with updated Universal HMI
installers; users should keep the application up to date. Redistribution remains
subject to the applicable licensed Visual Studio terms and Microsoft REDIST list:
https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution
https://learn.microsoft.com/en-us/cpp/windows/choosing-a-deployment-method?view=msvc-170
https://docs.flutter.dev/platform-integration/windows/building

Third-party notices for bundled macOS Flutter runner templates and default icons
===========================================================================
Copyright 2014 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Copyright 2013 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
