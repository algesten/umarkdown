# UMarkdown

UMarkdown is a read-only Markdown viewer for macOS with Quick Look support. Open
one or more Markdown files from Finder or choose **File → Open Markdown…**. Each
file opens in its own window. Configure rendering from **UMarkdown → Settings…**.

This fork is for personal use. I do not distribute UMarkdown builds or provide
support for UMarkdown. The source is published here under GPLv3.

## Build

Open `UMarkdown.xcodeproj` in Xcode and select the `UMarkdown` scheme. The
project uses the Git submodules listed in `.gitmodules` and native build tools
including CMake and Autotools. Initialize the submodules before building:

```sh
git submodule update --init --recursive
```

Select your own development team in Signing & Capabilities for the app and its
extensions if you build a signed local copy.

## Origin and license

UMarkdown is a modified fork of [SBAREX's QLMarkdown](https://github.com/sbarex/QLMarkdown).
See [ORIGIN_AND_LICENSE.txt](ORIGIN_AND_LICENSE.txt) for the source and change
notice. The code remains under [GNU GPL version 3](LICENSE.txt).
