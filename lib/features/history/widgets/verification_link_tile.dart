import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

typedef LinkOpener = Future<bool> Function(Uri url);

Future<bool> _openInBrowser(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

/// The record's public verification link. Tap the link to open it in the browser; tap the copy
/// button (or long-press the link) to copy it.
class VerificationLinkTile extends StatelessWidget {
  final String url;
  final LinkOpener opener;
  const VerificationLinkTile({super.key, required this.url, this.opener = _openInBrowser});

  void _say(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) _say(context, 'Link copied');
  }

  Future<void> _open(BuildContext context) async {
    var opened = false;
    try {
      opened = await opener(Uri.parse(url));
    } catch (_) {}
    if (!opened && context.mounted) _say(context, 'Could not open the browser. Use the copy button instead.');
  }

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Verification link', style: TextStyle(fontSize: 12, color: Colors.white60)),
              InkWell(
                onTap: () => _open(context),
                onLongPress: () => _copy(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    url,
                    style: const TextStyle(color: AppTheme.amber, decoration: TextDecoration.underline),
                  ),
                ),
              ),
            ]),
          ),
          IconButton(
            tooltip: 'Copy link',
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy, size: 20),
          ),
        ]),
      );
}
