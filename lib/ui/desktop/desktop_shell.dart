import 'package:flutter/material.dart';

import '../shared/gallery_view.dart';

class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(child: GalleryView());
  }
}
