#!/bin/bash
# Ad hoc local build: the app needs file access, while app extensions must
# remain sandboxed for PlugInKit to register them. No provisioning is required.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
derived_data=${UMARKDOWN_DERIVED_DATA:-/tmp/umarkdown-derived}
xcodebuild -project UMarkdown.xcodeproj -scheme UMarkdown -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" \
    -jobs 4 ONLY_ACTIVE_ARCH=YES ARCHS=arm64 CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual CODE_SIGN_ENTITLEMENTS= \
    ENABLE_APP_SANDBOX=NO build

python3 - "$derived_data/Build/Products/Debug/UMarkdown.app" <<'PY'
import pathlib
import plistlib
import subprocess
import sys
import tempfile

app = pathlib.Path(sys.argv[1])
extensions = [
    (app / 'Contents/PlugIns/UMarkdown Quick Look Extension.appex',
     pathlib.Path('UMarkdownExtension/UMarkdownExtension.entitlements')),
    (app / 'Contents/Extensions/UMarkdown Shortcut Extension.appex',
     pathlib.Path('Shortcut Extension/Shortcut_Extension.entitlements')),
]
for extension, source in extensions:
    entitlements = plistlib.loads(source.read_bytes())
    # Shared application groups require provisioning, unavailable with ad hoc signing.
    entitlements.pop('com.apple.security.application-groups', None)
    with tempfile.NamedTemporaryFile(suffix='.plist') as temporary:
        temporary.write(plistlib.dumps(entitlements))
        temporary.flush()
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements',
                        temporary.name, str(extension)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements',
                str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
PY
