// Account switcher pill, switcher sheet/dialog, and account management dialogs (F4).
import 'package:flutter/material.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../controllers/app_state.dart';
import '../features/common/app_tokens.dart';
import '../l10n/strings.dart';
import 'overlays.dart' show TutorialAnchor;

/// Builds a concise subtitle for an account row from its Bakaláři username and
/// school preset ID.
String formatAccountSubtitle(String username, String presetId) {
  final parts = <String>[];
  final user = username.trim();
  if (user.isNotEmpty) parts.add(user);
  final pid = presetId.trim();
  if (pid.isNotEmpty && pid != core.customId) {
    try {
      final preset = core.getPreset(pid);
      if (preset != null) {
        final title = core.presetTitle(preset, Strings.lang).trim();
        if (title.isNotEmpty) parts.add(title);
      }
    } catch (_) {}
  }
  return parts.join(' · ');
}

/// First uppercase character of [label] for the circular avatar badge.
String accountInitial(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
}

/// Compact TopBar pill showing the active account label and opening the
/// account switcher (§10.1). Callers render this only when `isMultiAccount`.
class AccountSwitcherPill extends StatelessWidget {
  final AppState appState;
  final Tokens tok;
  final bool narrow;
  final VoidCallback onManageAccounts;

  const AccountSwitcherPill({
    super.key,
    required this.appState,
    required this.tok,
    required this.narrow,
    required this.onManageAccounts,
  });

