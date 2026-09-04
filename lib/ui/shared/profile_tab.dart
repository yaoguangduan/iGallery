import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'settings_sheet.dart';

class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(children: [
      Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.outline, width: 0.5)),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('我的',
              style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w700)),
        ),
      ),
      const Expanded(child: ProfileContent(asPage: true)),
    ]);
  }
}
