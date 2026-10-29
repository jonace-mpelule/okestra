# Android capture component

Okestra Device bundles the unmodified scrcpy 3.3.4 Android server under Apache-2.0 (see LICENSE). It does not bundle the SDL/FFmpeg desktop client. Source: https://github.com/Genymobile/scrcpy/tree/v3.3.4/server . Binary taken from the installed Homebrew scrcpy 3.3.4 package, SHA-256:

8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e

The native Swift client implements its pinned H.264 and control wire format. Upgrading this server requires matching protocol verification and device acceptance testing. No binary is downloaded when opening the viewer.