  @override
  Widget build(BuildContext context) {
    final label = appState.activeAccountDisplayLabel;
    return TutorialAnchor(
      anchorKey: 'account_switcher',
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: narrow ? 120 : 200),
        child: Tooltip(
          message: label,
          child: Material(
            color: tintColor(tok.accent, 0.12),
            borderRadius: BorderRadius.circular(tok.radiusSm),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('account_switcher'),
              onTap: () => showAccountSwitcher(
                context,
                appState: appState,
                tok: tok,
                narrow: narrow,
                onManageAccounts: onManageAccounts,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: narrow ? 6 : 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_outline, size: 16, color: tok.accent),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tok.text,
                          fontSize: tok.fsSmall,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(Icons.arrow_drop_down, size: 18, color: tok.muted),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the account switcher as a bottom sheet on narrow layouts or a dialog
/// on wide layouts (§10.1).
Future<void> showAccountSwitcher(
  BuildContext context, {
  required AppState appState,
  required Tokens tok,
  required bool narrow,
  required VoidCallback onManageAccounts,
}) {
  if (narrow) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: tok.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(tok.radiusMd)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: AccountSwitcherSheet(
          appState: appState,
          tok: tok,
          onClose: () => Navigator.of(sheetCtx).pop(),
          onManageAccounts: onManageAccounts,
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (dlgCtx) => Dialog(
      backgroundColor: tok.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tok.radiusMd),
        side: BorderSide(color: tok.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: AccountSwitcherSheet(
          appState: appState,
          tok: tok,
          onClose: () => Navigator.of(dlgCtx).pop(),
          onManageAccounts: onManageAccounts,
        ),
      ),
    ),
  );
}

/// Account list + footer actions shown inside the switcher sheet or dialog.
class AccountSwitcherSheet extends StatelessWidget {
  final AppState appState;
  final Tokens tok;
  final VoidCallback onClose;
  final VoidCallback onManageAccounts;

  const AccountSwitcherSheet({
    super.key,
    required this.appState,
    required this.tok,
    required this.onClose,
    required this.onManageAccounts,
  });

  @override
  Widget build(BuildContext context) {
    final registry = appState.registry;
    final accounts = registry?.accounts ?? const <core.AccountInfo>[];
    final activeId = appState.activeAccountId;
    final primaryId = appState.primaryAccountId;

    return Padding(
      key: const Key('account_switcher_sheet'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            Strings.get('accounts_manage_title'),
            style: TextStyle(
              color: tok.text,
              fontSize: tok.fsSection,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: accounts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final acc = accounts[index];
                final label = appState.accountDisplayLabel(acc);
                final (user, presetId) = appState.accountSummary(acc.id);
                final subtitle = formatAccountSubtitle(user, presetId);
                final isActive = acc.id == activeId;
                final isPrimary = acc.id == primaryId;
                final bgOn = appState.accountBackgroundRefresh(acc.id);

                return Material(
                  color: isActive
                      ? tintColor(tok.accent, 0.14)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(tok.radiusSm),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: Key('switcher:item:${acc.id}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 2,
                    ),
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: tintColor(tok.accent, 0.18),
                      foregroundColor: tok.accent,
                      child: Text(
                        accountInitial(label),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: tok.text,
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (isPrimary) ...[
                          const SizedBox(width: 6),
                          _AccountTag(
                            text: Strings.get('account_primary_badge'),
                            color: tok.accent,
                            tok: tok,
                          ),
                        ],
                      ],
                    ),
                    subtitle: (subtitle.isNotEmpty || !bgOn)
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (subtitle.isNotEmpty)
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: tok.muted,
                                    fontSize: tok.fsSmall,
                                  ),
                                ),
                              if (!bgOn)
                                Text(
                                  Strings.get('account_bg_off_tag'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: tok.faint,
                                    fontSize: tok.fsTiny,
                                  ),
                                ),
                            ],
                          )
                        : null,
                    trailing: isActive
                        ? Icon(Icons.check, color: tok.accent)
                        : null,
                    onTap: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      onClose();
                      if (!isActive) {
                        appState.switchAccount(acc.id);
                      }
                    },
                  ),
                );
              },
            ),
          ),
          const Divider(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              FilledButton.tonalIcon(
                key: const Key('switcher:add_account'),
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: Text(Strings.get('account_add')),
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  onClose();
                  appState.beginAddAccount();
                },
              ),
              TextButton.icon(
                key: const Key('switcher:manage_accounts'),
                icon: const Icon(Icons.manage_accounts_outlined, size: 18),
                label: Text(Strings.get('account_manage_btn')),
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  onClose();
                  appState.setSettingsSection('accounts');
                  onManageAccounts();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccountTag extends StatelessWidget {
  final String text;
  final Color color;
  final Tokens tok;

  const _AccountTag({
    required this.text,
    required this.color,
    required this.tok,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tintColor(color, 0.16),
        borderRadius: BorderRadius.circular(tok.radiusSm),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: tok.fsTiny,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Explicit plain-language account deletion confirmation dialog (§9).
Future<bool> showDeleteAccountDialog(
  BuildContext context, {
  required String label,
  required bool showBackupNote,
}) async {
  final tok = tokensOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dlgCtx) => AlertDialog(
      key: const Key('acc:delete_dialog'),
      title: Text(Strings.format('account_delete_title', {'name': label})),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(Strings.get('account_delete_body')),
            if (showBackupNote)
              Text(
                Strings.get('account_delete_backup_note'),
                key: const Key('acc:delete_backup_note'),
                style: TextStyle(
                  color: tok.muted,
                  fontSize: tok.fsSmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('acc:delete_cancel'),
          onPressed: () => Navigator.of(dlgCtx).pop(false),
          child: Text(Strings.get('cancel')),
        ),
        FilledButton(
          key: const Key('acc:delete_confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: tok.red,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(dlgCtx).pop(true),
          child: Text(Strings.get('account_delete_confirm')),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Dialog for renaming an account (trimmed non-empty, max 60 chars, §2.1 & §10.2).
Future<String?> showRenameAccountDialog(
  BuildContext context, {
  required String currentLabel,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _RenameAccountDialog(currentLabel: currentLabel),
  );
}

class _RenameAccountDialog extends StatefulWidget {
  final String currentLabel;
  const _RenameAccountDialog({required this.currentLabel});

  @override
  State<_RenameAccountDialog> createState() => _RenameAccountDialogState();
}

class _RenameAccountDialogState extends State<_RenameAccountDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentLabel);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _controller.text.trim().isNotEmpty;
    return AlertDialog(
      key: const Key('acc:rename_dialog'),
      title: Text(Strings.get('account_rename')),
      content: TextField(
        key: const Key('acc:rename_field'),
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        decoration: InputDecoration(
          hintText: Strings.get('account_rename_hint'),
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (v) {
          final trimmed = v.trim();
          if (trimmed.isNotEmpty) {
            Navigator.of(context).pop(trimmed);
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(Strings.get('cancel')),
        ),
        FilledButton(
          key: const Key('acc:rename_confirm'),
          onPressed: valid
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: Text(Strings.get('account_rename')),
        ),
      ],
    );
  }
}
