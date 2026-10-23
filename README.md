# UMarkdown

> [!WARNING]
> **Inactive personal-use fork.** UMarkdown is not an active or maintained
> project. I do not publish builds, accept issues or pull requests, or provide
> support. This source repository is available under GPLv3.

UMarkdown is a read-only Markdown viewer for macOS with Quick Look support. Open
one or more Markdown files from Finder or choose **File → Open Markdown…**. Each
file opens in its own window. Configure rendering from **UMarkdown → Settings…**.

Press **⌘F** to find text in the current document. **⌘G** and **⇧⌘G** move
between matches; Return and Shift-Return also work in the find field. Press
**Esc** or click **Done** to dismiss the find bar and its highlights.

## Build

Open `UMarkdown.xcodeproj` in Xcode and select the `UMarkdown` scheme. The
project uses the Git submodules listed in `.gitmodules` and native build tools
including CMake and Autotools. Initialize the submodules before building:

```sh
git submodule update --init --recursive
```

Select your own development team in Signing & Capabilities for the app and its
extensions if you build a signed local copy.

Run the native find integration tests with `sh Tests/run-find-tests.sh` on macOS.

## Origin and license

UMarkdown is a modified fork of [SBAREX's QLMarkdown](https://github.com/sbarex/QLMarkdown).
See [ORIGIN_AND_LICENSE.txt](ORIGIN_AND_LICENSE.txt) for the source and change
notice. The code remains under [GNU GPL version 3](LICENSE.txt).
