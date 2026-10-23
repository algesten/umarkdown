# UMarkdown local build and install

When changing the macOS app, build and install the changed app before reporting completion. The user has explicitly requested this routine for future modifications; do not wait for a separate install prompt. This repository used to live at `~/dev/QLMarkdown` and `~/dev/UMarkdown`; use the current checkout and the `UMarkdown` project and scheme.

Xcode is installed at `/Applications/Xcode.app`, but `xcode-select` may point to Command Line Tools. Set `DEVELOPER_DIR` for every `xcodebuild` invocation. The working local build from previous sessions is:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project UMarkdown.xcodeproj -scheme UMarkdown -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/umarkdown-derived \
  -allowProvisioningUpdates -jobs 4 ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  build > /tmp/umarkdown-build.log 2>&1
```

Check that the command exits successfully and the log ends with `BUILD SUCCEEDED`. The signed product is `/tmp/umarkdown-derived/Build/Products/Debug/UMarkdown.app`. If package resolution requires network or Xcode needs its normal caches/keychain, run the build with the required sandbox escalation. Do not replace the signed build with `CODE_SIGNING_ALLOWED=NO` for installation.

Install the built app, replacing the user's existing local installation:

```sh
osascript -e 'tell application id "com.taglab.UMarkdown" to quit' >/dev/null 2>&1 || true
ditto /tmp/umarkdown-derived/Build/Products/Debug/UMarkdown.app /Users/martin/Applications/UMarkdown.app
codesign --verify --deep --strict /Users/martin/Applications/UMarkdown.app
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted /Users/martin/Applications/UMarkdown.app
```

Ask for sandbox escalation for installation outside the checkout when needed. Verify the installed app's executable or resources match the product. If a UI behavior was changed, launch the installed app with a suitable sample Markdown file and check the behavior when feasible. Report build and install results separately. Never claim installation from a successful build alone.
