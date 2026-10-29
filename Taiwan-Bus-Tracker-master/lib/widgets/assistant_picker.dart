// Bottom sheet that lets the user pick how to use the AI assistant:
// a text chat, or the sign-language hand.

import 'package:flutter/material.dart';
import '../design/tokens.dart';
import '../utils/app_strings.dart';

Future<void> showAssistantPicker(BuildContext context, AppLanguage lang) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppPalette.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpace.lg, AppSpace.lg, AppSpace.lg, AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(AppStrings.t(lang, 'assistantTitle'), style: AppText.title),
            const SizedBox(height: AppSpace.lg),
            Row(children: [
              Expanded(
                child: _OptionCard(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: AppStrings.t(lang, 'assistantChatTitle'),
                  description: AppStrings.t(lang, 'assistantChatDesc'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.pushNamed(context, '/assistant_chat');
                  },
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: _OptionCard(
                  icon: Icons.sign_language_rounded,
                  title: AppStrings.t(lang, 'assistantSignTitle'),
                  description: AppStrings.t(lang, 'assistantSignDesc'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.pushNamed(context, '/assistant_sign');
                  },
                ),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
}

class _OptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _OptionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.surfaceRaised,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Large icon so the choice works without reading.
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppPalette.accentSoft,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Icon(icon, size: 36, color: AppPalette.accent),
              ),
              const SizedBox(height: AppSpace.md),
              Text(title, style: AppText.heading),
              const SizedBox(height: AppSpace.xs),
              Text(description, style: AppText.caption),
            ],
          ),
        ),
      ),
    );
  }
}
