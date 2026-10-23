# Default workflow for every requested change

For every change the user requests in this repository, automatically implement the change, run appropriate validation, build and install the updated UMarkdown app on this system using the procedure below, commit the requested changes, and push the commit to the current branch's configured upstream before reporting completion. Do not wait for a separate request or confirmation to install, commit, or push; these steps are already authorized as part of every change request. Obtain sandbox escalation when required.

Commit only changes belonging to the task and leave unrelated working-tree changes untouched. If building, installation, committing, or pushing fails or is blocked, report the incomplete step explicitly. Report build, install, commit, and push results separately.

# UMarkdown local build and install

For every requested change, test Finder Quick Look (select a Markdown file and press Space), not just the standalone app. Use `TODO.md` as a smoke-test document and verify a rendered heading and task-list checkboxes rather than raw Markdown. Verify the installed Quick Look extension is registered and enabled with PlugInKit. A successful app preview or build does not establish that Finder Quick Look works. Report a blocked or failed Quick Look check explicitly.

Use `bash scripts/build-local.sh > /tmp/umarkdown-build.log 2>&1` for the local build. It applies the command-line overrides below, then ad hoc signs the extensions with their required sandbox entitlements, omitting provisioning-dependent application groups. PlugInKit rejects extensions without sandboxing. The containing app is built without sandboxing for local file access. Keep project signing settings unchanged.

When changing the macOS app, build and install the changed app before reporting completion. The user has explicitly requested this routine for future modifications; do not wait for a separate install prompt. This repository used to live at `~/dev/QLMarkdown` and `~/dev/UMarkdown`; use the current checkout and the `UMarkdown` project and scheme.

Xcode is installed at `/Applications/Xcode.app`, but `xcode-select` may point to Command Line Tools. Set `DEVELOPER_DIR` for every `xcodebuild` invocation. The working local build from previous sessions is:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project UMarkdown.xcodeproj -scheme UMarkdown -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/umarkdown-derived \
  -jobs 4 ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  CODE_SIGN_ENTITLEMENTS= ENABLE_APP_SANDBOX=NO \
  build > /tmp/umarkdown-build.log 2>&1
```

Check that the command exits successfully and the log contains `BUILD SUCCEEDED`, followed by successful extension signing and signature verification. The signed product is `/tmp/umarkdown-derived/Build/Products/Debug/UMarkdown.app`. Use ad hoc signing for local builds; it is available without an Apple development certificate or provisioning profile. The raw Xcode command above requires the extension-signing step in `scripts/build-local.sh` before installation. Local builds do not exercise shared application-group capabilities. Keep overrides on the command line; do not change project signing settings. Never commit machine-specific signing identities, team overrides, provisioning profiles, generated signatures, build artifacts, or new machine-specific paths. If package resolution requires network or Xcode needs its normal caches/keychain, run the build with the required sandbox escalation. Do not replace the signed build with `CODE_SIGNING_ALLOWED=NO` for installation.

Install the built app, replacing the user's existing local installation:

```sh
osascript -e 'tell application id "com.taglab.UMarkdown" to quit' >/dev/null 2>&1 || true
ditto /tmp/umarkdown-derived/Build/Products/Debug/UMarkdown.app /Users/martin/Applications/UMarkdown.app
codesign --verify --deep --strict /Users/martin/Applications/UMarkdown.app
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted /Users/martin/Applications/UMarkdown.app
```

Ask for sandbox escalation for installation outside the checkout when needed. Verify the installed app's executable or resources match the product. If a UI behavior was changed, launch the installed app with a suitable sample Markdown file and check the behavior when feasible. Report build and install results separately. Never claim installation from a successful build alone.
