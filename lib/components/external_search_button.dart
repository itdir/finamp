import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../screens/external_search_screen.dart';

/// AppBar action that opens [ExternalSearchScreen].
class ExternalSearchButton extends StatelessWidget {
  const ExternalSearchButton({Key? key}) : super(key: key);

  static const assetPath = 'images/external_search_icon.png';

  @override
  Widget build(BuildContext context) {
    return IconButton(
      // Use Image.asset (not ImageIcon) so black/white artwork is not
      // flattened into a solid tinted glyph.
      icon: Image.asset(
        assetPath,
        width: 24,
        height: 24,
        filterQuality: FilterQuality.medium,
      ),
      tooltip: AppLocalizations.of(context)!.externalSearch,
      onPressed: () => Navigator.of(context)
          .pushNamed(ExternalSearchScreen.routeName),
    );
  }
}

/// Drawer leading icon matching [ExternalSearchButton].
class ExternalSearchLeadingIcon extends StatelessWidget {
  const ExternalSearchLeadingIcon({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Image.asset(
        ExternalSearchButton.assetPath,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
