# Desktop uninstall registrations

Debian and pacman removal hooks remove the runtime URL handler and autostart
desktop entry only when their `Exec` still points to the packaged FlClashMeow
executable. MIME lists retain other handlers. Home-directory operations run as
each local account through `runuser`, rather than as the package manager's root
process; symlink desktop entries and MIME lists are left alone.

These hooks cover passwd accounts with UID 1000–65533 and the standard
`~/.config` / `~/.local/share` locations. A custom `XDG_DATA_HOME` is not available
to the package manager after application exit. Users of custom XDG locations
must remove that location's `flclash-meow-url-handler.desktop` and its matching
MIME association themselves. AppImage and archive removal has no package hook.

RPM is excluded from this product: the [current flutter_distributor RPM maker](https://github.com/chenx-dust/flutter_distributor/blob/c69667454c30dab80dac27258eb28c4236824550/packages/flutter_app_packager/lib/src/makers/rpm/make_rpm_config.dart#L145)
ignores configured uninstall hooks and Core-preservation macros. It must not
return to the target list until its generated-package contract is repaired and
verified; configuration values alone do not establish cleanup or Core integrity.

Run `python3 tool/product_uninstall_test.py` on Linux to exercise the actual
post-removal shell in temporary homes, with account discovery/identity switching
stubbed at the operating-system boundary. Windows runs the Inno template contract
and its embedded scheduled-task command against fixture query/delete commands;
the task is removed only for one argument-free action targeting this install.
Actual installer execution is covered by the disposable native package
acceptance workflow. These checks do not install packages or mutate services.
