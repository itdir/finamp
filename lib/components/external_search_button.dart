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
      icon: ImageIcon(
        const AssetImage(assetPath),
        color: Theme.of(context).iconTheme.color ??
            Theme.of(context).colorScheme.onSurface,
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
    return ImageIcon(
      const AssetImage(ExternalSearchButton.assetPath),
      color: Theme.of(context).iconTheme.color ??
          Theme.of(context).colorScheme.onSurface,
    );
  }
}
