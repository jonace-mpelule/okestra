# Expo and Okestra Device

Okestra Device exposes the server emulator as a local ADB device. Build and run an **Expo development build** with your local tooling and select the tunneled `127.0.0.1:<port>` device. Keep Metro running locally and use your existing development-client connection workflow. The Mac Device app does not manage Metro, builds, projects or source sync.

For local Metro through the ADB transport, explicitly reverse the port you use, for example `adb -s SERIAL reverse tcp:8081 tcp:8081`. Use your development client's matching local Metro URL. Reapply reverses after restarting/switching the emulator. Network configuration and the URL scheme remain your project's responsibility.

See [device setup](android.md). The earlier remote Expo build integration is [archived](archive/README.md), with its previous guide retained [here](archive/expo-project-workflows.md).
