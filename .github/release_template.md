FlClash-Meow VERSION uses an embedded meow-rs core for Windows, macOS and Linux.

## Upstream Base

- **FlClash-Patched:** [0.9.2 at `71f94d5a`](https://github.com/chenx-dust/FlClash-Patched/commit/71f94d5af53eb6193e153ae2c039460b9011ad55).
- **meow-rs:** [v0.22.0](https://github.com/meow-rs/meow-rs/releases/tag/v0.22.0).

## What's Changed

- Fixed first startup by initializing missing Geo databases from bundled resources, without replacing existing files.
- Followed meow-rs configuration handling: unsupported fields produce warnings; only error-level issues block configuration application.
- Fixed provider cache paths and DNS compatibility, including bare IPv6 nameserver addresses and unsupported system resolver entries.
- Added AnyTLS certificate pinning and supported TLS options.
- Kept startup diagnostics in Core logs with clean formatting and correct severity.
- Simplified TUN routing labels, added an IPv6 capture setting, and updated the About page and connection labels.
- Fixed Core restart recovery after unexpected process termination and Windows TUN address readiness.
- Fixed UDP routing in Windows global TUN mode and destination-aware outbound binding across desktop platforms.
- Preserved traffic history during TUN changes and moved configuration processing off the UI thread.
- Synced upstream configuration auto-reload, proxy chain display, emoji rendering, and label improvements.

**Download based on your OS:**

<table>
    <thead>
        <tr>
            <th align="left">OS</th>
            <th align="left">Download</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td>Windows</td>
            <td>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-windows-x64-setup.exe"><img alt="Installer x64" src="https://img.shields.io/badge/Installer-x64-00E5FF.svg?logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTAgMGgxMS4zNzd2MTEuMzcySDB6TTEyLjYyMyAwSDI0djExLjM3MkgxMi42MjN6TTAgMTIuNjIzaDExLjM3N1YyNEgweiBNMTIuNjIzIDEyLjYyM0gyNFYyNEgxMi42MjN6IiBmaWxsPSIjZjVmNWY1Ii8+PC9zdmc+&amp;logoColor=f5f5f5"></a>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-windows-arm64-setup.exe"><img alt="Installer arm64" src="https://img.shields.io/badge/Installer-arm64-00B8D4.svg?logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTAgMGgxMS4zNzd2MTEuMzcySDB6TTEyLjYyMyAwSDI0djExLjM3MkgxMi42MjN6TTAgMTIuNjIzaDExLjM3N1YyNEgweiBNMTIuNjIzIDEyLjYyM0gyNFYyNEgxMi42MjN6IiBmaWxsPSIjZjVmNWY1Ii8+PC9zdmc+&amp;logoColor=f5f5f5"></a><br>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-windows-x64.zip"><img alt="Portable x64" src="https://img.shields.io/badge/Portable-x64-0091EA.svg?logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTAgMGgxMS4zNzd2MTEuMzcySDB6TTEyLjYyMyAwSDI0djExLjM3MkgxMi42MjN6TTAgMTIuNjIzaDExLjM3N1YyNEgweiBNMTIuNjIzIDEyLjYyM0gyNFYyNEgxMi42MjN6IiBmaWxsPSIjZjVmNWY1Ii8+PC9zdmc+&amp;logoColor=f5f5f5"></a>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-windows-arm64.zip"><img alt="Portable arm64" src="https://img.shields.io/badge/Portable-arm64-00B0FF.svg?logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTAgMGgxMS4zNzd2MTEuMzcySDB6TTEyLjYyMyAwSDI0djExLjM3MkgxMi42MjN6TTAgMTIuNjIzaDExLjM3N1YyNEgweiBNMTIuNjIzIDEyLjYyM0gyNFYyNEgxMi42MjN6IiBmaWxsPSIjZjVmNWY1Ii8+PC9zdmc+&amp;logoColor=f5f5f5"></a>
            </td>
        </tr>
        <tr>
            <td>macOS</td>
            <td>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-macos-x64.dmg"><img alt="DMG x64" src="https://img.shields.io/badge/DMG-x64-00A9E0.svg?logo=apple"></a>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-macos-arm64.dmg"><img alt="DMG arm64" src="https://img.shields.io/badge/DMG-arm64-000000.svg?logo=apple"></a>
            </td>
        </tr>
        <tr>
            <td>Linux</td>
            <td>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-linux-x64.zip"><img alt="ZIP x64" src="https://img.shields.io/badge/ZIP-x64-FF6D00.svg?logo=linux&amp;logoColor=f5f5f5"></a>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-linux-arm64.zip"><img alt="ZIP arm64" src="https://img.shields.io/badge/ZIP-arm64-FF9100.svg?logo=linux&amp;logoColor=f5f5f5"></a><br>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-linux-x64.AppImage"><img alt="AppImage x64" src="https://img.shields.io/badge/AppImage-x64-FF5252.svg?logo=linux&amp;logoColor=f5f5f5"></a>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-linux-arm64.AppImage"><img alt="AppImage arm64" src="https://img.shields.io/badge/AppImage-arm64-D50000.svg?logo=linux&amp;logoColor=f5f5f5"></a><br>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-linux-x64.deb"><img alt="DEB x64" src="https://img.shields.io/badge/DEB-x64-FF8A80.svg?logo=debian&amp;logoColor=f5f5f5"></a>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-linux-arm64.deb"><img alt="DEB arm64" src="https://img.shields.io/badge/DEB-arm64-FF1744.svg?logo=debian&amp;logoColor=f5f5f5"></a><br>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-linux-x64.tar.zst"><img alt="Arch x64" src="https://img.shields.io/badge/Arch-x64-FF4081.svg?logo=archlinux&amp;logoColor=f5f5f5"></a>
                <a href="https://github.com/yukkodesu/FlClash-Patched/releases/download/vVERSION/FlClash-Meow-VERSION-linux-arm64.tar.zst"><img alt="Arch arm64" src="https://img.shields.io/badge/Arch-arm64-F50057.svg?logo=archlinux&amp;logoColor=f5f5f5"></a>
            </td>
        </tr>
    </tbody>
</table>
